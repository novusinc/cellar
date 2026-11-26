import 'package:cellar/src/cellar/eviction_policy.dart'
    show accessCountMetadataKey, accessedAtMetadataKey;
import 'package:cellar/src/core/object_info.dart';

/// Told that the ledger grew: an object was added, or became larger. Runs
/// synchronously inside the write that caused it, so it must return at once and
/// must not throw; start the work it implies and let that run on its own.
typedef LedgerGrowthListener = void Function();

/// An in-memory tally of what a backend holds: every object's [ObjectInfo], and so
/// their total size, without listing the backend.
///
/// A cap on a partition needs one number, "how many bytes are in it", and the only
/// way to get it from storage is to list every object, which on a disk reads one
/// sidecar file each. A ledger keeps that number current instead: it is built from
/// one listing, and every write, copy, move, delete and metadata change that passes
/// through a `LedgerBackend` updates it as it happens. Asking what the partition
/// holds is then a lookup in memory.
///
/// ## What it is, and is not
///
/// - **A copy, not the truth.** The objects themselves, and their metadata, are the
///   truth, written atomically by the backend. The ledger holds nothing that is not
///   on the backend, and it is never stored: a restart builds it again from a
///   listing. There is therefore no second record that can disagree after a crash.
/// - **Exact for what passes through it.** Something that changes the backend
///   behind the ledger (another tab, another process, the OS clearing a cache
///   folder) is not seen until the next listing through it, which corrects it. A
///   cellar's timer pass lists, so a partition is put right at least that often.
/// - **Safe to read while it is updated.** Every change is made in one synchronous
///   step, so a reader never sees half of one. A listing that runs while objects are
///   being written does not overwrite what those writes recorded ([beginSnapshot]).
///
/// It costs memory in proportion to the number of objects (their [ObjectInfo], a
/// few hundred bytes each), which is what it trades for not reading the disk.
class UsageLedger {
  /// An empty ledger. It knows nothing until a listing through its backend, or the
  /// writes that follow, tell it ([isLoaded]).
  UsageLedger();

  final Map<String, ObjectInfo> _entries = {};
  int _total = 0;

  /// Prefixes a complete listing has been taken of: what the ledger holds under one
  /// of them is the whole truth as of that listing, as changed since by what passed
  /// through.
  final Set<String> _loaded = {};

  /// Listings in flight. Changes made while one runs are remembered, so the
  /// listing, which may have read the backend before them, does not undo them.
  int _snapshotsInFlight = 0;
  final Set<String> _changedKeys = {};
  final Set<String> _changedPrefixes = {};

  /// When each object's access was last recorded on the backend, in microseconds, as
  /// far as this ledger knows. [touch] uses it to write a record at most once in a
  /// window instead of at every read.
  final Map<String, int> _recordedAccess = {};

  final List<LedgerGrowthListener> _listeners = [];

  /// The bytes of every object the ledger holds.
  int get totalBytes => _total;

  /// How many objects it holds.
  int get count => _entries.length;

  /// What the ledger knows of [key], or null.
  ObjectInfo? operator [](String key) => _entries[key];

  /// Whether a complete listing has covered [prefix]: only then does the ledger hold
  /// everything under it, and may be asked "how many bytes". A cap decided from a
  /// ledger that has not loaded yet would see less than there is.
  bool isLoaded(String prefix) => _loaded.any(prefix.startsWith);

  /// The bytes of the objects whose key starts with [prefix].
  int bytesUnder(String prefix) {
    if (prefix.isEmpty) return _total;
    var sum = 0;
    for (final entry in _entries.entries) {
      if (entry.key.startsWith(prefix)) sum += entry.value.size;
    }
    return sum;
  }

  /// The objects whose key starts with [prefix], in no particular order: a copy,
  /// so what the caller does with it cannot disturb the ledger.
  List<ObjectInfo> entriesUnder(String prefix) => [
    for (final entry in _entries.entries)
      if (entry.key.startsWith(prefix)) entry.value,
  ];

  /// Calls [listener] whenever the ledger grows, until the returned function is
  /// called. See [LedgerGrowthListener].
  void Function() addGrowthListener(LedgerGrowthListener listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  // ── Changes ───────────────────────────────────────────────────────────────

  /// [info] is what the backend now holds at its key: it replaces what the ledger
  /// had.
  void record(ObjectInfo info) {
    _noteChange(info.key);
    if (_put(info)) _grew();
  }

  /// [key] is gone.
  void forget(String key) {
    _noteChange(key);
    _remove(key);
  }

  /// Every object whose key starts with [prefix] is gone.
  void forgetPrefix(String prefix) {
    if (_snapshotsInFlight > 0) _changedPrefixes.add(prefix);
    for (final key in [
      for (final key in _entries.keys)
        if (key.startsWith(prefix)) key,
    ]) {
      _remove(key);
    }
  }

  /// The metadata of [key] was patched on the backend with [changes] (a null value
  /// removes the key), so the ledger's copy changes the same way without asking the
  /// backend what it now holds.
  void applyPatch(String key, Map<String, String?> changes) {
    final info = _entries[key];
    if (info == null) return;
    _noteChange(key);
    final metadata = {...info.metadata};
    for (final change in changes.entries) {
      final value = change.value;
      if (value == null) {
        metadata.remove(change.key);
      } else {
        metadata[change.key] = value;
      }
    }
    _entries[key] = info.copyWith(metadata: metadata);
    _recordedAccess[key] = _accessMicros(metadata) ?? 0;
  }

  /// Notes that [key] was used at [at], in memory and at once, so that least-
  /// recently-used order is exact from the moment of the read.
  ///
  /// Writing the use to the object (so it survives a restart) is the caller's job,
  /// and it is done at most once per [persistAfter] for an object that is used all
  /// the time: this returns the metadata to write when a record is due, and null
  /// when the last one is recent enough. A caller that makes the record (a
  /// `patchMetadata`) passes it through the backend, and the ledger sees it there.
  /// Returns null for an object the ledger does not hold.
  Map<String, String>? touch(
    String key,
    DateTime at, {
    Duration persistAfter = const Duration(minutes: 1),
  }) {
    final info = _entries[key];
    if (info == null) return null;
    _noteChange(key);
    final micros = at.toUtc().microsecondsSinceEpoch;
    final recorded = _recordedAccess[key];
    final due =
        recorded == null || micros - recorded >= persistAfter.inMicroseconds;
    final count =
        (int.tryParse(info.metadata[accessCountMetadataKey] ?? '') ?? 0) +
        (due ? 1 : 0);
    _entries[key] = info.copyWith(
      metadata: {
        ...info.metadata,
        accessedAtMetadataKey: '$micros',
        if (due) accessCountMetadataKey: '$count',
      },
    );
    if (!due) return null;
    _recordedAccess[key] = micros;
    return {accessedAtMetadataKey: '$micros', accessCountMetadataKey: '$count'};
  }

  // ── Listings ──────────────────────────────────────────────────────────────

  /// Call before listing the backend. Changes that happen until [endSnapshot] or
  /// [abortSnapshot] are remembered, because the listing may have read the backend
  /// before them: an object written while it ran must not be erased by a listing
  /// that did not see it, nor one deleted while it ran put back by a listing that
  /// did.
  void beginSnapshot() => _snapshotsInFlight++;

  /// The listing failed: nothing is applied.
  void abortSnapshot() => _finishSnapshot();

  /// The backend listed [listed] under [prefix], and that is all there was under it
  /// when the listing ran. The ledger takes it as the truth for every object that
  /// nothing has changed since, and adds, corrects or removes accordingly.
  void endSnapshot(String prefix, List<ObjectInfo> listed) {
    var grew = false;
    final seen = <String>{};
    for (final info in listed) {
      seen.add(info.key);
      if (_changedSince(info.key)) continue;
      if (_put(info)) grew = true;
    }
    final gone = [
      for (final key in _entries.keys)
        if (key.startsWith(prefix) &&
            !seen.contains(key) &&
            !_changedSince(key))
          key,
    ];
    gone.forEach(_remove);
    final firstLoad = _loaded.add(prefix);
    _finishSnapshot();
    if (grew || firstLoad) _grew();
  }

  // ── Internals ─────────────────────────────────────────────────────────────

  bool _changedSince(String key) =>
      _changedKeys.contains(key) || _changedPrefixes.any(key.startsWith);

  void _noteChange(String key) {
    if (_snapshotsInFlight > 0) _changedKeys.add(key);
  }

  void _finishSnapshot() {
    if (--_snapshotsInFlight == 0) {
      _changedKeys.clear();
      _changedPrefixes.clear();
    }
  }

  /// Stores [info]; true when that made the ledger bigger.
  bool _put(ObjectInfo info) {
    final old = _entries[info.key];
    _total += info.size - (old?.size ?? 0);
    _entries[info.key] = info;
    _recordedAccess[info.key] = _accessMicros(info.metadata) ?? 0;
    return old == null || info.size > old.size;
  }

  void _remove(String key) {
    final old = _entries.remove(key);
    if (old != null) _total -= old.size;
    _recordedAccess.remove(key);
  }

  void _grew() {
    // Nothing a cap could be decided from before the first complete listing.
    if (_loaded.isEmpty) return;
    for (final listener in [..._listeners]) {
      listener();
    }
  }

  static int? _accessMicros(Map<String, String> metadata) =>
      int.tryParse(metadata[accessedAtMetadataKey] ?? '');
}
