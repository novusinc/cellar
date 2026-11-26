import 'dart:async';
import 'dart:typed_data';

import 'package:cellar/src/core/materialized_file.dart';
import 'package:cellar/src/core/write_options.dart';
import 'package:cellar/src/decorators/forwarding/forwarding_backend.dart';
import 'package:cellar/src/decorators/hooks/storage_hooks.dart';

/// A decorator that runs [StorageHooks] around the calls of the backend it wraps:
/// application code that runs before and after a save, a delete or a read, and may
/// veto the first two.
///
/// It exists so that one check does not need a decorator of its own (13 methods to
/// forward). Like every decorator it does not dispose what it wraps, and it takes no
/// locks.
class HookedBackend extends ForwardingBackend {
  /// Run [hooks] around [inner]'s calls.
  HookedBackend(super.inner, {required this.hooks});

  /// The hooks this backend runs.
  final StorageHooks hooks;

  /// The options to write with: what [StorageHooks.beforeWrite] returns, or [options].
  Future<WriteOptions> _before(String key, WriteOptions options) async {
    final hook = hooks.beforeWrite;
    return hook == null ? options : await hook(key, options);
  }

  /// Runs an `after` hook that must never fail the call.
  Future<void> _after(
    String name,
    String key,
    FutureOr<void> Function()? hook,
  ) async {
    if (hook == null) return;
    try {
      await hook();
    } catch (error) {
      hooks.onHookError?.call(name, key, error);
    }
  }

  Future<void> _afterWrite(String key, WriteOptions options) => _after(
    'afterWrite',
    key,
    hooks.afterWrite == null ? null : () => hooks.afterWrite!(key, options),
  );

  Future<void> _afterRead(String key) => _after(
    'afterRead',
    key,
    hooks.afterRead == null ? null : () => hooks.afterRead!(key),
  );

  @override
  Future<void> write(
    String key,
    Uint8List bytes, [
    WriteOptions options = const WriteOptions(),
  ]) async {
    checkNotDisposed();
    final use = await _before(key, options);
    await super.write(key, bytes, use);
    await _afterWrite(key, use);
  }

  @override
  Future<void> writeStream(
    String key,
    Stream<List<int>> byteStream, [
    WriteOptions options = const WriteOptions(),
  ]) async {
    checkNotDisposed();
    final use = await _before(key, options);
    await super.writeStream(key, byteStream, use);
    await _afterWrite(key, use);
  }

  @override
  Future<void> copy(String sourceKey, String destKey) async {
    checkNotDisposed();
    final use = await _before(destKey, const WriteOptions());
    await super.copy(sourceKey, destKey);
    await _afterWrite(destKey, use);
  }

  @override
  Future<void> delete(String key) async {
    checkNotDisposed();
    await hooks.beforeDelete?.call(key, prefix: false);
    await super.delete(key);
    await _after(
      'afterDelete',
      key,
      hooks.afterDelete == null
          ? null
          : () => hooks.afterDelete!(key, prefix: false),
    );
  }

  @override
  Future<void> deletePrefix(String prefix) async {
    checkNotDisposed();
    await hooks.beforeDelete?.call(prefix, prefix: true);
    await super.deletePrefix(prefix);
    await _after(
      'afterDelete',
      prefix,
      hooks.afterDelete == null
          ? null
          : () => hooks.afterDelete!(prefix, prefix: true),
    );
  }

  @override
  Future<Uint8List> read(String key) async {
    final bytes = await super.read(key);
    await _afterRead(key);
    return bytes;
  }

  @override
  Future<Uint8List> readRange(
    String key, {
    required int start,
    required int length,
  }) async {
    final bytes = await super.readRange(key, start: start, length: length);
    await _afterRead(key);
    return bytes;
  }

  @override
  Stream<List<int>> readStream(String key) async* {
    checkNotDisposed();
    yield* inner.readStream(key);
    // Only a stream that was read to its end gets here: a failure or a cancel
    // leaves the generator before it.
    await _afterRead(key);
  }

  @override
  Future<MaterializedFile> materialize(
    String key, {
    bool decrypt = true,
    bool exclusive = false,
  }) async {
    final file = await super.materialize(
      key,
      decrypt: decrypt,
      exclusive: exclusive,
    );
    await _afterRead(key);
    return file;
  }
}
