import 'package:cellar/src/core/storage_backend.dart';
import 'package:cellar/src/core/write_options.dart';

/// An optional capability of a [StorageBackend]: store a file that already exists
/// on the device's file system as an object, without reading its bytes through the
/// application.
///
/// `write` takes bytes and `writeStream` a stream. A file that is already on disk
/// (a 500 MB video an encoder just wrote, a picked file in the system's temp
/// folder) would have to be read and written again, so every byte is copied and the
/// file exists twice for a moment. [importFile] takes a **path in** instead, and
/// exposes none: where the object lives stays the backend's business.
///
/// Native only by nature; the web has no file paths. The interface itself has no
/// platform types, so code that holds a backend can ask for it everywhere.
abstract interface class ImportableBackend implements StorageBackend {
  /// Store the file at [path] under [key], replacing what is there.
  ///
  /// With [move] the file is handed over: it is renamed into the store when it is on
  /// the same volume (no copy at all), and otherwise copied in and then deleted.
  /// Without it the file is copied in and left where it is. Either way the write is
  /// atomic: an interruption leaves [key]'s previous object, or the whole new one,
  /// and with [move] never loses the source before the object exists.
  ///
  /// [options] supply the content type and metadata. Throws `FileNotFoundError`
  /// naming [path] when there is no such file.
  Future<void> importFile(
    String key,
    String path, {
    bool move = false,
    WriteOptions options = const WriteOptions(),
  });
}
