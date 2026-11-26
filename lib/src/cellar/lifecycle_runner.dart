import 'dart:async';

import 'package:cellar/src/cellar/eviction_policy.dart';
import 'package:cellar/src/cellar/lifecycle.dart';
import 'package:cellar/src/cellar/storage_scope.dart';
import 'package:cellar/src/core/object_info.dart';

/// Callback for eviction failures. [key] is the victim that could not be
/// deleted, or null when the partition pass itself failed (e.g. the
/// listing errored). Without an observer, a permanently failing delete
/// retries forever with zero visibility.
typedef EvictionErrorCallback =
    void Function(String partition, String? key, Object error);

/// Background runner that evaluates partition lifecycle policies and
/// evicts items.
///
/// One runner per `Cellar` instance. Holds a Map of partition → scope
/// + lifecycle, fires a single periodic timer at the shortest configured
/// `runInterval`, walks each partition with rules and evicts.
///
/// Eviction is best-effort and resilient: a victim that fails to delete
/// is reported via [onEvictionError] and SKIPPED — one stuck object must
/// not shield everything newer from the size cap. Failed victims retry
/// on the next tick.
class LifecycleRunner {
  /// [now] injects the clock for age-eviction tests; production uses the
  /// real one.
  LifecycleRunner({
    DateTime Function() now = DateTime.now,
    this.onEvictionError,
  }) : _now = now;

  final Map<String, _PartitionLifecycle> _partitions = {};

  /// Injectable clock — age eviction is testable at exact boundaries
  /// without real waits.
  final DateTime Function() _now;

  /// Invoked once per eviction failure. Null = failures are silent
  /// (still retried next tick).
  final EvictionErrorCallback? onEvictionError;

  Timer? _timer;
  Duration? _interval;

  /// Register a partition for lifecycle evaluation. Called by `Cellar`
  /// on each partition that has a non-null [Lifecycle].
  void register(String name, StorageScope scope, Lifecycle lifecycle) {
    _partitions[name] = _PartitionLifecycle(name, scope, lifecycle);
    _restartTimer();
  }

  /// Stop the timer and clear state. Called by `Cellar.close`.
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _partitions.clear();
  }

  /// Run evaluation immediately for every registered partition. Useful
  /// for tests; production code lets the timer fire it.
  Future<void> evaluateNow() async {
    for (final p in _partitions.values) {
      await _evaluate(p);
    }
  }

  /// Run wipeOnOpen across all partitions whose lifecycle requests it.
  /// Called by `Cellar.open` before any user calls happen.
  Future<void> runWipeOnOpen() async {
    for (final p in _partitions.values) {
      if (p.lifecycle.wipeOnOpen) {
        await p.scope.deletePrefix('');
      }
    }
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = null;

    Duration? shortest;
    for (final p in _partitions.values) {
      if (!p.lifecycle.hasRules) continue;
      final candidate = p.lifecycle.runInterval;
      if (shortest == null || candidate < shortest) shortest = candidate;
    }
    if (shortest == null) return;

    _interval = shortest;
    _timer = Timer.periodic(shortest, (_) => _tick());
  }

  Future<void> _tick() async {
    for (final p in _partitions.values) {
      try {
        await _evaluate(p);
      } catch (e) {
        // The pass itself failed (listing errored, backend down). Report
        // and move to the next partition; this one retries next tick.
        onEvictionError?.call(p.name, null, e);
      }
    }
  }

  Future<void> _evaluate(_PartitionLifecycle p) async {
    if (!p.lifecycle.hasRules || p.lifecycle.wipeOnOpen) {
      // wipeOnOpen handled at open time, not on every tick.
      if (p.lifecycle.maxBytes == null && p.lifecycle.maxAge == null) return;
    }

    final all = await p.scope.list('');
    if (all.isEmpty) return;

    // Oldest written first: the order age eviction walks, and the base order the
    // policy re-sorts for the size cap.
    final sorted = [...all]
      ..sort((a, b) => a.lastModified.compareTo(b.lastModified));

    final now = _now().toUtc();
    final maxAge = p.lifecycle.maxAge;
    final maxBytes = p.lifecycle.maxBytes;

    // Pass 1: age-based eviction. An object the application keeps (canEvict)
    // stays, expired or not.
    if (maxAge != null) {
      final cutoff = now.subtract(maxAge);
      for (final info in [...sorted]) {
        if (!info.lastModified.isBefore(cutoff)) continue;
        if (await _evict(p, info, EvictionReason.expired)) sorted.remove(info);
      }
    }

    // Pass 2: size-based eviction in the policy's order. A victim that is kept,
    // or fails to delete, is skipped WITHOUT subtracting its size — it still
    // occupies the cap, so the pass keeps evicting the next ones until under the
    // limit.
    if (maxBytes != null) {
      var total = sorted.fold<int>(0, (a, b) => a + b.size);
      if (total <= maxBytes) return;
      final policy = p.lifecycle.evictionPolicy;
      final ordered = [...sorted]
        ..sort((a, b) {
          final byPolicy = policy.compare(a, b);
          return byPolicy != 0 ? byPolicy : a.key.compareTo(b.key);
        });
      for (final victim in ordered) {
        if (total <= maxBytes) break;
        if (await _evict(p, victim, EvictionReason.partitionCap)) {
          total -= victim.size;
        }
      }
    }
  }

  /// Evict [info] from [p], honoring the partition's `canEvict` and
  /// `evictionGuard`. Returns whether the object was deleted: false when the
  /// application kept it, the guard skipped it, or the delete failed (reported to
  /// [onEvictionError] and retried next tick).
  Future<bool> _evict(
    _PartitionLifecycle p,
    ObjectInfo info,
    EvictionReason reason,
  ) async {
    final lifecycle = p.lifecycle;
    final bool evicted;
    try {
      final canEvict = lifecycle.canEvict;
      if (canEvict != null && !await canEvict(info)) return false;
      final guard = lifecycle.evictionGuard;
      if (guard == null) {
        await p.scope.delete(info.key);
        evicted = true;
      } else {
        final action = _GuardedEviction(p.scope, info.key);
        await guard(info, action);
        evicted = action.evicted;
      }
    } catch (e) {
      onEvictionError?.call(p.name, info.key, e);
      return false;
    }
    if (evicted) {
      try {
        lifecycle.onEvicted?.call(p.name, info, reason);
      } catch (e) {
        // An observer that throws must not stop the pass or undo the eviction.
        onEvictionError?.call(p.name, info.key, e);
      }
    }
    return evicted;
  }

  /// The currently-active timer interval, for diagnostics. Null if no
  /// partition has rules.
  Duration? get currentInterval => _interval;
}

class _PartitionLifecycle {
  _PartitionLifecycle(this.name, this.scope, this.lifecycle);
  final String name;
  final StorageScope scope;
  final Lifecycle lifecycle;
}

/// What an [EvictionGuard] is handed: a way to read the guarded object as it is
/// now, and the delete. Remembers whether the delete ran, so the runner does not
/// have to trust a return value.
class _GuardedEviction implements EvictionAction {
  _GuardedEviction(this._scope, this._key);

  final StorageScope _scope;
  final String _key;

  /// Whether [evict] completed.
  bool evicted = false;

  @override
  Future<ObjectInfo?> head() => _scope.head(_key);

  @override
  Future<void> evict() async {
    await _scope.delete(_key);
    evicted = true;
  }
}
