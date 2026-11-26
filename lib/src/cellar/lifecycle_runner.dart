import 'dart:async';

import 'package:cellar/src/cellar/byte_budget.dart';
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
  final Map<String, ByteBudget> _budgets = {};

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

  /// Register a budget over partitions already registered (a member with no rules
  /// of its own is registered with an empty [Lifecycle]). Called by `Cellar`.
  void registerBudget(String name, ByteBudget budget) {
    _budgets[name] = budget;
    _restartTimer();
  }

  /// Stop the timer and clear state. Called by `Cellar.close`.
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _partitions.clear();
    _budgets.clear();
  }

  /// Run evaluation immediately for every registered partition. Useful
  /// for tests; production code lets the timer fire it.
  Future<void> evaluateNow() async {
    for (final p in _partitions.values) {
      await _evaluate(p);
    }
    for (final entry in _budgets.entries) {
      await _enforceBudget(entry.value);
    }
  }

  /// Free at least [bytes] from the budget [name], evicting in its policy order
  /// across its partitions; returns the bytes freed, which is less than [bytes]
  /// when what is left is kept (`canEvict`, a guard) or the budget is smaller.
  ///
  /// This is not "get under the cap": it frees [bytes] whether or not the budget is
  /// full, for a caller whose write failed because the device or browser ran out of
  /// room that the budget does not know about.
  Future<int> makeRoom(String name, int bytes) async {
    final budget = _budgets[name];
    if (budget == null) {
      throw ArgumentError.value(name, 'budget', 'unknown budget');
    }
    if (bytes <= 0) return 0;
    var freed = 0;
    for (final victim in await _budgetVictims(budget)) {
      if (freed >= bytes) break;
      if (await _evict(victim.$1, victim.$2, EvictionReason.makeRoom)) {
        freed += victim.$2.size;
      }
    }
    return freed;
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
    for (final budget in _budgets.values) {
      if (shortest == null || budget.runInterval < shortest) {
        shortest = budget.runInterval;
      }
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
    for (final entry in _budgets.entries) {
      try {
        await _enforceBudget(entry.value);
      } catch (e) {
        onEvictionError?.call(entry.key, null, e);
      }
    }
  }

  /// Every object of the budget's partitions, in the budget's eviction order, each
  /// with the partition it lives in. Ties break by partition then key.
  Future<List<(_PartitionLifecycle, ObjectInfo)>> _budgetVictims(
    ByteBudget budget,
  ) async {
    final all = <(_PartitionLifecycle, ObjectInfo)>[];
    for (final name in budget.partitions) {
      final p = _partitions[name]!;
      for (final info in await p.scope.list('')) {
        all.add((p, info));
      }
    }
    all.sort((a, b) {
      final byPolicy = budget.evictionPolicy.compare(a.$2, b.$2);
      if (byPolicy != 0) return byPolicy;
      final byPartition = a.$1.name.compareTo(b.$1.name);
      return byPartition != 0 ? byPartition : a.$2.key.compareTo(b.$2.key);
    });
    return all;
  }

  /// Bring the budget's partitions, together, under its cap. Runs after each
  /// partition's own rules, so those have already trimmed what they could.
  Future<void> _enforceBudget(ByteBudget budget) async {
    final victims = await _budgetVictims(budget);
    var total = victims.fold<int>(0, (a, v) => a + v.$2.size);
    if (total <= budget.maxBytes) return;
    for (final victim in victims) {
      if (total <= budget.maxBytes) break;
      if (await _evict(victim.$1, victim.$2, EvictionReason.budget)) {
        total -= victim.$2.size;
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
