import 'dart:typed_data';

import 'package:cellar/src/core/storage_backend.dart';
import 'package:cellar/src/core/dispose_guard.dart';
import 'package:cellar/src/core/materialized_file.dart';
import 'package:cellar/src/core/object_info.dart';
import 'package:cellar/src/core/write_options.dart';
import 'package:cellar/src/core/errors.dart';
import 'package:cellar/src/core/metadata_keys.dart';
import 'package:cellar/src/core/metadata_patchable.dart' as patch;

/// A backing that can list just the records whose key ends with a suffix, without
/// touching the others.
///
/// [ChunkedBackend] lists an object by its manifest record and ignores the many
/// chunk records beside it. A backing whose `list` has to read every record's body
/// to answer (IndexedDB's does) implements this so a listing reads only the
/// manifests, whose bodies are empty. A backing that lists cheaply need not.
abstract interface class SuffixListableBackend implements StorageBackend {
  /// The records under [prefix] whose key ends with [suffix], as `list` would
  /// report them (keys are the stored, unchunked record keys).
  Future<List<ObjectInfo>> listEndingWith(String prefix, String suffix);
}

/// Generic chunked storage layer.
///
/// Wraps a backing [StorageBackend] (any platform — local files,
/// IndexedDB, a remote store, in-memory) and stores each logical key as N+1
/// records, with the chunk records tagged by a write generation:
///
/// ```
/// {key}__manifest      → { generation, chunkCount, totalSize,
///                          contentType, metadata }
/// {key}__g{G}__c0      → { body: Uint8List (≤ chunkSize) }
/// {key}__g{G}__c1      → { body: Uint8List (≤ chunkSize) }
/// ...
/// {key}__g{G}__c{N-1}  → { body: Uint8List (≤ chunkSize) }
/// ```
///
/// The chunking algorithm lives here; the storage primitives live in
/// the backing backend. This separation keeps the algorithm
/// platform-independent (testable on any VM) and means individual
/// backends don't reinvent it.
///
/// ## What this layer guarantees
///
/// - `writeStream` is true streaming — buffers one [chunkSize]
///   chunk at a time, flushes, then writes the manifest LAST.
/// - `readStream` yields chunk-by-chunk — O(chunkSize) memory.
/// - `head`/`exists`/`list` use the manifest only — no body reads.
/// - `readRange` decodes only the chunks that overlap the requested
///   range.
/// - A crash mid-FIRST-write leaves the manifest absent →
///   `head`/`exists`/`list`/`read` all behave as if the key never
///   existed.
/// - A crash (or stream failure) mid-OVERWRITE leaves the previous
///   object fully intact: each write lands its chunks under a fresh
///   generation, swaps the manifest last, and only then reclaims the
///   previous generation's chunks. Without generations, an overwrite
///   would clobber the old chunk records in place and a mid-write
///   failure would serve a torn mix of old and new bytes.
/// - A write that fails removes the chunks it wrote, at once (a full quota
///   must not be left holding the failed attempt's data). If that cannot
///   happen (a crash), the leftovers share the generation number the NEXT
///   write of that key will use: it sweeps them before writing, so a shorter
///   object does not leave their tail behind, and a delete removes the
///   current generation and the one after it, so no record of the key
///   outlives it. A chunk is removed by its generation's key prefix, never by
///   the manifest's count.
///
/// ## Atomicity caveats
///
/// The backing backend is not assumed to provide multi-key
/// transactions. Two callers writing to the SAME key concurrently can
/// interleave each other's chunk writes; that's a caller-side
/// serialization concern (the [StorageBackend] interface already
/// notes this on every backend).
///
/// ## materialize
///
/// Not implemented at this layer because how to materialize an
/// arbitrarily-large object as a platform-local handle is
/// platform-specific (filesystem path on native, Blob URL on web).
/// Subclasses or wrapping decorators provide it.
class ChunkedBackend
    with DisposeGuard
    implements patch.MetadataPatchableBackend {
  /// Wrap [backing], splitting every object into [chunkSize]-byte records.
  ChunkedBackend({
    required StorageBackend backing,
    this.chunkSize = defaultChunkSize,
  }) : _backing = backing;

  /// Default chunk size — 64 KiB.
  ///
  /// Picked to balance three things on web (the most constrained
  /// backend): IndexedDB record overhead per write, JS heap pressure
  /// per chunk in flight, and the typical encryption chunk size used
  /// by streaming AEAD constructions (which lets a chunked-then-
  /// encrypted pipeline align without re-buffering). Override via the
  /// constructor for workloads with different trade-offs.
  static const int defaultChunkSize = 64 * 1024;

  /// Suffix for the per-key manifest record. Distinct from the chunk
  /// markers, short, obvious in any storage browser.
  static const String manifestSuffix = '__manifest';

  /// Generation marker in a chunk record's key. The write generation
  /// follows it; `__c{index}` follows the generation.
  static const String generationPrefix = '__g';

  /// Per-chunk record marker. The chunk index follows it.
  static const String chunkPrefix = '__c';

  final StorageBackend _backing;

  /// Plaintext bytes per chunk record.
  final int chunkSize;

  /// The backing backend — exposed for subclasses that need to add
  /// platform-specific operations (e.g. [materialize]) on top.
  StorageBackend get backing => _backing;

  /// The manifest for [key], or null when the object doesn't exist.
  /// For subclasses whose [materialize] reads chunk records directly.
  Future<ChunkedManifest?> manifestFor(String key) => _readManifest(key);

  /// The backing-record key of chunk [index] in [generation] of [key].
  /// For subclasses whose [materialize] reads chunk records directly —
  /// pair with [manifestFor] to get the current generation.
  String chunkKeyFor(String key, int generation, int index) =>
      '$key$generationPrefix$generation$chunkPrefix$index';

  // Internal record key builders.
  String _manifestKey(String key) => '$key$manifestSuffix';

  // ══════════════════════════════════════════════════════════════════════
  // WRITE
  // ══════════════════════════════════════════════════════════════════════

  @override
  Future<void> write(
    String key,
    Uint8List bytes, [
    WriteOptions options = const WriteOptions(),
  ]) async {
    checkNotDisposed();
    final previous = await _readManifest(key);
    final generation = await _clearLeftovers(key, previous);
    try {
      final chunkCount = await _writeChunksFromBytes(key, generation, bytes);
      await _writeManifest(
        key,
        generation: generation,
        chunkCount: chunkCount,
        totalSize: bytes.length,
        contentType: options.contentType,
        metadata: options.metadata,
      );
    } catch (_) {
      await _reclaimFailed(key, generation);
      rethrow;
    }
    await _deleteGeneration(key, previous);
  }

  @override
  Future<void> writeStream(
    String key,
    Stream<List<int>> byteStream, [
    WriteOptions options = const WriteOptions(),
  ]) async {
    checkNotDisposed();
    final previous = await _readManifest(key);
    final generation = await _clearLeftovers(key, previous);
    var index = 0;
    var totalSize = 0;
    final buffer = BytesBuilder(copy: false);

    Future<void> flush() async {
      if (buffer.isEmpty) return;
      final chunk = buffer.takeBytes();
      await _putChunk(key, generation, index, chunk);
      index++;
    }

    try {
      await for (final chunk in byteStream) {
        var offset = 0;
        while (offset < chunk.length) {
          final remaining = chunkSize - buffer.length;
          final take = (chunk.length - offset) < remaining
              ? chunk.length - offset
              : remaining;
          buffer.add(chunk.sublist(offset, offset + take));
          offset += take;
          totalSize += take;
          if (buffer.length == chunkSize) await flush();
        }
        // Logical-bytes progress, once per source chunk. _putChunk builds
        // its own per-record options, so the backing never double-reports.
        options.onProgress?.call(totalSize, null);
      }
      await flush(); // final partial chunk (may be empty for empty input)

      await _writeManifest(
        key,
        generation: generation,
        chunkCount: index,
        totalSize: totalSize,
        contentType: options.contentType,
        metadata: options.metadata,
      );
    } catch (_) {
      await _reclaimFailed(key, generation);
      rethrow;
    }
    await _deleteGeneration(key, previous);
  }

  Future<int> _writeChunksFromBytes(
    String key,
    int generation,
    Uint8List bytes,
  ) async {
    if (bytes.isEmpty) return 0;
    var i = 0;
    var offset = 0;
    while (offset < bytes.length) {
      final end = (offset + chunkSize) > bytes.length
          ? bytes.length
          : offset + chunkSize;
      await _putChunk(
        key,
        generation,
        i,
        Uint8List.sublistView(bytes, offset, end),
      );
      i++;
      offset = end;
    }
    return i;
  }

  // ══════════════════════════════════════════════════════════════════════
  // READ
  // ══════════════════════════════════════════════════════════════════════

  @override
  Future<Uint8List> read(String key) async {
    checkNotDisposed();
    final manifest = await _readManifest(key);
    if (manifest == null) throw FileNotFoundError(key);
    final builder = BytesBuilder(copy: false);
    for (var i = 0; i < manifest.chunkCount; i++) {
      builder.add(await _readChunk(key, manifest.generation, i));
    }
    return builder.takeBytes();
  }

  @override
  Stream<List<int>> readStream(String key) async* {
    checkNotDisposed();
    final manifest = await _readManifest(key);
    if (manifest == null) throw FileNotFoundError(key);
    for (var i = 0; i < manifest.chunkCount; i++) {
      yield await _readChunk(key, manifest.generation, i);
    }
  }

  @override
  Future<Uint8List> readRange(
    String key, {
    required int start,
    required int length,
  }) async {
    checkNotDisposed();
    final manifest = await _readManifest(key);
    if (manifest == null) throw FileNotFoundError(key);

    final end = (start + length).clamp(0, manifest.totalSize);
    if (end <= start) return Uint8List(0);

    final firstChunk = start ~/ chunkSize;
    final lastChunk = (end - 1) ~/ chunkSize;

    final builder = BytesBuilder(copy: false);
    for (var i = firstChunk; i <= lastChunk; i++) {
      final chunk = await _readChunk(key, manifest.generation, i);
      final chunkStart = i * chunkSize;
      final sliceStart = (start > chunkStart) ? start - chunkStart : 0;
      final sliceEnd = (end < chunkStart + chunk.length)
          ? end - chunkStart
          : chunk.length;
      builder.add(chunk.sublist(sliceStart, sliceEnd));
    }
    return builder.takeBytes();
  }

  // ══════════════════════════════════════════════════════════════════════
  // METADATA
  // ══════════════════════════════════════════════════════════════════════

  @override
  Future<ObjectInfo?> head(String key) async {
    checkNotDisposed();
    final manifest = await _readManifest(key);
    if (manifest == null) return null;
    return ObjectInfo(
      key: key,
      size: manifest.totalSize,
      contentType: manifest.contentType,
      metadata: manifest.metadata,
      lastModified: manifest.lastModified,
    );
  }

  @override
  Future<bool> exists(String key) {
    checkNotDisposed();
    return _backing.exists(_manifestKey(key));
  }

  // ══════════════════════════════════════════════════════════════════════
  // DELETE
  // ══════════════════════════════════════════════════════════════════════

  @override
  Future<void> delete(String key) async {
    checkNotDisposed();
    final manifest = await _readManifest(key);
    if (manifest == null) {
      // No manifest, but orphaned chunks (from a failed first write) might
      // exist under any generation.
      await _backing.deletePrefix('$key$generationPrefix');
      return;
    }
    // The manifest goes first: the object is gone the moment it is deleted, and
    // a crash after that leaves only unreferenced chunks, which nothing can read
    // and the next write of the key sweeps. Chunks first would leave a manifest
    // pointing at records that no longer exist.
    await _backing.delete(_manifestKey(key));
    await _deleteGeneration(key, manifest);
    // A write that failed before its manifest leaves chunks of the generation
    // after the current one; delete them too, so no record of the key remains.
    await _backing.deletePrefix(
      _generationChunks(key, manifest.generation + 1),
    );
  }

  /// The key prefix of every chunk record of [generation] of [key].
  String _generationChunks(String key, int generation) =>
      '$key$generationPrefix$generation$chunkPrefix';

  /// The generation a new write of [key] will use, after removing what an earlier
  /// attempt at it left behind.
  ///
  /// A write puts its chunks under a new generation number and swaps the manifest
  /// last, so one that fails part-way leaves chunks nothing references. They
  /// carry the number the next attempt will use, so the next attempt overwrites
  /// them, but a shorter object would leave the tail of the failed one behind
  /// for good. Chunks are written in order from 0, so a leftover generation
  /// includes chunk 0, and one point lookup gates the sweep.
  ///
  /// With no manifest at all the object has never been written (or was deleted),
  /// and every generation of the key is swept, as a deletion does.
  Future<int> _clearLeftovers(String key, ChunkedManifest? previous) async {
    if (previous == null) {
      if (await _backing.exists(chunkKeyFor(key, 0, 0))) {
        await _backing.deletePrefix('$key$generationPrefix');
      }
      return 0;
    }
    final generation = previous.generation + 1;
    if (await _backing.exists(chunkKeyFor(key, generation, 0))) {
      await _backing.deletePrefix(_generationChunks(key, generation));
    }
    return generation;
  }

  /// Best-effort removal of the chunks a write wrote before it failed, so a failure
  /// (a full quota, above all) does not leave its partial data taking more room.
  /// Whatever it cannot remove is swept by the next write or delete of the key.
  Future<void> _reclaimFailed(String key, int generation) async {
    try {
      await _backing.deletePrefix(_generationChunks(key, generation));
    } catch (_) {
      // The original failure is the one to report.
    }
  }

  /// Reclaim every chunk record of a superseded (or deleted) generation, by
  /// prefix and not by the manifest's count, so chunks beyond it (left by a
  /// failed attempt at the same generation) go too. Called after the manifest
  /// swap, so a failure here can only leave orphans, never a torn object.
  Future<void> _deleteGeneration(String key, ChunkedManifest? manifest) async {
    if (manifest == null) return;
    await _backing.deletePrefix(_generationChunks(key, manifest.generation));
  }

  @override
  Future<void> deletePrefix(String prefix) async {
    checkNotDisposed();
    // Nuke EVERY backing record under the prefix — manifests AND chunks.
    await _backing.deletePrefix(prefix);
  }

  // ══════════════════════════════════════════════════════════════════════
  // LIST
  // ══════════════════════════════════════════════════════════════════════

  @override
  Future<List<ObjectInfo>> list(String prefix) async {
    checkNotDisposed();
    // Only manifest records contribute; chunks are skipped. A backing that can
    // list by suffix hands over just the manifests, so no chunk record is read.
    final backing = _backing;
    final manifests = backing is SuffixListableBackend
        ? await backing.listEndingWith(prefix, manifestSuffix)
        : [
            for (final info in await _backing.list(prefix))
              if (info.key.endsWith(manifestSuffix)) info,
          ];
    final results = <ObjectInfo>[];
    for (final info in manifests) {
      final logicalKey = info.key.substring(
        0,
        info.key.length - manifestSuffix.length,
      );
      final manifest = _decodeManifest(info);
      results.add(
        ObjectInfo(
          key: logicalKey,
          size: manifest.totalSize,
          contentType: manifest.contentType,
          metadata: manifest.metadata,
          lastModified: info.lastModified,
        ),
      );
    }
    return results;
  }

  // ══════════════════════════════════════════════════════════════════════
  // COPY
  // ══════════════════════════════════════════════════════════════════════

  @override
  Future<void> copy(String sourceKey, String destKey) async {
    checkNotDisposed();
    final manifest = await _readManifest(sourceKey);
    if (manifest == null) throw FileNotFoundError(sourceKey);

    final destPrevious = await _readManifest(destKey);
    final destGeneration = await _clearLeftovers(destKey, destPrevious);
    try {
      for (var i = 0; i < manifest.chunkCount; i++) {
        final chunk = await _readChunk(sourceKey, manifest.generation, i);
        await _putChunk(destKey, destGeneration, i, chunk);
      }
      await _writeManifest(
        destKey,
        generation: destGeneration,
        chunkCount: manifest.chunkCount,
        totalSize: manifest.totalSize,
        contentType: manifest.contentType,
        metadata: manifest.metadata,
      );
    } catch (_) {
      await _reclaimFailed(destKey, destGeneration);
      rethrow;
    }
    await _deleteGeneration(destKey, destPrevious);
  }

  // ══════════════════════════════════════════════════════════════════════
  // METADATA UPDATE
  // ══════════════════════════════════════════════════════════════════════

  @override
  Future<void> updateMetadata(
    String key, {
    String? contentType,
    Map<String, String> metadata = const {},
  }) async {
    checkNotDisposed();
    final manifest = await _readManifest(key);
    if (manifest == null) throw FileNotFoundError(key);
    // Update the manifest record's metadata in place instead of rewriting the
    // record: a rewrite is a write, and would stamp a new lastModified (the
    // manifest's, which is what list reports) on an object whose bytes did not
    // change.
    await _backing.updateMetadata(
      _manifestKey(key),
      contentType: contentType,
      metadata: _manifestMetadata(
        manifest.generation,
        manifest.chunkCount,
        manifest.totalSize,
        metadata,
      ),
    );
  }

  /// Patch the caller's metadata keys of the object's manifest record, leaving the
  /// chunk pointer and size as they are at that instant when the backing can merge
  /// atomically (IndexedDB does, in one transaction), so a writer that commits a new
  /// generation meanwhile is not overwritten by a stale pointer.
  @override
  Future<void> patchMetadata(String key, Map<String, String?> changes) async {
    checkNotDisposed();
    if (!await _backing.exists(_manifestKey(key))) throw FileNotFoundError(key);
    return patch.patchMetadata(_backing, _manifestKey(key), changes);
  }

  // ══════════════════════════════════════════════════════════════════════
  // MATERIALIZE — platform-specific, must be provided by subclass
  // ══════════════════════════════════════════════════════════════════════

  @override
  Future<MaterializedFile> materialize(
    String key, {
    bool decrypt = true,
    bool exclusive = false,
  }) {
    checkNotDisposed();
    throw UnimplementedError(
      'ChunkedBackend does not implement materialize directly. '
      'Subclass it with a platform-specific materialize (Blob URL on '
      'web, file path on native) or wrap it in a decorator.',
    );
  }

  // ══════════════════════════════════════════════════════════════════════
  // INTERNAL — chunk + manifest record I/O via the backing adapter
  // ══════════════════════════════════════════════════════════════════════

  Future<void> _putChunk(
    String key,
    int generation,
    int index,
    Uint8List bytes,
  ) => _backing.write(chunkKeyFor(key, generation, index), bytes);

  Future<Uint8List> _readChunk(String key, int generation, int index) async {
    try {
      return await _backing.read(chunkKeyFor(key, generation, index));
    } on FileNotFoundError {
      throw CorruptedFileError(
        key,
        cause: 'Missing chunk $index referenced by manifest',
      );
    }
  }

  Future<void> _writeManifest(
    String key, {
    required int generation,
    required int chunkCount,
    required int totalSize,
    String? contentType,
    Map<String, String> metadata = const {},
  }) async {
    // Manifest is encoded into the metadata of an empty backing record.
    // Backings store metadata via WriteOptions — same path everything else
    // already goes through. Reading is symmetric: head() returns the
    // metadata back out.
    await _backing.write(
      _manifestKey(key),
      Uint8List(0),
      WriteOptions(
        contentType: contentType,
        metadata: _manifestMetadata(
          generation,
          chunkCount,
          totalSize,
          metadata,
        ),
      ),
    );
  }

  Future<ChunkedManifest?> _readManifest(String key) async {
    final info = await _backing.head(_manifestKey(key));
    if (info == null) return null;
    return _decodeManifest(info);
  }

  /// The manifest record's metadata: this layer's three keys under their
  /// `cellar.` names, then the caller's, stored exactly as given. The caller's
  /// keys cannot collide with ours, whatever they are called.
  Map<String, String> _manifestMetadata(
    int generation,
    int chunkCount,
    int totalSize,
    Map<String, String> user,
  ) => {
    ...user,
    CellarMetadata.generation.name: '$generation',
    CellarMetadata.chunkCount.name: '$chunkCount',
    CellarMetadata.totalSize.name: '$totalSize',
  };

  ChunkedManifest _decodeManifest(ObjectInfo info) {
    final raw = info.metadata;
    int number(CellarMetadataKey key) =>
        int.tryParse(
          CellarMetadata.read(raw, key, marker: CellarMetadata.generation) ??
              '',
        ) ??
        0;
    // An object written by the current format has `cellar.generation`; one
    // written by cellar 1.0.0 has the unprefixed names, which are then cellar's
    // and hidden from the caller. In a current object an unprefixed
    // `generation` or `totalSize` is the caller's own and is returned as it is.
    final current = raw.containsKey(CellarMetadata.generation.name);
    final ours = {
      for (final key in [
        CellarMetadata.generation,
        CellarMetadata.chunkCount,
        CellarMetadata.totalSize,
      ])
        current ? key.name : key.legacyName,
    };
    return ChunkedManifest(
      generation: number(CellarMetadata.generation),
      chunkCount: number(CellarMetadata.chunkCount),
      totalSize: number(CellarMetadata.totalSize),
      contentType: info.contentType,
      metadata: {
        for (final entry in raw.entries)
          if (!ours.contains(entry.key)) entry.key: entry.value,
      },
      lastModified: info.lastModified,
    );
  }

  // ── Lifecycle ──

  @override
  String get disposeLabel => 'ChunkedBackend';

  @override
  Future<void> dispose() async {
    // Ownership rule: the backing backend is caller-provided, so its
    // creator disposes it — this layer only arms its own guard.
    markDisposed();
  }
}

/// In-memory representation of a manifest record.
class ChunkedManifest {
  /// In-memory decode of one manifest record.
  const ChunkedManifest({
    required this.generation,
    required this.chunkCount,
    required this.totalSize,
    required this.contentType,
    required this.metadata,
    required this.lastModified,
  });

  /// Write generation whose chunk records this manifest points at. Each
  /// overwrite bumps it, so an in-flight write never touches the records
  /// a reader may be following.
  final int generation;

  /// Number of chunk records in [generation].
  final int chunkCount;

  /// Logical object size in bytes (the sum of all chunks).
  final int totalSize;

  /// Stored content type, if any.
  final String? contentType;

  /// User metadata (the manifest's own bookkeeping keys stripped).
  final Map<String, String> metadata;

  /// The manifest record's own timestamp — when the object last changed.
  final DateTime lastModified;
}
