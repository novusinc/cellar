import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cellar/src/backends/file_system/os/file_system_os.dart';
import 'package:cellar/src/backends/file_system/os/windows_file_system_os.dart';
import 'package:cellar/src/core/dispose_guard.dart';
import 'package:cellar/src/core/errors.dart';
import 'package:cellar/src/core/key_validation.dart';
import 'package:cellar/src/core/materialized_file.dart';
import 'package:cellar/src/data/data_entry.dart';
import 'package:cellar/src/data/data_store.dart';

/// A [DataStore] over native files (`dart:io`): the key is the path under a base directory,
/// and an object is **one file**, with no sidecar beside it, so a write is one flush and one
/// rename, and a listing is a walk and a `stat`.
///
/// The write protocol is the file system backend's: the bytes go to a temp file beside the
/// key, are flushed to disk, and are renamed over the key only when complete, so a reader (or
/// a crash) sees the previous object or the whole new one. A temp that a crash left is inert:
/// listings skip it and [sweepLeftovers] removes it once it is old enough that no write can
/// still own it.
///
/// Everything that differs between operating systems goes through the [FileSystemOs] seam,
/// as in the file system backend (delete-while-open on Windows, backup exclusion on Apple
/// platforms). `dart:io` only: the web gets the throwing stub through the conditional export.
class FileDataStore with DisposeGuard implements DataStore {
  /// A store rooted at `baseDir`. `osBackup` false keeps the directory out of the platform's
  /// backup (iCloud, Time Machine), applied on the first write; a no-op where there is no such
  /// thing. `os` replaces the per-OS behaviour, so a test can inject a fault.
  FileDataStore(this._baseDir, {bool osBackup = true, FileSystemOs? os})
    : _osBackup = osBackup,
      _os = os ?? FileSystemOs.current();

  /// Marks the temp file of a write in progress, as in the file system backend.
  static const String writeTempSuffix = '.cellar_write.';

  /// Marks a Windows delete-while-open leftover.
  static const String tombstoneSuffix = WindowsFileSystemOs.tombstoneSuffix;

  @override
  String get disposeLabel => 'FileDataStore';

  final String _baseDir;
  final bool _osBackup;
  final FileSystemOs _os;
  bool _osBackupApplied = false;

  static final Random _random = Random.secure();

  File _file(String key) {
    validateKey(key);
    return File('$_baseDir/$key');
  }

  Future<void> _ensureBackupAttribute() async {
    if (_osBackupApplied) return;
    _osBackupApplied = true;
    if (_osBackup) return;
    try {
      await Directory(_baseDir).create(recursive: true);
      await _os.excludeFromBackup(_baseDir);
    } catch (_) {
      // Best-effort: a write is never failed because the flag could not be set.
    }
  }

  /// A fresh temp path beside [filePath]. The suffix is random, not a timestamp: two writes in
  /// the same microsecond, or in two isolates, never share a temp file.
  String _writeTempPath(String filePath) {
    final unique = [
      for (var i = 0; i < 4; i++)
        _random.nextInt(0x100000000).toRadixString(16),
    ].join();
    return '$filePath$writeTempSuffix$unique';
  }

  /// Flushes [file] to disk (an `fsync`), so the rename that promotes it cannot outlive the
  /// data on a file system that reorders the two.
  Future<void> _flushToDisk(File file) async {
    final handle = await file.open(mode: FileMode.append);
    try {
      await handle.flush();
    } finally {
      await handle.close();
    }
  }

  /// Writes the object atomically: [fill] writes the whole content into a temp beside the key
  /// and flushes it, and only then is the temp renamed over the key. If a step fails, the temp is
  /// removed and the key is as it was.
  Future<void> _commit(
    String key,
    Future<void> Function(File temp) fill,
  ) async {
    final dest = _file(key);
    await _ensureBackupAttribute();
    await dest.parent.create(recursive: true);
    final temp = File(_writeTempPath(dest.path));
    try {
      await fill(temp);
      await _os.renameOver(temp, dest.path);
    } catch (_) {
      await _discardTemp(temp);
      rethrow;
    }
  }

  Future<void> _discardTemp(File temp) async {
    try {
      await _os.deleteFile(temp);
    } on FileSystemException {
      // Inert: listings skip it and sweepLeftovers reaps it.
    }
  }

  // ── Write ──

  @override
  Future<void> write(String key, Uint8List bytes) async {
    checkNotDisposed();
    await _commit(key, (temp) => temp.writeAsBytes(bytes, flush: true));
  }

  @override
  Future<void> writeStream(
    String key,
    Stream<List<int>> bytes, {
    void Function(int written)? onProgress,
  }) async {
    checkNotDisposed();
    await _commit(key, (temp) async {
      final sink = temp.openWrite();
      var written = 0;
      try {
        await for (final chunk in bytes) {
          sink.add(chunk);
          written += chunk.length;
          onProgress?.call(written);
        }
        await sink.close();
      } catch (_) {
        try {
          await sink.close();
        } on FileSystemException {
          // The sink may already be broken; deleting the temp is what matters.
        }
        rethrow;
      }
      await _flushToDisk(temp);
    });
  }

  // ── Read ──

  @override
  Stream<List<int>> readStream(String key) async* {
    checkNotDisposed();
    final file = _file(key);
    if (!await file.exists()) throw FileNotFoundError(key);
    yield* file.openRead();
  }

  @override
  Future<Uint8List> read(String key) async {
    checkNotDisposed();
    final file = _file(key);
    try {
      return await file.readAsBytes();
    } on FileSystemException {
      // The subtype varies by substrate: decide not-found by existence, then rethrow.
      if (!await file.exists()) throw FileNotFoundError(key);
      rethrow;
    }
  }

  @override
  Future<Uint8List> readRange(
    String key, {
    required int start,
    required int length,
  }) async {
    checkNotDisposed();
    final file = _file(key);
    final RandomAccessFile raf;
    try {
      raf = await file.open(mode: FileMode.read);
    } on FileSystemException {
      if (!await file.exists()) throw FileNotFoundError(key);
      rethrow;
    }
    try {
      await raf.setPosition(start);
      return await raf.read(length);
    } finally {
      await raf.close();
    }
  }

  @override
  Future<DataEntry?> stat(String key) async {
    checkNotDisposed();
    final file = _file(key);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) return null;
    return DataEntry(
      key: key,
      size: stat.size,
      modified: stat.modified.toUtc(),
    );
  }

  @override
  Future<bool> exists(String key) {
    checkNotDisposed();
    return _file(key).exists();
  }

  // ── Delete ──

  @override
  Future<void> delete(String key) async {
    checkNotDisposed();
    await _os.deleteFile(_file(key));
  }

  @override
  Future<void> deletePrefix(String prefix) async {
    checkNotDisposed();
    validatePrefix(prefix);
    // An empty prefix removes the children, never the base directory itself: the root
    // carries OS attributes (the backup exclusion) that a delete and recreate would lose.
    if (prefix.isEmpty) {
      final root = Directory(_baseDir);
      if (await root.exists()) {
        await for (final entity in root.list(followLinks: false)) {
          await _deleteEntity(entity);
        }
      }
      return;
    }
    // A prefix ending in '/' is exactly a directory subtree.
    if (prefix.endsWith('/')) {
      await _deleteSubtree(Directory('$_baseDir/$prefix'));
      return;
    }
    // A bare prefix is a raw string prefix: the object named by it, the subtree under it
    // and every sibling that shares the partial segment.
    final parent = Directory(
      '$_baseDir/${prefix.substring(0, prefix.lastIndexOf('/') + 1)}',
    );
    if (!await parent.exists()) return;
    final fullPrefix = _keyForm('$_baseDir/$prefix');
    await for (final entity in parent.list(followLinks: false)) {
      if (!_keyForm(entity.path).startsWith(fullPrefix)) continue;
      await _deleteEntity(entity);
    }
  }

  Future<void> _deleteEntity(FileSystemEntity entity) async {
    if (entity is File) {
      await _os.deleteFile(entity);
    } else if (entity is Directory) {
      await _deleteSubtree(entity);
    }
  }

  /// Deletes a directory tree, honouring Windows tombstones: the fast whole-tree delete first,
  /// and per-file safe deletes when held files block it.
  Future<void> _deleteSubtree(Directory dir) async {
    if (!await dir.exists()) return;
    try {
      await dir.delete(recursive: true);
      return;
    } on FileSystemException {
      // Fall through to per-file deletion with a tombstone fallback.
    }
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) await _os.deleteFile(entity);
    }
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // A tombstoned file may still hold the directory; sweepLeftovers reaps it.
    }
  }

  // ── List ──

  /// How many files a listing `stat`s at once: they wait on the disk and not on each other,
  /// and a bound keeps a listing of thousands from opening thousands of files together.
  static const int _listConcurrency = 16;

  /// Path separators differ on Windows, keys never do.
  String _keyForm(String path) => path.replaceAll('\\', '/');

  bool _isObject(String path) =>
      !path.contains(tombstoneSuffix) && !path.contains(writeTempSuffix);

  @override
  Future<List<DataEntry>> list(String prefix) async {
    checkNotDisposed();
    validatePrefix(prefix);
    // The deepest directory that fully contains every candidate; filter by raw prefix. One
    // pass covers a subtree, siblings that share a partial segment, and anything under both.
    final parent = Directory(
      '$_baseDir/${prefix.substring(0, prefix.lastIndexOf('/') + 1)}',
    );
    if (!await parent.exists()) return [];
    final fullPrefix = _keyForm('$_baseDir/$prefix');
    final files = <File>[];
    await for (final entity in parent.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final path = _keyForm(entity.path);
      if (path.startsWith(fullPrefix) && _isObject(path)) files.add(entity);
    }
    final root = _keyForm(_baseDir);
    final entries = <DataEntry>[];
    for (var i = 0; i < files.length; i += _listConcurrency) {
      final batch = files.skip(i).take(_listConcurrency);
      final stats = await Future.wait(batch.map((f) => f.stat()));
      var n = 0;
      for (final file in batch) {
        final stat = stats[n++];
        // A file deleted between the walk and the stat is simply not there.
        if (stat.type != FileSystemEntityType.file) continue;
        entries.add(
          DataEntry(
            key: _keyForm(file.path).substring(root.length + 1),
            size: stat.size,
            modified: stat.modified.toUtc(),
          ),
        );
      }
    }
    return entries;
  }

  // ── Import ──

  @override
  Future<void> importFile(String key, String path, {bool move = false}) async {
    checkNotDisposed();
    final dest = _file(key);
    await _ensureBackupAttribute();
    final source = File(path);
    final stat = await source.stat();
    if (stat.type != FileSystemEntityType.file) throw FileNotFoundError(path);
    if (await dest.exists() &&
        await FileSystemEntity.identical(source.path, dest.path)) {
      throw ArgumentError.value(
        path,
        'path',
        'is the file already stored at "$key"',
      );
    }
    await dest.parent.create(recursive: true);
    if (move) {
      try {
        // Same volume: the file itself becomes the object, no bytes are copied. The rename is
        // atomic, so the key holds the previous object or the whole new one.
        await _os.renameOver(source, dest.path);
        return;
      } on FileSystemException {
        // Refused (another volume): the source is intact, since a refused rename moves
        // nothing, so fall through to a copy.
      }
    }
    await _commit(key, (temp) async {
      await source.copy(temp.path);
      await _flushToDisk(temp);
    });
    // The source goes only now that the object exists.
    if (move) await _os.deleteFile(source);
  }

  // ── Materialize ──

  @override
  Future<MaterializedFile> materialize(
    String key, {
    bool exclusive = false,
  }) async {
    checkNotDisposed();
    final file = _file(key);
    if (!file.existsSync()) throw FileNotFoundError(key);
    if (!exclusive) {
      // Shared: the object's own path, no copy. Release is a no-op.
      return MaterializedFile(
        localPath: file.path,
        key: key,
        release: () async {},
      );
    }
    // Exclusive: a private copy the caller owns.
    final tempDir = await Directory.systemTemp.createTemp('cellar_');
    final tempFile = File('${tempDir.path}/${file.path.split('/').last}');
    await file.copy(tempFile.path);
    return MaterializedFile(
      localPath: tempFile.path,
      key: key,
      release: () async {
        try {
          await tempFile.delete();
        } on FileSystemException {
          return; // The OS temp reaper owns it now.
        }
        try {
          await tempDir.delete();
        } on FileSystemException {
          // Non-empty or held: left to the OS.
        }
      },
    );
  }

  // ── Housekeeping ──

  @override
  Future<void> sweepLeftovers({
    Duration olderThan = const Duration(minutes: 1),
  }) async {
    checkNotDisposed();
    final root = Directory(_baseDir);
    if (!await root.exists()) return;
    await _os.sweepTombstones(_baseDir);
    final cutoff = DateTime.now().subtract(olderThan);
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.contains(writeTempSuffix)) continue;
      try {
        if ((await entity.stat()).modified.isBefore(cutoff)) {
          await _os.deleteFile(entity);
        }
      } on FileSystemException {
        // Best-effort: what it cannot handle is left, never a failed open.
      }
    }
  }

  @override
  Future<void> dispose() async {
    markDisposed();
  }
}
