import 'dart:async';

import 'package:cellar/src/core/object_info.dart';

/// Metadata key under which access tracking records when an object was last
/// read: microseconds since the Unix epoch, UTC, as a decimal string.
///
/// [EvictionPolicy.leastRecentlyUsed] and [EvictionPolicy.leastFrequentlyUsed]
/// read it, falling back to `lastModified` for an object that has none. Nothing
/// in a plain `Cellar` writes it: an object is "used" only if something records
/// its reads.
const String accessedAtMetadataKey = 'cellar.accessedAt';

/// Metadata key under which access tracking records how many times an object was
/// read: a non-negative decimal integer. Read by
/// [EvictionPolicy.leastFrequentlyUsed]; a missing or unparseable value is 0.
const String accessCountMetadataKey = 'cellar.accessCount';

/// Decides which objects of a partition are evicted first when it is over its
/// `maxBytes`.
///
/// A policy is only an order: [compare] ranks two objects, the one that sorts first
/// is evicted first, and the runner keeps evicting down the order until the
/// partition is under its cap. Policies never delete, and they see only
/// [ObjectInfo], so every one runs identically on every backend.
///
/// Three ship: [oldestWritten] (the default, and what cellar has always done),
/// [leastRecentlyUsed] and [leastFrequentlyUsed]. Write your own by extending this
/// class; a tie is broken by key, so an order is deterministic.
abstract class EvictionPolicy {
  /// A policy is a pure ordering and holds no state, so one instance is shared.
  const EvictionPolicy();

  /// Evict the object written longest ago first (`lastModified`, ascending).
  ///
  /// This is first-in, first-out by write time, and the default: a partition that
  /// does not choose a policy evicts exactly as it did before policies existed.
  static const EvictionPolicy oldestWritten = _OldestWritten();

  /// Evict the object used longest ago first.
  ///
  /// "Used" is the later of the object's `lastModified` and its
  /// [accessedAtMetadataKey], so an object that was read since it was written
  /// counts from that read, and one that was never read counts from its write.
  static const EvictionPolicy leastRecentlyUsed = _LeastRecentlyUsed();

  /// Evict the object read the fewest times first ([accessCountMetadataKey], 0 when
  /// absent); among objects read equally often, the least recently used first.
  static const EvictionPolicy leastFrequentlyUsed = _LeastFrequentlyUsed();

  /// Negative when [a] is evicted before [b], positive when after, and 0 when the
  /// policy has no preference (the runner then orders them by key).
  int compare(ObjectInfo a, ObjectInfo b);
}

class _OldestWritten extends EvictionPolicy {
  const _OldestWritten();

  @override
  int compare(ObjectInfo a, ObjectInfo b) =>
      a.lastModified.compareTo(b.lastModified);
}

class _LeastRecentlyUsed extends EvictionPolicy {
  const _LeastRecentlyUsed();

  @override
  int compare(ObjectInfo a, ObjectInfo b) =>
      _lastUsedMicros(a).compareTo(_lastUsedMicros(b));
}

class _LeastFrequentlyUsed extends EvictionPolicy {
  const _LeastFrequentlyUsed();

  @override
  int compare(ObjectInfo a, ObjectInfo b) {
    final byCount = _accessCount(a).compareTo(_accessCount(b));
    return byCount != 0
        ? byCount
        : _lastUsedMicros(a).compareTo(_lastUsedMicros(b));
  }
}

int _lastUsedMicros(ObjectInfo info) {
  final written = info.lastModified.toUtc().microsecondsSinceEpoch;
  final read = int.tryParse(info.metadata[accessedAtMetadataKey] ?? '');
  return read != null && read > written ? read : written;
}

int _accessCount(ObjectInfo info) =>
    int.tryParse(info.metadata[accessCountMetadataKey] ?? '') ?? 0;

/// Why an object was evicted, reported to [EvictionCallback].
enum EvictionReason {
  /// It was older than the partition's `maxAge`.
  expired,

  /// The partition was over its `maxBytes`.
  partitionCap,
}

/// Decides whether an object may be evicted at all. Return false to keep it, for
/// whatever the application knows that cellar does not (an upload that has not
/// finished may be the only copy).
///
/// Asked only for an object the pass is about to evict, and only for that pass:
/// answer from state you can read cheaply, and re-check in an [EvictionGuard] for
/// anything that can change between the question and the delete.
typedef CanEvict = FutureOr<bool> Function(ObjectInfo info);

/// What an [EvictionGuard] may do with the object it is guarding.
abstract interface class EvictionAction {
  /// The object as it is now (its key is the partition-relative key, as in
  /// `ObjectInfo`), or null if it is already gone.
  Future<ObjectInfo?> head();

  /// Deletes the object. Call it at most once, and only after the guard has made
  /// sure the object is still the one that was listed and is safe to remove.
  Future<void> evict();
}

/// Wraps one eviction so the application can protect it: take a lock, re-check the
/// object, then call [EvictionAction.evict] or return without calling it, which
/// skips the object.
///
/// A pass lists a partition and deletes later, and a delete is by key: an object
/// rewritten, or read, between the listing and the delete would otherwise be
/// deleted from stale information. [listed] is what the pass saw; [action] reads
/// the object now and deletes it.
///
/// A guard that throws skips the object and is reported to `onEvictionError`; the
/// object is tried again on the next pass.
typedef EvictionGuard =
    Future<void> Function(ObjectInfo listed, EvictionAction action);

/// Told after each object a pass evicted. [info] is what was listed, with the
/// partition-relative key. A callback that throws is reported to
/// `onEvictionError` and does not stop the pass.
typedef EvictionCallback =
    void Function(String partition, ObjectInfo info, EvictionReason reason);
