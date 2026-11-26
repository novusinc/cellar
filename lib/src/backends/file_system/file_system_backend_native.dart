import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cellar/src/backends/file_system/os/file_system_os.dart';
import 'package:cellar/src/backends/file_system/os/windows_file_system_os.dart';
import 'package:cellar/src/core/storage_backend.dart';
import 'package:cellar/src/core/dispose_guard.dart';
import 'package:cellar/src/core/errors.dart';
import 'package:cellar/src/core/materialized_file.dart';
import 'package:cellar/src/core/metadata_patchable.dart';
import 'package:cellar/src/core/object_info.dart';
import 'package:cellar/src/core/write_options.dart';

/// Native filesystem [StorageBackend] backed by `dart:io`.
///
/// Keys are `/`-separated paths resolved relative to a base directory:
/// `"device/model/abc/gguf"` → `"{baseDir}/device/model/abc/gguf"`.
///
/// Per-object metadata (content type, custom metadata) lives in sibling
/// `.meta.json` sidecar files next to each object. Sidecars travel with
/// the body on `copy`; no external database is involved.
///
/// `dart:io` only — this class never compiles on web. The web build
/// gets the throwing stub via the conditional re-export in
/// `file_system_backend.dart` (the plain-named switch is the import point).
///
/// ## Per-OS behavior
///
/// This class is OS-blind. Everything that differs between operating
/// systems (delete-while-open semantics, rename-over rules, backup
/// exclusion) goes through the [FileSystemOs] seam — common behavior in
/// [DefaultFileSystemOs], one subclass per OS overriding only its own
/// quirk. Inject a specific OS in tests to exercise its paths anywhere.
///
/// ## iCloud / Time Machine backup exclusion
///
/// Passing `osBackup: false` excludes `_baseDir` from the platform
/// backup: `kCFURLIsExcludedFromBackupKey` via CFURL on iOS (in-
/// sandbox — process spawning is forbidden there), `tmutil addexclusion`
/// on macOS (the supported Time Machine mechanism). On Android / Linux /
/// Windows the flag is a no-op. Applied lazily on the first write —
/// there's no async setup step in the constructor.
class FileSystemBackend with DisposeGuard implements MetadataPatchableBackend {
  /// Create a backend rooted at `baseDir`.
  ///
  /// [osBackup] (default `true`) controls whether the directory
  /// participates in OS backup (iCloud on iOS, Time Machine on macOS).
  /// Pass `false` for partitions whose contents are regenerable (cache,
  /// scratch) so they don't waste the user's backup quota. No-op on
  /// platforms without the concept.
  /// [os] overrides the per-OS behavior seam — tests inject a specific
  /// OS to exercise its paths on any machine.
  FileSystemBackend(this._baseDir, {bool osBackup = true, FileSystemOs? os})
    : _osBackup = osBackup,
      _os = os ?? FileSystemOs.current();

  /// Suffix marking Windows delete-while-open leftovers — see
  /// [WindowsFileSystemOs], the quirk's home.
  static const String tombstoneSuffix = WindowsFileSystemOs.tombstoneSuffix;

  /// Suffix for in-flight streaming-write temp files. The temp is renamed
  /// over the destination only after the source stream completes, so a
  /// failed or interrupted write never leaves a readable partial object.
  /// Filtered from listings like tombstones; a crash leftover is inert.
  static const String writeTempSuffix = '.cellar_write.';

  @override
  String get disposeLabel => 'FileSystemBackend';

  final String _baseDir;
  final bool _osBackup;
  final FileSystemOs _os;
  bool _osBackupApplied = false;

  File _file(String key) => File('$_baseDir/$key');
  File _metaFile(String key) => File('$_baseDir/$key.meta.json');

  /// Apply the backup exclusion if needed. Called lazily from the first
  /// write so the constructor stays sync. Idempotent.
  ///
  /// Only does work when `osBackup: false` was passed AND the OS has a
  /// backup mechanism. Everywhere else this is a no-op marker flip.
  Future<void> _ensureBackupAttribute() async {
    if (_osBackupApplied) return;
    _osBackupApplied = true;

    // Backup is allowed (default) — nothing to do. OSes without the
    // concept answer false from the seam's default implementation.
    if (_osBackup) return;

    try {
      await Directory(_baseDir).create(recursive: true);
      await _os.excludeFromBackup(_baseDir);
    } catch (_) {
      // Best-effort: never fail a write because the backup flag couldn't
      // be set. The dev gets the safe (backed-up) outcome instead.
    }
  }

  /// Sweep up tombstone files (Windows delete-while-open leftovers).
  /// Safe to call any time; no-op on POSIX.
  Future<void> sweepTombstones() async {
    checkNotDisposed();
    await _os.sweepTombstones(_baseDir);
  }

  /// How old a leftover sidecar temp must be before [recoverInterruptedWrites]
  /// deletes one that does not match its body: a write in progress in this process
  /// holds one for milliseconds, and a crash's is older than the process.
  static const Duration _leftoverGrace = Duration(minutes: 1);

  /// Finish or discard the writes a crash interrupted. Call it when a partition is
  /// opened, beside [sweepTombstones].
  ///
  /// A write renames the body into place and then the sidecar, so a crash between
  /// the two leaves a new body and the sidecar's temp file. A leftover sidecar temp
  /// whose recorded identity matches the key's current body is that interrupted
  /// write's, and is renamed into place, which completes it. Any other leftover
  /// (its body was never promoted) is deleted once it is older than a minute.
  /// Best-effort: a file it cannot handle is left, never a failed open.
  ///
  /// Walks the partition once, as [sweepTombstones] does on Windows.
  Future<void> recoverInterruptedWrites() async {
    checkNotDisposed();
    final root = Directory(_baseDir);
    if (!await root.exists()) return;
    const marker = '$_sidecarSuffix$writeTempSuffix';
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final at = entity.path.indexOf(marker);
      if (at <= 0) continue;
      try {
        final bodyPath = entity.path.substring(0, at);
        if (await _sidecarMatchesBody(entity, File(bodyPath))) {
          await _os.renameOver(entity, '$bodyPath$_sidecarSuffix');
        } else if (DateTime.now().difference((await entity.stat()).modified) >
            _leftoverGrace) {
          await _os.deleteFile(entity);
        }
      } on FileSystemException {
        // Left for the next open.
      }
    }
  }

  /// Whether [sidecar] records the identity of [body] as it is now.
  Future<bool> _sidecarMatchesBody(File sidecar, File body) async {
    final stat = await body.stat();
    if (stat.type == FileSystemEntityType.notFound) return false;
    try {
      final meta = jsonDecode(await sidecar.readAsString());
      return meta is Map &&
          meta['size'] == stat.size &&
          meta['bodyModified'] == stat.modified.toUtc().microsecondsSinceEpoch;
    } catch (_) {
      return false;
    }
  }

  static final Random _random = Random.secure();

  /// A fresh temp path beside [filePath]. The suffix is random, not a timestamp:
  /// two writes in the same microsecond, or in two isolates, must never share a
  /// temp file.
  String _writeTempPath(String filePath) {
    final unique = [
      for (var i = 0; i < 4; i++)
        _random.nextInt(0x100000000).toRadixString(16),
    ].join();
    return '$filePath$writeTempSuffix$unique';
  }

  /// Write an object atomically: [fill] writes the complete data into a temp file
  /// beside the key and flushes it; the sidecar is written to a temp file of its
  /// own, recording the body's identity (see [_writeSidecar]); and only when BOTH
  /// are complete is the body renamed over the key, then the sidecar.
  ///
  /// A rename replaces the destination in one step, so a reader, or a crash, sees
  /// the previous object or the whole new one. The two renames are not one step,
  /// so a crash between them leaves the new body beside the old sidecar; the
  /// sidecar's identity no longer matches the body, so readers ignore it (see
  /// [_readMeta]) and [recoverInterruptedWrites] finishes the pair at the next
  /// open. If a step fails before the body is promoted, both temps are removed and
  /// the key is as it was; after it, the sidecar's temp is kept for recovery.
  Future<void> _commit(
    String key,
    Future<void> Function(File temp) fill, {
    required String? contentType,
    required Map<String, String> metadata,
  }) async {
    final dest = _file(key);
    final tempBody = File(_writeTempPath(dest.path));
    File? tempMeta;
    var promoted = false;
    try {
      await fill(tempBody);
      if (_hasMetadata(contentType, metadata)) {
        tempMeta = File(_writeTempPath(_metaFile(key).path));
        await _writeSidecar(
          tempMeta,
          contentType,
          metadata,
          await tempBody.stat(),
        );
      }
      await _os.renameOver(tempBody, dest.path);
      promoted = true;
      if (tempMeta != null) {
        await _os.renameOver(tempMeta, _metaFile(key).path);
      } else {
        // No metadata: an older sidecar belongs to the previous body.
        await _os.deleteFile(_metaFile(key));
      }
    } catch (_) {
      await _discardTemp(tempBody);
      if (!promoted && tempMeta != null) await _discardTemp(tempMeta);
      rethrow;
    }
  }

  /// Delete a temp file; the first failure is the one to report, and an
  /// undeletable temp is inert.
  Future<void> _discardTemp(File temp) async {
    try {
      await _os.deleteFile(temp);
    } on FileSystemException {
      // Inert: listings skip it and the open-time pass reaps it.
    }
  }

  /// Flush [file]'s contents to disk (an `fsync`), so a rename that promotes it
  /// cannot outlive the data on a file system that reorders the two.
  Future<void> _flushToDisk(File file) async {
    final handle = await file.open(mode: FileMode.append);
    try {
      await handle.flush();
    } finally {
      await handle.close();
    }
  }

  // ── Write ──

  @override
  Future<void> writeStream(
    String key,
    Stream<List<int>> byteStream, [
    WriteOptions options = const WriteOptions(),
  ]) async {
    checkNotDisposed();
    await _ensureBackupAttribute();
    final file = _file(key);
    await file.parent.create(recursive: true);

    // Atomic write: stream into a sibling temp, promote by rename only
    // after the source completes. A stream that errors (or a crash) must
    // never leave a readable partial object at the key — a torn cache
    // fill or interrupted upload would otherwise be served as complete.
    await _commit(
      key,
      (temp) async {
        final sink = temp.openWrite();
        var bytesWritten = 0;
        try {
          await for (final chunk in byteStream) {
            sink.add(chunk);
            bytesWritten += chunk.length;
            options.onProgress?.call(bytesWritten, null);
          }
          await sink.close();
        } catch (_) {
          try {
            await sink.close();
          } on FileSystemException {
            // The sink may already be broken; the temp delete is what matters.
          }
          rethrow;
        }
        await _flushToDisk(temp);
      },
      contentType: options.contentType,
      metadata: options.metadata,
    );
  }

  @override
  Future<void> write(
    String key,
    Uint8List bytes, [
    WriteOptions options = const WriteOptions(),
  ]) async {
    checkNotDisposed();
    await _ensureBackupAttribute();
    final file = _file(key);
    await file.parent.create(recursive: true);
    await _commit(
      key,
      (temp) => temp.writeAsBytes(bytes, flush: true),
      contentType: options.contentType,
      metadata: options.metadata,
    );
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
    try {
      return await _file(key).readAsBytes();
    } on FileSystemException {
      // Subtype varies by substrate (PathNotFoundException on the real
      // filesystem, base FileSystemException on dart:io-compatible
      // stand-ins) — decide not-found by existence, then rethrow.
      if (!await _file(key).exists()) throw FileNotFoundError(key);
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
    final RandomAccessFile raf;
    try {
      raf = await _file(key).open(mode: FileMode.read);
    } on FileSystemException {
      // Same substrate-varying subtype as in read() — decide by existence.
      if (!await _file(key).exists()) throw FileNotFoundError(key);
      rethrow;
    }
    try {
      await raf.setPosition(start);
      return await raf.read(length);
    } finally {
      await raf.close();
    }
  }

  // ── Metadata ──

  @override
  Future<ObjectInfo?> head(String key) async {
    checkNotDisposed();
    final file = _file(key);
    if (!await file.exists()) return null;
    final stat = await file.stat();
    final meta = await _readMeta(key, stat);
    return ObjectInfo(
      key: key,
      size: stat.size,
      // Tolerate a corrupt sidecar: non-string values degrade to absent
      // instead of throwing a TypeError out of head().
      contentType: meta?['contentType'] is String
          ? meta!['contentType'] as String
          : null,
      metadata: _castMetadata(meta?['metadata']),
      lastModified: stat.modified.toUtc(),
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
    await _os.deleteFile(_metaFile(key));
  }

  @override
  Future<void> deletePrefix(String prefix) async {
    checkNotDisposed();
    // Empty prefix = wipe everything — but delete the CHILDREN, never
    // the base directory itself: the root carries OS attributes (the
    // backup exclusion) that a delete-and-recreate would silently lose.
    if (prefix.isEmpty) {
      final root = Directory(_baseDir);
      if (await root.exists()) {
        await for (final entity in root.list(followLinks: false)) {
          if (entity is File) {
            await _os.deleteFile(entity);
          } else if (entity is Directory) {
            await _deleteSubtree(entity);
          }
        }
      }
      return;
    }
    // '/'-terminated prefixes map exactly to a directory subtree —
    // recursive delete fast path.
    if (prefix.endsWith('/')) {
      await _deleteSubtree(Directory('$_baseDir/$prefix'));
      return;
    }
    // Bare prefix — RAW semantics: the object at `prefix` itself, the
    // subtree under `prefix/`, and every sibling entry sharing the
    // partial segment (photos → photos_old/, photos2, photos2.meta.json).
    final parent = Directory(
      '$_baseDir/${prefix.substring(0, prefix.lastIndexOf('/') + 1)}',
    );
    if (!await parent.exists()) return;
    final fullPrefix = _keyForm('$_baseDir/$prefix');
    await for (final entity in parent.list(followLinks: false)) {
      if (!_keyForm(entity.path).startsWith(fullPrefix)) continue;
      if (entity is File) {
        await _os.deleteFile(entity);
      } else if (entity is Directory) {
        await _deleteSubtree(entity);
      }
    }
  }

  /// Recursive directory delete honoring Windows tombstones: try the fast
  /// whole-tree delete; when held files block it (Windows), fall back to
  /// per-file safe deletes and a best-effort rmdir.
  Future<void> _deleteSubtree(Directory dir) async {
    if (!await dir.exists()) return;
    try {
      await dir.delete(recursive: true);
      return;
    } on FileSystemException {
      // Fall through to per-file deletion with tombstone fallback.
    }
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) await _os.deleteFile(entity);
    }
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // Some files may have been tombstoned and still hold the dir open.
      // Sweep will pick them up later.
    }
  }

  // ── List ──

  @override
  Future<List<ObjectInfo>> list(String prefix) async {
    checkNotDisposed();
    final keys = await _listKeys(prefix);
    final results = <ObjectInfo>[];
    for (final key in keys) {
      final info = await head(key);
      if (info != null) results.add(info);
    }
    return results;
  }

  // ── Copy ──

  @override
  Future<void> copy(String sourceKey, String destKey) async {
    checkNotDisposed();
    final dest = _file(destKey);
    await dest.parent.create(recursive: true);
    // The destination gets the source's content type and metadata, and nothing
    // of its own previous object's (a source with none clears the key's).
    final source = await _readMeta(sourceKey, await _file(sourceKey).stat());
    // dart:io removes an existing destination before copying onto it, so a
    // copy straight to the key could leave it truncated or gone. Copy beside it
    // and promote by rename, as every other write does.
    await _commit(
      destKey,
      (temp) async {
        await _file(sourceKey).copy(temp.path);
        await _flushToDisk(temp);
      },
      contentType: source?['contentType'] is String
          ? source!['contentType'] as String
          : null,
      metadata: _castMetadata(source?['metadata']),
    );
  }

  // ── Metadata update ──

  @override
  Future<void> updateMetadata(
    String key, {
    String? contentType,
    Map<String, String> metadata = const {},
  }) async {
    checkNotDisposed();
    final stat = await _file(key).stat();
    if (stat.type == FileSystemEntityType.notFound) {
      throw FileNotFoundError(key);
    }
    await _replaceSidecar(key, contentType, metadata, stat);
  }

  /// Merge [changes] into the sidecar and replace it atomically; the body, its
  /// content type and its `lastModified` are not touched. The sidecar is read and
  /// replaced in two steps, so a concurrent patch of the same key, or a write to it,
  /// can lose one of them: same-key writes are the caller's to serialize.
  @override
  Future<void> patchMetadata(String key, Map<String, String?> changes) async {
    checkNotDisposed();
    final stat = await _file(key).stat();
    if (stat.type == FileSystemEntityType.notFound) {
      throw FileNotFoundError(key);
    }
    final current = await _readMeta(key, stat);
    final contentType = current?['contentType'];
    await _replaceSidecar(
      key,
      contentType is String ? contentType : null,
      applyMetadataChanges(_castMetadata(current?['metadata']), changes),
      stat,
    );
  }

  /// Replace [key]'s sidecar with one holding [contentType] and [metadata] (or
  /// none at all when both are empty), for the body whose `stat` is [stat].
  Future<void> _replaceSidecar(
    String key,
    String? contentType,
    Map<String, String> metadata,
    FileStat stat,
  ) async {
    if (!_hasMetadata(contentType, metadata)) {
      await _os.deleteFile(_metaFile(key));
      return;
    }
    // Written beside the sidecar and renamed over it, so a crash leaves the old
    // sidecar or the new one, never a truncated one.
    final temp = File(_writeTempPath(_metaFile(key).path));
    try {
      await _writeSidecar(temp, contentType, metadata, stat);
      await _os.renameOver(temp, _metaFile(key).path);
    } catch (_) {
      await _discardTemp(temp);
      rethrow;
    }
  }

  // ── Internal: metadata sidecar ──

  static const String _sidecarSuffix = '.meta.json';

  bool _hasMetadata(String? contentType, Map<String, String> metadata) =>
      contentType != null || metadata.isNotEmpty;

  /// Write [file] as a sidecar for a body whose `stat` is [body], flushed.
  ///
  /// Besides the content type and metadata (which cannot be derived from the
  /// bytes), it records the body's identity: its size and modification time. A
  /// rename preserves the modification time, so the identity of a finished temp
  /// body is the identity of the key once it is promoted. [_readMeta] compares it
  /// with the body on disk, so a sidecar that belongs to a different body is never
  /// believed.
  Future<void> _writeSidecar(
    File file,
    String? contentType,
    Map<String, String> metadata,
    FileStat body,
  ) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({
        'contentType': contentType,
        'metadata': metadata,
        'size': body.size,
        'bodyModified': body.modified.toUtc().microsecondsSinceEpoch,
      }),
      flush: true,
    );
  }

  /// The sidecar of [key], or null when there is none or it does not belong to the
  /// body whose `stat` is [body].
  ///
  /// A sidecar that records an identity is believed only if the body still has that
  /// size and modification time; otherwise it is the previous object's (a crash
  /// between the two renames of a write) and reads as absent, never as wrong
  /// metadata. A sidecar without one (written by cellar 1.0.0) is believed as it
  /// always was. An unparseable one is deleted, as before.
  Future<Map<String, dynamic>?> _readMeta(String key, FileStat body) async {
    final metaFile = _metaFile(key);
    if (!await metaFile.exists()) return null;
    final Map<String, dynamic> meta;
    try {
      meta = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      // The body is the source of truth for its bytes, but not for its content
      // type or metadata; those are lost with the sidecar. Delete the unparseable
      // one so the next write rebuilds it cleanly, and read as if none existed.
      try {
        await metaFile.delete();
      } on FileSystemException {
        // Sidecar cleanup is best-effort; the next write overwrites it.
      }
      return null;
    }
    final size = meta['size'];
    final modified = meta['bodyModified'];
    if (size is int && modified is int) {
      final matches =
          size == body.size &&
          modified == body.modified.toUtc().microsecondsSinceEpoch;
      if (!matches) return null;
    }
    return meta;
  }

  Map<String, String> _castMetadata(Object? raw) {
    // Validate eagerly. A lazy `.cast<String, String>()` view would throw
    // a TypeError at some distant read site the first time a corrupt
    // sidecar carries a non-string value; dropping bad entries here keeps
    // corruption degradation local, like the rest of the sidecar handling.
    if (raw is! Map) return const {};
    return {
      for (final entry in raw.entries)
        if (entry.key is String && entry.value is String)
          entry.key as String: entry.value as String,
    };
  }

  // ── Internal: key listing (excludes .meta.json sidecars + tombstones) ──

  /// Platform path → key form. Directory.list returns `\`-separated
  /// paths on Windows; keys are always `/`-separated (the grammar forbids
  /// `\`), so both prefix filtering and key reconstruction compare in
  /// key form.
  String _keyForm(String path) => path.replaceAll('\\', '/');

  bool _isUserFile(String path) {
    if (path.endsWith('.meta.json')) return false;
    if (path.contains(tombstoneSuffix)) return false;
    if (path.contains(writeTempSuffix)) return false;
    return true;
  }

  Future<List<String>> _listKeys(String prefix) async {
    // RAW string-prefix contract: walk the deepest directory that fully
    // contains every candidate (the prefix's last full segment), filter by
    // raw path prefix. One pass covers subtree keys ('photos/'), siblings
    // sharing a partial segment ('photos' matching photos_old/x, photos2),
    // and arbitrarily deep keys under either.
    final parent = Directory(
      '$_baseDir/${prefix.substring(0, prefix.lastIndexOf('/') + 1)}',
    );
    if (!await parent.exists()) return [];
    final fullPrefix = _keyForm('$_baseDir/$prefix');
    final keys = <String>[];
    await for (final entity in parent.list(
      recursive: true,
      followLinks: false,
    )) {
      final path = _keyForm(entity.path);
      if (entity is File && path.startsWith(fullPrefix) && _isUserFile(path)) {
        keys.add(path.substring(fullPrefix.length - prefix.length));
      }
    }
    return keys;
  }

  // ── Materialize ──

  /// Materialize on the local filesystem.
  ///
  /// This backend stores raw bytes and knows nothing about encryption —
  /// the [decrypt] flag is accepted for interface compliance but has no
  /// effect here. When an `EncryptedBackend` wraps this backend it
  /// intercepts [materialize] and applies the decrypt semantics BEFORE
  /// delegating. Callers holding a bare [FileSystemBackend] always get the
  /// raw on-disk bytes back.
  @override
  Future<MaterializedFile> materialize(
    String key, {
    bool decrypt = true,
    bool exclusive = false,
  }) async {
    checkNotDisposed();
    final file = _file(key);
    if (!file.existsSync()) {
      throw FileNotFoundError(key);
    }

    if (!exclusive) {
      // Shared access — return the original path. Zero copy.
      return MaterializedFile(
        localPath: file.path,
        key: key,
        release: () async {}, // no-op — original stays
      );
    }

    // Exclusive — copy to a temp file the caller owns.
    final tempDir = await Directory.systemTemp.createTemp('cellar_');
    final tempFile = File('${tempDir.path}/${file.path.split('/').last}');
    await file.copy(tempFile.path);

    return MaterializedFile(
      localPath: tempFile.path,
      key: key,
      release: () async {
        // Best-effort: an undeletable temp is orphaned in systemTemp,
        // which the OS reclaims.
        try {
          await tempFile.delete();
        } on FileSystemException {
          return;
        }
        try {
          await tempDir.delete();
        } on FileSystemException {
          // Non-empty or held — the OS temp reaper owns it now.
        }
      },
    );
  }

  // ── Lifecycle ──

  @override
  Future<void> dispose() async {
    // The filesystem needs no releasing — dispose just arms the guard so
    // use-after-dispose fails fast instead of racing a torn-down owner.
    markDisposed();
  }
}
