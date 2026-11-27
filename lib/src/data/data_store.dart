import 'dart:typed_data';

import 'package:cellar/src/core/materialized_file.dart';
import 'package:cellar/src/data/data_entry.dart';

/// A flat store of **bytes only**: a key names an object, and the store knows its length and
/// when it was written, and nothing else. No content type, no caller metadata, no record of
/// how often it is used: that is the metadata store's job, so a listing costs a directory
/// walk and a `stat` and never a second file per object.
///
/// What it keeps from the file system backend: **a write is atomic** (the previous object or
/// the whole new one is at the key, whatever kills the process), bytes **stream** in and out,
/// a range can be read without the rest, and a file can be **adopted by rename**
/// ([importFile]) without copying it.
///
/// It is the data half of a store whose records live elsewhere, so it does not decide what a
/// key means and does not evict. A key follows cellar's key grammar; one that could leave the
/// store's root is refused.
abstract interface class DataStore {
  /// Writes [bytes] at [key], replacing what is there, atomically.
  Future<void> write(String key, Uint8List bytes);

  /// Writes what [bytes] yields at [key], replacing what is there, atomically: a stream
  /// that fails part-way leaves the previous object (or none) and no readable partial one.
  /// [onProgress] is told the bytes written so far.
  Future<void> writeStream(
    String key,
    Stream<List<int>> bytes, {
    void Function(int written)? onProgress,
  });

  /// The object's bytes as a stream. Throws `FileNotFoundError` when there is none.
  Stream<List<int>> readStream(String key);

  /// The whole object. Throws `FileNotFoundError` when there is none.
  Future<Uint8List> read(String key);

  /// [length] bytes of the object from [start], without reading the rest (fewer when the
  /// object ends first). Throws `FileNotFoundError` when there is none.
  Future<Uint8List> readRange(
    String key, {
    required int start,
    required int length,
  });

  /// The size and write time of the object at [key], or null when there is none.
  Future<DataEntry?> stat(String key);

  /// Whether an object is stored at [key].
  Future<bool> exists(String key);

  /// Removes the object at [key]. Harmless when there is none.
  Future<void> delete(String key);

  /// Removes every object whose key starts with [prefix] (an empty prefix removes all of
  /// them, and leaves the store's root in place).
  Future<void> deletePrefix(String prefix);

  /// Every object whose key starts with [prefix], with its size and write time. Reads no
  /// object's bytes. What a crash left half-written is not listed.
  Future<List<DataEntry>> list(String prefix);

  /// Adopts the file at [path] as the object at [key]. With [move] the file is renamed into
  /// place when the rename is possible (the same volume), so no bytes are copied; when it is
  /// not, the file is copied in atomically and the source deleted only after the object exists.
  /// Without it the file is copied and left where it was.
  Future<void> importFile(String key, String path, {bool move = false});

  /// A handle to the object for code that wants a file: a path on native. With [exclusive]
  /// the handle is a private copy the caller may change; release it when done.
  Future<MaterializedFile> materialize(String key, {bool exclusive = false});

  /// Removes what an interrupted write left behind: a temp file older than the grace period,
  /// so a write in progress (this process's, or another's) is never touched. Call it when the
  /// store is opened. Best-effort: what it cannot delete is left.
  Future<void> sweepLeftovers({
    Duration olderThan = const Duration(minutes: 1),
  });

  /// Lets go of the store. Using it afterwards fails.
  Future<void> dispose();
}
