import 'dart:typed_data';

import 'package:cellar/src/core/dispose_guard.dart';
import 'package:cellar/src/core/materialized_file.dart';
import 'package:cellar/src/core/object_info.dart';
import 'package:cellar/src/core/storage_backend.dart';
import 'package:cellar/src/core/write_options.dart';

/// A [StorageBackend] decorator that forwards every call to [inner].
///
/// The base class for a decorator that changes one or two behaviors: subclass
/// it and override only those methods, instead of writing all 13. It adds
/// nothing of its own, so a bare `ForwardingBackend(inner)` behaves exactly
/// like `inner` and passes the same conformance battery.
///
/// ```dart
/// class CountingBackend extends ForwardingBackend {
///   CountingBackend(super.inner);
///
///   int reads = 0;
///
///   @override
///   Future<Uint8List> read(String key) {
///     reads++;
///     return super.read(key);
///   }
/// }
/// ```
///
/// Follows the decorator ownership rule: [dispose] disposes only this
/// wrapper, never [inner] (whoever created [inner] disposes it). After
/// [dispose], every forwarded method fails with [StateError], as the contract
/// requires, without reaching [inner]. An override that does not call `super`
/// skips that check, so call `checkNotDisposed()` first in it.
class ForwardingBackend with DisposeGuard implements StorageBackend {
  /// Wraps [inner]; the caller keeps ownership of it.
  ForwardingBackend(this.inner);

  /// The backend every call is forwarded to.
  final StorageBackend inner;

  @override
  String get disposeLabel => runtimeType.toString();

  @override
  Future<void> write(
    String key,
    Uint8List bytes, [
    WriteOptions options = const WriteOptions(),
  ]) async {
    checkNotDisposed();
    return inner.write(key, bytes, options);
  }

  @override
  Future<void> writeStream(
    String key,
    Stream<List<int>> byteStream, [
    WriteOptions options = const WriteOptions(),
  ]) async {
    checkNotDisposed();
    return inner.writeStream(key, byteStream, options);
  }

  @override
  Stream<List<int>> readStream(String key) async* {
    checkNotDisposed();
    yield* inner.readStream(key);
  }

  @override
  Future<Uint8List> read(String key) async {
    checkNotDisposed();
    return inner.read(key);
  }

  @override
  Future<Uint8List> readRange(
    String key, {
    required int start,
    required int length,
  }) async {
    checkNotDisposed();
    return inner.readRange(key, start: start, length: length);
  }

  @override
  Future<ObjectInfo?> head(String key) async {
    checkNotDisposed();
    return inner.head(key);
  }

  @override
  Future<bool> exists(String key) async {
    checkNotDisposed();
    return inner.exists(key);
  }

  @override
  Future<void> delete(String key) async {
    checkNotDisposed();
    return inner.delete(key);
  }

  @override
  Future<void> deletePrefix(String prefix) async {
    checkNotDisposed();
    return inner.deletePrefix(prefix);
  }

  @override
  Future<List<ObjectInfo>> list(String prefix) async {
    checkNotDisposed();
    return inner.list(prefix);
  }

  @override
  Future<void> copy(String sourceKey, String destKey) async {
    checkNotDisposed();
    return inner.copy(sourceKey, destKey);
  }

  @override
  Future<void> updateMetadata(
    String key, {
    String? contentType,
    Map<String, String> metadata = const {},
  }) async {
    checkNotDisposed();
    return inner.updateMetadata(
      key,
      contentType: contentType,
      metadata: metadata,
    );
  }

  @override
  Future<MaterializedFile> materialize(
    String key, {
    bool decrypt = true,
    bool exclusive = false,
  }) async {
    checkNotDisposed();
    return inner.materialize(key, decrypt: decrypt, exclusive: exclusive);
  }

  /// Disposes this wrapper only; [inner] belongs to whoever created it.
  @override
  Future<void> dispose() async {
    markDisposed();
  }
}
