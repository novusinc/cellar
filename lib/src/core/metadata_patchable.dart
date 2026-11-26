import 'package:cellar/src/core/errors.dart';
import 'package:cellar/src/core/storage_backend.dart';

/// An optional capability of a [StorageBackend]: change some of an object's
/// metadata keys without touching the rest.
///
/// `updateMetadata` replaces the whole metadata, so changing one key means
/// reading everything, changing it and writing it all back, as two steps. A
/// writer that commits between them has its work overwritten by the stale copy
/// (on the web the manifest also holds the chunk pointer). A backend that can do
/// the merge atomically implements this; ask for it through [patchMetadata],
/// which falls back for one that cannot.
///
/// The 13-method contract does not change: a backend that does not implement
/// this is still a complete `StorageBackend`.
abstract interface class MetadataPatchableBackend implements StorageBackend {
  /// Set each key in [changes] to its value, remove each mapped to `null`, and
  /// leave everything else (the other metadata keys, the content type, the bytes,
  /// `lastModified`) as it is.
  ///
  /// Atomic where the substrate allows it: IndexedDB merges inside one read-write
  /// transaction, so it keeps whatever the record holds at that instant and cannot
  /// restore a stale chunk pointer, and needs no lock. The filesystem has no
  /// transactions: it merges and replaces the sidecar atomically, but two
  /// concurrent patches, or a patch racing a write to the same key, can lose one;
  /// serialize same-key writes, as for every cellar write.
  ///
  /// Throws [FileNotFoundError] when [key] does not exist.
  Future<void> patchMetadata(String key, Map<String, String?> changes);
}

/// Patch [key]'s metadata on [backend]: atomically when it is a
/// [MetadataPatchableBackend], otherwise by reading the metadata and replacing it
/// with `updateMetadata`, which is **not atomic** (a write between the two steps is
/// overwritten).
///
/// Throws [FileNotFoundError] when [key] does not exist.
Future<void> patchMetadata(
  StorageBackend backend,
  String key,
  Map<String, String?> changes,
) async {
  if (backend is MetadataPatchableBackend) {
    return backend.patchMetadata(key, changes);
  }
  final info = await backend.head(key);
  if (info == null) throw FileNotFoundError(key);
  return backend.updateMetadata(
    key,
    contentType: info.contentType,
    metadata: applyMetadataChanges(info.metadata, changes),
  );
}

/// [metadata] with [changes] applied: a value sets the key, `null` removes it.
Map<String, String> applyMetadataChanges(
  Map<String, String> metadata,
  Map<String, String?> changes,
) {
  final merged = Map<String, String>.of(metadata);
  for (final change in changes.entries) {
    final value = change.value;
    if (value == null) {
      merged.remove(change.key);
    } else {
      merged[change.key] = value;
    }
  }
  return merged;
}
