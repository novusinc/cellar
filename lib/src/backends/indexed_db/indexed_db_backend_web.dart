import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'package:cellar/src/decorators/chunked/chunked_backend.dart';
import 'package:cellar/src/core/dispose_guard.dart';
import 'package:cellar/src/core/materialized_file.dart';
import 'package:cellar/src/core/metadata_patchable.dart';
import 'package:cellar/src/core/object_info.dart';
import 'package:cellar/src/core/write_options.dart';
import 'package:cellar/src/core/errors.dart';

/// Web file storage using IndexedDB.
///
/// Layered on [ChunkedBackend] (which owns the
/// chunk-and-manifest algorithm) over a thin [_RawIndexedDbBackend]
/// (which owns the JS-interop / IndexedDB primitives). This means:
///
/// - The chunking logic is shared with any other backend that wants
///   it; tests against `ChunkedBackend` over an in-memory
///   backing prove the algorithm without needing a browser.
/// - This file owns ONLY the web-specific bits: opening a database,
///   reading/writing single records, and producing Blob URLs from
///   chunked records (the only operation that genuinely cannot be
///   abstracted across native and web).
///
/// Default chunk size is 64 KiB — see [ChunkedBackend] for the
/// rationale; override via the constructor to change it.
class IndexedDbBackend extends ChunkedBackend {
  /// Create a backend over the IndexedDB database [dbName].
  IndexedDbBackend({
    required String dbName,
    super.chunkSize = ChunkedBackend.defaultChunkSize,
  }) : super(backing: _RawIndexedDbBackend(dbName: dbName));

  @override
  String get disposeLabel => 'IndexedDbBackend';

  @override
  Future<void> dispose() async {
    // This class constructed its raw backing, so it disposes it — that
    // closes the IDBDatabase connection, unblocking deleteDatabase and
    // version upgrades from other tabs.
    await backing.dispose();
    await super.dispose();
  }

  // ══════════════════════════════════════════════════════════════════════
  // MATERIALIZE — Blob URL from chunked records
  // ══════════════════════════════════════════════════════════════════════

  /// Materialize on IndexedDB — returns a **Blob URL**.
  ///
  /// Web has no filesystem, so [MaterializedFile.localPath] is an object
  /// URL (e.g. `blob:https://app.example.com/uuid`). Usable with most
  /// browser APIs (`<audio src=...>`, `<img src=...>`, `fetch(url)`,
  /// anchor downloads). NOT usable with native FFI — which doesn't run
  /// on web anyway.
  ///
  /// ## Memory
  ///
  /// Reads each chunk record once (O(chunk size) in JS heap per
  /// iteration) and hands it off to the `Blob` constructor as one of N
  /// parts. The browser keeps blob parts in IndexedDB-backed memory
  /// rather than concatenating them in the JS heap. End-to-end memory
  /// is O(chunk size), regardless of total file size.
  ///
  /// ## Decrypt + exclusive
  ///
  /// [decrypt] is a no-op at this layer — the
  /// `EncryptedBackend` decorator intercepts upstream. If
  /// this code is reached on encrypted bytes, the blob URL exposes the
  /// ciphertext.
  ///
  /// [exclusive] is also a no-op: every call creates a fresh blob URL
  /// pointing at independent buffers, so callers always get an
  /// independent handle. [MaterializedFile.release] revokes the URL.
  @override
  Future<MaterializedFile> materialize(
    String key, {
    bool decrypt = true,
    bool exclusive = false,
  }) async {
    final manifest = await manifestFor(key);
    if (manifest == null) throw FileNotFoundError(key);

    // Read each chunk via the backing's raw record API, building a
    // JSAny[] for the Blob constructor. Per the Blob spec, parts are
    // referenced — not concatenated — until the blob's bytes are
    // actually requested. End-to-end memory stays O(chunkSize).
    final parts = <JSAny>[];
    for (var i = 0; i < manifest.chunkCount; i++) {
      final bytes = await backing.read(
        chunkKeyFor(key, manifest.generation, i),
      );
      parts.add(bytes.toJS);
    }

    final blob = manifest.contentType != null
        ? web.Blob(parts.toJS, web.BlobPropertyBag(type: manifest.contentType!))
        : web.Blob(parts.toJS);

    final url = web.URL.createObjectURL(blob);

    return MaterializedFile(
      localPath: url,
      key: key,
      release: () async {
        web.URL.revokeObjectURL(url);
      },
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// Raw IndexedDB backend — single-record I/O over IndexedDB.
//
// Implements [StorageBackend] but ONLY for the simple key→bytes
// case. The chunking layer above ([ChunkedBackend]) is what
// makes this usable for arbitrary-size objects. Splitting the two lets
// the chunking algorithm be tested off-web against an in-memory
// backing — no JS runtime required for unit tests.
// ══════════════════════════════════════════════════════════════════════════

class _RawIndexedDbBackend
    with DisposeGuard
    implements SuffixListableBackend, MetadataPatchableBackend {
  _RawIndexedDbBackend({required String dbName}) : _dbName = dbName;
  final String _dbName;
  static const _storeName = 'files';
  static const _dbVersion = 1;

  web.IDBDatabase? _db;

  @override
  String get disposeLabel => 'IndexedDbBackend';

  @override
  Future<void> dispose() async {
    markDisposed();
    _db?.close();
    _db = null;
  }

  Future<web.IDBDatabase> _getDb() async {
    // Every operation on this backend goes through _getDb — one guard
    // here covers the whole surface.
    checkNotDisposed();
    if (_db != null) return _db!;

    final completer = Completer<web.IDBDatabase>();
    final request = web.window.self.indexedDB.open(_dbName, _dbVersion);

    request.onupgradeneeded = (web.IDBVersionChangeEvent event) {
      final db = request.result as web.IDBDatabase;
      if (!db.objectStoreNames.contains(_storeName)) {
        db.createObjectStore(_storeName);
      }
    }.toJS;

    request.onsuccess = (web.Event event) {
      _db = request.result as web.IDBDatabase;
      completer.complete(_db!);
    }.toJS;

    request.onerror = (web.Event event) {
      completer.completeError(
        StateError(
          'Failed to open IndexedDB "$_dbName": ${request.error?.message}',
        ),
      );
    }.toJS;

    return completer.future;
  }

  Future<web.IDBObjectStore> _store(String mode) async {
    final db = await _getDb();
    final tx = db.transaction(_storeName.toJS, mode);
    return tx.objectStore(_storeName);
  }

  /// Resolves with [request]'s result. A failure is mapped by [_failure], using
  /// [key] for the typed error.
  Future<JSAny?> _request(web.IDBRequest request, {String? key}) {
    final completer = Completer<JSAny?>();
    request.onsuccess = (web.Event event) {
      completer.complete(request.result);
    }.toJS;
    request.onerror = (web.Event event) {
      completer.completeError(_failure(key, request.error, 'request'));
    }.toJS;
    return completer.future;
  }

  /// The error for a failed request or aborted transaction: a [QuotaExceededError]
  /// when the browser says storage is full, a [StateError] otherwise (as before).
  Object _failure(String? key, web.DOMException? error, String what) {
    if (error?.name == 'QuotaExceededError') {
      return QuotaExceededError(key ?? '', cause: error?.message);
    }
    return StateError('IndexedDB $what failed: ${error?.message}');
  }

  /// A read-write transaction whose end is observable: [_WriteTransaction.done]
  /// completes when the browser has COMMITTED it, and fails if it aborts.
  ///
  /// A request's success only means the browser accepted the operation. The commit
  /// comes later, and that is where a full quota shows up, as an abort. Returning
  /// at the request's success would report a write that is not stored.
  Future<_WriteTransaction> _writeTransaction(String key) async {
    final db = await _getDb();
    final tx = db.transaction(_storeName.toJS, 'readwrite');
    final done = Completer<void>();
    // A failure is for whoever awaits [done]; one nobody awaits (the request that
    // failed already threw) must not take the zone down.
    done.future.ignore();
    tx.oncomplete = (web.Event event) {
      done.complete();
    }.toJS;
    tx.onabort = (web.Event event) {
      done.completeError(_failure(key, tx.error, 'transaction'));
    }.toJS;
    return _WriteTransaction(tx.objectStore(_storeName), done.future);
  }

  /// Starts a request with [start] and waits for it, turning a quota failure that
  /// the browser throws synchronously into a [QuotaExceededError] too.
  Future<JSAny?> _send(String key, web.IDBRequest Function() start) async {
    try {
      return await _request(start(), key: key);
    } on StorageError {
      rethrow;
    } catch (e) {
      // dart2js and dart2wasm both give a thrown DOMException a toString of
      // "<name>: <message>".
      if (e.toString().contains('QuotaExceededError')) {
        throw QuotaExceededError(key, cause: e);
      }
      rethrow;
    }
  }

  // ── Write ──

  @override
  Future<void> write(
    String key,
    Uint8List bytes, [
    WriteOptions options = const WriteOptions(),
  ]) async {
    final tx = await _writeTransaction(key);
    final record = _buildRecord(bytes, options.contentType, options.metadata);
    await _send(key, () => tx.store.put(record, key.toJS));
    await tx.done;
  }

  @override
  Future<void> writeStream(
    String key,
    Stream<List<int>> byteStream, [
    WriteOptions options = const WriteOptions(),
  ]) async {
    // Single-record backend — collect then write. The chunking layer
    // above breaks large inputs into many small records BEFORE they
    // reach this method, so the buffered size here is bounded by the
    // chunking layer's chunkSize (default 64 KiB).
    final chunks = <int>[];
    await for (final chunk in byteStream) {
      chunks.addAll(chunk);
    }
    await write(key, Uint8List.fromList(chunks), options);
  }

  // ── Read ──

  @override
  Future<Uint8List> read(String key) async {
    final store = await _store('readonly');
    final result = await _request(store.get(key.toJS));
    if (result == null) throw FileNotFoundError(key);
    return _extractBody(key, result);
  }

  @override
  Stream<List<int>> readStream(String key) async* {
    yield await read(key);
  }

  @override
  Future<Uint8List> readRange(
    String key, {
    required int start,
    required int length,
  }) async {
    final bytes = await read(key);
    final end = (start + length).clamp(0, bytes.length);
    return bytes.sublist(start, end);
  }

  // ── Metadata ──

  @override
  Future<ObjectInfo?> head(String key) async {
    final store = await _store('readonly');
    final result = await _request(store.get(key.toJS));
    if (result == null) return null;
    return _parseObjectInfo(key, result);
  }

  @override
  Future<bool> exists(String key) async {
    final store = await _store('readonly');
    final result = await _request(store.count(key.toJS));
    if (result == null) return false;
    return (result as JSNumber).toDartInt > 0;
  }

  // ── Delete ──

  @override
  Future<void> delete(String key) async {
    final tx = await _writeTransaction(key);
    await _send(key, () => tx.store.delete(key.toJS));
    await tx.done;
  }

  @override
  Future<void> deletePrefix(String prefix) async {
    final keyRange = web.IDBKeyRange.bound(prefix.toJS, '$prefix\uffff'.toJS);
    final tx = await _writeTransaction(prefix);
    final store = tx.store;
    final cursorRequest = store.openKeyCursor(keyRange);

    final completer = Completer<void>();
    cursorRequest.onsuccess = (web.Event event) {
      final cursor = cursorRequest.result;
      if (cursor != null) {
        final keyCursor = cursor as web.IDBCursor;
        store.delete(keyCursor.key!);
        keyCursor.continue_();
      } else {
        completer.complete();
      }
    }.toJS;
    cursorRequest.onerror = (web.Event event) {
      completer.completeError(
        StateError('IndexedDB cursor failed: ${cursorRequest.error?.message}'),
      );
    }.toJS;
    await completer.future;
    await tx.done;
  }

  // ── List ──

  @override
  Future<List<ObjectInfo>> list(String prefix) async {
    final keyRange = web.IDBKeyRange.bound(prefix.toJS, '$prefix\uffff'.toJS);
    final store = await _store('readonly');
    final cursorRequest = store.openCursor(keyRange);

    final results = <ObjectInfo>[];
    final completer = Completer<List<ObjectInfo>>();

    cursorRequest.onsuccess = (web.Event event) {
      final cursor = cursorRequest.result;
      if (cursor != null) {
        final valueCursor = cursor as web.IDBCursorWithValue;
        final key = (valueCursor.key! as JSString).toDart;
        final value = valueCursor.value;
        if (value != null) {
          results.add(_parseObjectInfo(key, value));
        }
        valueCursor.continue_();
      } else {
        completer.complete(results);
      }
    }.toJS;
    cursorRequest.onerror = (web.Event event) {
      completer.completeError(
        StateError('IndexedDB cursor failed: ${cursorRequest.error?.message}'),
      );
    }.toJS;

    return completer.future;
  }

  /// The records under [prefix] whose key ends with [suffix].
  ///
  /// Walks the key range with a keys-only cursor, which reads no record values, and
  /// then reads only the records that match, all in one read-only transaction.
  /// [list] reads every record's value (a chunk record's body is up to 64 KiB, and
  /// it is read only to be discarded), so a listing of a partition costs its whole
  /// size; this costs the size of the matching records, which for manifests is
  /// their metadata.
  @override
  Future<List<ObjectInfo>> listEndingWith(String prefix, String suffix) async {
    final keyRange = web.IDBKeyRange.bound(prefix.toJS, '$prefix\uffff'.toJS);
    final store = await _store('readonly');
    final cursorRequest = store.openKeyCursor(keyRange);

    final keys = <String>[];
    final done = Completer<void>();
    cursorRequest.onsuccess = (web.Event event) {
      final cursor = cursorRequest.result;
      if (cursor != null) {
        final key = ((cursor as web.IDBCursor).key! as JSString).toDart;
        if (key.endsWith(suffix)) keys.add(key);
        cursor.continue_();
      } else {
        done.complete();
      }
    }.toJS;
    cursorRequest.onerror = (web.Event event) {
      done.completeError(
        StateError('IndexedDB cursor failed: ${cursorRequest.error?.message}'),
      );
    }.toJS;
    await done.future;

    final results = <ObjectInfo>[];
    for (final key in keys) {
      final value = await _request(store.get(key.toJS));
      if (value != null) results.add(_parseObjectInfo(key, value));
    }
    return results;
  }

  // ── Copy ──

  @override
  Future<void> copy(String sourceKey, String destKey) async {
    final store = await _store('readonly');
    final result = await _request(store.get(sourceKey.toJS));
    if (result == null) throw FileNotFoundError(sourceKey);
    final tx = await _writeTransaction(destKey);
    await _send(destKey, () => tx.store.put(result, destKey.toJS));
    await tx.done;
  }

  // ── Metadata update ──

  @override
  Future<void> updateMetadata(
    String key, {
    String? contentType,
    Map<String, String> metadata = const {},
  }) async {
    // One read-write transaction (get, then put): IndexedDB transactions are
    // atomic across tabs, so no writer can slip in between the two.
    final tx = await _writeTransaction(key);
    final store = tx.store;
    final result = await _request(store.get(key.toJS), key: key);
    if (result == null) throw FileNotFoundError(key);

    final bytes = _extractBody(key, result);
    // Carry the record's write time forward: lastModified is when the BYTES were
    // written, as on native, so changing metadata must not restart an object's
    // age (maxAge) or reorder it for eviction.
    final writtenAt = (result as _IdbRecord).writtenAt;
    final record = _buildRecord(
      bytes,
      contentType,
      metadata,
      writtenAt: writtenAt.isA<JSNumber>() ? writtenAt : null,
    );
    await _send(key, () => store.put(record, key.toJS));
    await tx.done;
  }

  /// Merge [changes] into the record's metadata in ONE read-write transaction:
  /// get, merge, put. The record is read where it is written, so whatever it holds
  /// at that instant is kept (a chunk pointer a writer just committed included),
  /// and IndexedDB makes the transaction atomic across tabs, so no lock is needed.
  /// The bytes, the content type and `writtenAt` are carried forward unchanged.
  @override
  Future<void> patchMetadata(String key, Map<String, String?> changes) async {
    final tx = await _writeTransaction(key);
    final store = tx.store;
    final result = await _request(store.get(key.toJS), key: key);
    if (result == null) throw FileNotFoundError(key);

    final info = _parseObjectInfo(key, result);
    final writtenAt = (result as _IdbRecord).writtenAt;
    final record = _buildRecord(
      _extractBody(key, result),
      info.contentType,
      applyMetadataChanges(info.metadata, changes),
      writtenAt: writtenAt.isA<JSNumber>() ? writtenAt : null,
    );
    await _send(key, () => store.put(record, key.toJS));
    await tx.done;
  }

  // ── Materialize — never called on this layer ──

  @override
  Future<MaterializedFile> materialize(
    String key, {
    bool decrypt = true,
    bool exclusive = false,
  }) {
    // The chunking layer above provides the real materialize. This raw
    // backend is internal and shouldn't be reached directly.
    throw UnsupportedError(
      '_RawIndexedDbBackend.materialize must not be called — go through '
      'IndexedDbBackend, which produces a Blob URL from chunks.',
    );
  }

  // ── Internal: compound record helpers ──

  JSObject _buildRecord(
    Uint8List bytes,
    String? contentType,
    Map<String, String> metadata, {
    JSAny? writtenAt,
  }) {
    return <String, Object?>{
          'body': bytes.toJS,
          'contentType': contentType?.toJS,
          'metadata': metadata.map((k, v) => MapEntry(k, v.toJS)).jsify(),
          // Cellar-maintained write timestamp. IndexedDB has no native
          // last-modified tracking; we write it on every put so ObjectInfo
          // can return a non-null lastModified on web. Stored as ms-since-epoch.
          // [writtenAt] is passed only by updateMetadata, to keep the bytes' time.
          'writtenAt':
              writtenAt ?? DateTime.now().toUtc().millisecondsSinceEpoch.toJS,
        }.jsify()
        as JSObject;
  }

  Uint8List _extractBody(String key, JSAny record) {
    final body = (record as _IdbRecord).body;
    // _buildRecord stores the body as a Uint8Array (`Uint8List.toJS`);
    // structured clone hands the same shape back. Accept a bare
    // ArrayBuffer too — records imported from other tooling often carry
    // one, and the bytes are identical either way.
    if (body.isA<JSUint8Array>()) {
      return (body! as JSUint8Array).toDart;
    }
    if (body.isA<JSArrayBuffer>()) {
      return (body! as JSArrayBuffer).toDart.asUint8List();
    }
    throw CorruptedFileError(key, cause: 'Unexpected record body format');
  }

  ObjectInfo _parseObjectInfo(String key, JSAny record) {
    final bytes = _extractBody(key, record);
    final rec = record as _IdbRecord;

    String? contentType;
    final ct = rec.contentType;
    if (ct.isA<JSString>()) {
      contentType = (ct! as JSString).toDart;
    }

    var metadata = const <String, String>{};
    final meta = rec.metadata;
    if (meta != null) {
      final dartMap = meta.dartify();
      if (dartMap is Map) {
        metadata = dartMap.cast<String, String>();
      }
    }

    DateTime? lastModified;
    final wa = rec.writtenAt;
    if (wa.isA<JSNumber>()) {
      lastModified = DateTime.fromMillisecondsSinceEpoch(
        (wa! as JSNumber).toDartInt,
        isUtc: true,
      );
    }

    if (lastModified == null) {
      // ObjectInfo.lastModified is non-null by contract. A record without
      // writtenAt was written by code that didn't maintain the field —
      // treat it as corruption, not a legacy compat case.
      throw CorruptedFileError(
        key,
        cause: 'IndexedDB record missing writtenAt — wipe and rewrite.',
      );
    }

    return ObjectInfo(
      key: key,
      size: bytes.length,
      contentType: contentType,
      metadata: metadata,
      lastModified: lastModified,
    );
  }
}

/// A read-write transaction: its store, and a future for its commit.
class _WriteTransaction {
  _WriteTransaction(this.store, this.done);

  final web.IDBObjectStore store;

  /// Completes when the browser has committed the transaction; fails with the
  /// mapped error (a [QuotaExceededError] for a full quota) if it aborts.
  final Future<void> done;
}

/// Typed view of the compound record [_RawIndexedDbBackend] stores.
///
/// External getters compile to direct property access under BOTH dart2js
/// and dart2wasm. Do not read record fields through `dynamic` — dynamic
/// member access on a JS value crashes at runtime under dart2wasm.
@JS()
extension type _IdbRecord._(JSObject _) implements JSObject {
  external JSAny? get body;
  external JSAny? get contentType;
  external JSObject? get metadata;
  external JSAny? get writtenAt;
}
