import 'dart:async';

import 'package:cellar/src/cellar/byte_budget.dart';
import 'package:cellar/src/cellar/eviction_policy.dart';
import 'package:cellar/src/cellar/lifecycle.dart';
import 'package:cellar/src/cellar/storage_scope.dart';
import 'package:cellar/src/core/object_info.dart';
import 'package:cellar/src/decorators/ledger/usage_ledger.dart';

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
/// A partition or budget that enforces its cap on write ([Lifecycle.enforceOnWrite])
/// is also driven by its `UsageLedger`: a write that takes it over the cap starts a
/// pass at once, from the ledger, with no listing. One pass runs at a time for each
/// partition or budget, whether the timer or a write started it.
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

  /// The budget each member partition belongs to, by name.
  final Map<String, String> _budgetOfPartition = {};
  final Map<String, _Serial> _budgetSerials = {};

  /// Passes a write started, by what they enforce, and the tasks in flight.
  final Map<String, _PassState> _passes = {};
  final Set<Future<void>> _inFlight = {};
  bool _disposed = false;

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
  ///
  /// [ledger] is the partition's `UsageLedger`, for a partition that enforces its cap
  /// on write or is in a budget that does. The runner then loads it (one listing, in
  /// the background) and watches it grow.
  void register(
    String name,
    StorageScope scope,
    Lifecycle lifecycle, {
    UsageLedger? ledger,
  }) {
    final p = _PartitionLifecycle(name, scope, lifecycle, ledger);
    _partitions[name] = p;
    if (ledger != null) {
      p.unsubscribe = ledger.addGrowthListener(() => _onGrowth(p));
      _track(_load(p));
    }
    _restartTimer();
  }

  /// Register a budget over partitions already registered (a member with no rules
  /// of its own is registered with an empty [Lifecycle]). Called by `Cellar`.
  void registerBudget(String name, ByteBudget budget) {
    _budgets[name] = budget;
    _budgetSerials[name] = _Serial();
    for (final member in budget.partitions) {
      _budgetOfPartition[member] = name;
    }
    _restartTimer();
  }

  /// Stop the timer and clear state. Called by `Cellar.close`. A pass that is
  /// running finishes its current eviction and stops; [stop] also waits for it.
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    for (final p in _partitions.values) {
      p.unsubscribe?.call();
    }
    _partitions.clear();
    _budgets.clear();
    _budgetOfPartition.clear();
    _budgetSerials.clear();
  }

  /// [dispose], then wait until no pass is still running, so the backends can be
  /// disposed without a pass reaching into them.
  Future<void> stop() async {
    dispose();
    await idle();
  }

  /// Completes when every pass that is running, and every one a write has asked
  /// for, has finished. A write does not wait for the pass it starts; a caller that
  /// must see its effect (a test, a shutdown) waits here.
  Future<void> idle() async {
    while (_inFlight.isNotEmpty) {
      await Future.wait(_inFlight.toList());
    }
  }

  /// Run evaluation immediately for every registered partition. Useful
  /// for tests; production code lets the timer fire it. Waits for the passes
  /// writes started first, so the two never run over each other.
  Future<void> evaluateNow() async {
    await idle();
    for (final p in _partitions.values) {
      await p.serial.run(() => _evaluate(p));
    }
    for (final entry in _budgets.entries) {
      await _budgetSerials[entry.key]!.run(() => _enforceBudget(entry.value));
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
      if (await _evictTracked(victim.$1, victim.$2, EvictionReason.makeRoom)) {
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
    for (final p in _partitions.values.toList()) {
      try {
        await p.serial.run(() => _evaluate(p));
      } catch (e) {
        // The pass itself failed (listing errored, backend down). Report
        // and move to the next partition; this one retries next tick.
        onEvictionError?.call(p.name, null, e);
      }
    }
    for (final entry in _budgets.entries.toList()) {
      try {
        final serial = _budgetSerials[entry.key];
        if (serial == null) continue; // closed while the tick ran
        await serial.run(() => _enforceBudget(entry.value));
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
      for (final info in await _objectsOf(p)) {
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

  /// What [p] holds: from its ledger when it has one that is loaded (no listing), and
  /// from a listing when not.
  Future<List<ObjectInfo>> _objectsOf(_PartitionLifecycle p) async {
    final ledger = p.ledger;
    final prefix = p.scope.prefix('');
    if (ledger != null && ledger.isLoaded(prefix)) {
      return p.scope.scoped(ledger.entriesUnder(prefix));
    }
    return p.scope.list('');
  }

  /// The bytes the budget's members hold together, read from their ledgers: exact,
  /// and no listing. Null when a member has no loaded ledger.
  int? _budgetTotal(ByteBudget budget) {
    var total = 0;
    for (final name in budget.partitions) {
      final p = _partitions[name];
      final ledger = p?.ledger;
      final prefix = p?.scope.prefix('');
      if (p == null || ledger == null || !ledger.isLoaded(prefix!)) return null;
      total += ledger.bytesUnder(prefix);
    }
    return total;
  }

  /// Bring the budget's partitions, together, under its cap. Runs after each
  /// partition's own rules, so those have already trimmed what they could.
  Future<void> _enforceBudget(ByteBudget budget) async {
    final victims = await _budgetVictims(budget);
    var total = victims.fold<int>(0, (a, v) => a + v.$2.size);
    if (total <= budget.maxBytes) return;
    for (final victim in victims) {
      if (_disposed) return;
      // With every member's ledger the total is read fresh, so what other passes
      // freed meanwhile is not evicted twice over.
      if ((_budgetTotal(budget) ?? total) <= budget.maxBytes) break;
      if (await _evictTracked(victim.$1, victim.$2, EvictionReason.budget)) {
        total -= victim.$2.size;
      }
    }
  }

  // ── Eviction on write ───────────────────────────────────────────────────────

  /// Loads [p]'s ledger with one listing, in the background.
  Future<void> _load(_PartitionLifecycle p) async {
    try {
      // A listing through the scope passes through the ledger, which takes it.
      await p.scope.list('');
    } catch (e) {
      onEvictionError?.call(p.name, null, e);
    }
  }

  void _track(Future<void> task) {
    _inFlight.add(task);
    unawaited(
      task.whenComplete(() {
        _inFlight.remove(task);
      }),
    );
  }

  /// The ledger of [p] grew: if that took the partition, or its budget, over the cap,
  /// a pass is started. Runs inside the write that grew it, so it starts work and
  /// returns, and it does not throw.
  void _onGrowth(_PartitionLifecycle p) {
    if (_disposed) return;
    try {
      if (p.lifecycle.enforceOnWrite && _overCap(p)) {
        _schedule(
          'partition:${p.name}',
          p.name,
          p.serial,
          () => _enforceFromLedger(p),
        );
      }
      final budgetName = _budgetOfPartition[p.name];
      final budget = budgetName == null ? null : _budgets[budgetName];
      if (budget != null && budget.enforceOnWrite) {
        final total = _budgetTotal(budget);
        if (total != null && total > budget.maxBytes) {
          _schedule(
            'budget:$budgetName',
            budgetName!,
            _budgetSerials[budgetName]!,
            () => _enforceBudget(budget),
          );
        }
      }
    } catch (e) {
      onEvictionError?.call(p.name, null, e);
    }
  }

  bool _overCap(_PartitionLifecycle p) {
    final maxBytes = p.lifecycle.maxBytes;
    final ledger = p.ledger;
    if (maxBytes == null || ledger == null) return false;
    final prefix = p.scope.prefix('');
    return ledger.isLoaded(prefix) && ledger.bytesUnder(prefix) > maxBytes;
  }

  /// Runs [run] under [serial], and again once more if something asks for it while
  /// it runs: writes that arrive during a pass are covered by one more pass, not by
  /// one each, and never by two at once.
  void _schedule(
    String id,
    String reportAs,
    _Serial serial,
    Future<void> Function() run,
  ) {
    final state = _passes.putIfAbsent(id, _PassState.new);
    if (state.running) {
      state.again = true;
      return;
    }
    state.running = true;
    _track(_repeat(state, reportAs, serial, run));
  }

  Future<void> _repeat(
    _PassState state,
    String reportAs,
    _Serial serial,
    Future<void> Function() run,
  ) async {
    try {
      do {
        state.again = false;
        if (_disposed) break;
        await serial.run(run);
      } while (state.again && !_disposed);
    } catch (e) {
      onEvictionError?.call(reportAs, null, e);
    } finally {
      state.running = false;
    }
  }

  /// Bring [p] under its cap from its ledger: the objects, in the policy's order, with
  /// no listing. The ledger is read again after each eviction, so a pass stops as soon
  /// as the partition fits, whatever else was written or freed meanwhile.
  Future<void> _enforceFromLedger(_PartitionLifecycle p) async {
    final maxBytes = p.lifecycle.maxBytes;
    final ledger = p.ledger;
    if (maxBytes == null || ledger == null || !_overCap(p)) return;
    final prefix = p.scope.prefix('');
    final policy = p.lifecycle.evictionPolicy;
    final ordered = p.scope.scoped(ledger.entriesUnder(prefix))
      ..sort((a, b) {
        final byPolicy = policy.compare(a, b);
        return byPolicy != 0 ? byPolicy : a.key.compareTo(b.key);
      });
    for (final victim in ordered) {
      if (_disposed || ledger.bytesUnder(prefix) <= maxBytes) break;
      await _evictTracked(p, victim, EvictionReason.partitionCap);
    }
  }

  /// [_evict], and when an eviction guard declined: if the object is in fact gone,
  /// the ledger holds a stale entry (it was removed behind the cellar's back), which
  /// would count against the cap and be tried by every pass; it is dropped.
  Future<bool> _evictTracked(
    _PartitionLifecycle p,
    ObjectInfo info,
    EvictionReason reason,
  ) async {
    final evicted = await _evict(p, info, reason);
    final ledger = p.ledger;
    if (!evicted && ledger != null && p.lifecycle.evictionGuard != null) {
      try {
        if (await p.scope.head(info.key) == null) {
          ledger.forget(p.scope.key(info.key));
        }
      } catch (_) {
        // The entry stays until the next listing puts the ledger right.
      }
    }
    return evicted;
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
  _PartitionLifecycle(this.name, this.scope, this.lifecycle, this.ledger);
  final String name;
  final StorageScope scope;
  final Lifecycle lifecycle;

  /// The partition's usage ledger, when it enforces its cap on write.
  final UsageLedger? ledger;

  /// Runs this partition's passes one at a time, whoever starts them.
  final _Serial serial = _Serial();

  /// Stops listening to [ledger].
  void Function()? unsubscribe;
}

/// Whether a pass for something is running, and whether another was asked for
/// while it did.
class _PassState {
  bool running = false;
  bool again = false;
}

/// Runs async functions one after another, in the order they are given.
class _Serial {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() task) {
    final finished = Completer<void>();
    final previous = _tail;
    _tail = finished.future;
    return previous.then((_) => task()).whenComplete(() {
      finished.complete();
    });
  }
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
