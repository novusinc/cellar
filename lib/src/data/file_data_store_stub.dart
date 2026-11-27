import 'dart:typed_data';

import 'package:cellar/src/core/dispose_guard.dart';
import 'package:cellar/src/core/materialized_file.dart';
import 'package:cellar/src/data/data_entry.dart';
import 'package:cellar/src/data/data_store.dart';

/// Web stub for the native-only [FileDataStore]: the constructor throws. It mirrors the native
/// class's cross-platform surface so code that compiles for both analyzes against one shape;
/// the native constructor's `os:` seam (dart:io-typed) is the one gap, and tests of the native
/// implementation import it directly.
class FileDataStore with DisposeGuard implements DataStore {
  /// Throws [UnsupportedError]: native files need `dart:io`.
  FileDataStore(String baseDir, {bool osBackup = true}) {
    throw UnsupportedError(
      'FileDataStore($baseDir, osBackup: $osBackup) requires dart:io and is '
      'not available on web.',
    );
  }

  /// Mirrors the native constant.
  static const String writeTempSuffix = '.cellar_write.';

  /// Mirrors the native constant.
  static const String tombstoneSuffix = '.cellar_tombstone.';

  @override
  String get disposeLabel => 'FileDataStore';

  Never _unsupported() => throw UnsupportedError('stub');

  @override
  Future<void> write(String key, Uint8List bytes) async => _unsupported();

  @override
  Future<void> writeStream(
    String key,
    Stream<List<int>> bytes, {
    void Function(int written)? onProgress,
  }) async => _unsupported();

  @override
  Stream<List<int>> readStream(String key) => _unsupported();

  @override
  Future<Uint8List> read(String key) async => _unsupported();

  @override
  Future<Uint8List> readRange(
    String key, {
    required int start,
    required int length,
  }) async => _unsupported();

  @override
  Future<DataEntry?> stat(String key) async => _unsupported();

  @override
  Future<bool> exists(String key) async => _unsupported();

  @override
  Future<void> delete(String key) async => _unsupported();

  @override
  Future<void> deletePrefix(String prefix) async => _unsupported();

  @override
  Future<List<DataEntry>> list(String prefix) async => _unsupported();

  @override
  Future<void> importFile(String key, String path, {bool move = false}) async =>
      _unsupported();

  @override
  Future<MaterializedFile> materialize(
    String key, {
    bool exclusive = false,
  }) async => _unsupported();

  @override
  Future<void> sweepLeftovers({
    Duration olderThan = const Duration(minutes: 1),
  }) async => _unsupported();

  @override
  Future<void> dispose() async {
    markDisposed();
  }
}
