import 'package:cellar/src/core/errors.dart';
import 'package:cellar/src/core/storage_backend.dart';

/// An optional capability of a [StorageBackend]: move an object to another key in
/// one step, without copying its bytes.
///
/// `Cellar.move` is a copy followed by a delete, which for a large file needs the
/// space twice, takes as long as a copy, and leaves both objects if it is
/// interrupted between the two steps. A backend that can rename (the filesystem
/// backend, within one partition) offers this instead; [moveObject] uses it when
/// there and falls back to copy then delete when not, so the 13-method contract
/// does not change.
abstract interface class MovableBackend implements StorageBackend {
  /// Move [sourceKey] to [destKey], replacing what is there, keeping the bytes,
  /// content type and metadata. Throws `FileNotFoundError` when [sourceKey] does
  /// not exist. Moving a key onto itself leaves it as it is.
  ///
  /// The bytes are never in two places and never copied. An interruption leaves the
  /// object at [sourceKey] (nothing moved) or at [destKey] (moved, though a
  /// leftover of its metadata may need the next open to finish).
  Future<void> move(String sourceKey, String destKey);
}

/// Move [sourceKey] to [destKey] on [backend]: in one step when it is a
/// [MovableBackend], otherwise by copying and then deleting, which is **not
/// atomic** (an interruption between the two leaves both). Moving a key onto
/// itself leaves it as it is, and throws [FileNotFoundError] if it is absent.
Future<void> moveObject(
  StorageBackend backend,
  String sourceKey,
  String destKey,
) async {
  if (backend is MovableBackend) return backend.move(sourceKey, destKey);
  if (sourceKey == destKey) {
    // Copy then delete would copy the object onto itself and then delete it.
    if (!await backend.exists(sourceKey)) throw FileNotFoundError(sourceKey);
    return;
  }
  await backend.copy(sourceKey, destKey);
  await backend.delete(sourceKey);
}
