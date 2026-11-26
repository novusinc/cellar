import 'dart:async';
import 'dart:typed_data';

import 'package:cellar/src/cellar/eviction_policy.dart';
import 'package:cellar/src/core/materialized_file.dart';
import 'package:cellar/src/core/metadata_patchable.dart' as patch;
import 'package:cellar/src/core/write_options.dart';
import 'package:cellar/src/decorators/forwarding/forwarding_backend.dart';

/// A decorator that records when, and how often, each object is read.
///
/// cellar records nothing about reads, so "least recently used" has nothing to go
/// on: eviction orders by when an object was written. This decorator keeps two
/// metadata keys current on each object it serves, in the object's own metadata
/// (the manifest on the web, the sidecar on native), where
/// [EvictionPolicy.leastRecentlyUsed] and [EvictionPolicy.leastFrequentlyUsed]
/// read them:
///
/// - [accessedAtMetadataKey]: when it was last read.
/// - [accessCountMetadataKey]: how many times. **This counts the throttle windows
///   in which the object was read, not every read** (see below), so it is a
///   measure of how often an object is used, not an exact tally.
///
/// It never changes the bytes or `lastModified`, which `maxAge` reads: the update
/// is a [patch.patchMetadata], one key set at a time, atomic where the backend can
/// be (IndexedDB, in one transaction).
///
/// **A read never waits for it and never fails because of it.** The record is made
/// after the read has returned, in the background; a failure is reported to
/// [onError] and forgotten. It is also **throttled per key**: an object read many
/// times a second is recorded once per [minInterval], so it costs one metadata
/// write per window, not one per read. The throttle is in this object's memory, so
/// two instances (two tabs) each record, which is harmless.
///
/// Wrap the backend that holds the objects, beneath any decorator that hides the
/// metadata. Like every decorator it does not dispose what it wraps.
class AccessTrackingBackend extends ForwardingBackend {
  /// Track reads of [inner]. [minInterval] is the shortest time between two
  /// records of one key; [now] is the clock (inject one in a test); [onError] hears
  /// a record that failed.
  AccessTrackingBackend(
    super.inner, {
    this.minInterval = const Duration(minutes: 1),
    DateTime Function() now = DateTime.now,
    this.onError,
  }) : _now = now;

  /// The shortest time between two records of one key.
  final Duration minInterval;

  /// Told when recording an access failed. Null ignores the failure.
  final void Function(String key, Object error)? onError;

  final DateTime Function() _now;
  final Map<String, DateTime> _lastRecorded = {};
  final Set<Future<void>> _pending = {};

  /// Completes when every record started so far has finished (or failed). A read
  /// does not wait for its record, so a caller that needs to see it (a test, a
  /// shutdown) waits here.
  Future<void> idle() async {
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.toList());
    }
  }

  void _record(String key) {
    if (isDisposed) return;
    final now = _now();
    final last = _lastRecorded[key];
    if (last != null && now.difference(last) < minInterval) return;
    _lastRecorded[key] = now;
    late final Future<void> task;
    task = _write(key, now).whenComplete(() => _pending.remove(task));
    _pending.add(task);
  }

  Future<void> _write(String key, DateTime at) async {
    try {
      final info = await inner.head(key);
      if (info == null) return;
      final count =
          int.tryParse(info.metadata[accessCountMetadataKey] ?? '') ?? 0;
      await patch.patchMetadata(inner, key, {
        accessedAtMetadataKey: '${at.toUtc().microsecondsSinceEpoch}',
        accessCountMetadataKey: '${count + 1}',
      });
    } catch (error) {
      // A missing key (deleted since the read) is not worth reporting; anything
      // else is, and neither may reach the reader.
      onError?.call(key, error);
    }
  }

  @override
  Future<Uint8List> read(String key) async {
    final bytes = await super.read(key);
    _record(key);
    return bytes;
  }

  @override
  Stream<List<int>> readStream(String key) async* {
    checkNotDisposed();
    var started = false;
    await for (final chunk in inner.readStream(key)) {
      if (!started) {
        started = true;
        _record(key);
      }
      yield chunk;
    }
    if (!started) _record(key);
  }

  @override
  Future<Uint8List> readRange(
    String key, {
    required int start,
    required int length,
  }) async {
    final bytes = await super.readRange(key, start: start, length: length);
    _record(key);
    return bytes;
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
    _record(key);
    return file;
  }

  // A new object is a new thing to track: forget the old one's throttle.

  @override
  Future<void> write(
    String key,
    Uint8List bytes, [
    WriteOptions options = const WriteOptions(),
  ]) {
    _lastRecorded.remove(key);
    return super.write(key, bytes, options);
  }

  @override
  Future<void> writeStream(
    String key,
    Stream<List<int>> byteStream, [
    WriteOptions options = const WriteOptions(),
  ]) {
    _lastRecorded.remove(key);
    return super.writeStream(key, byteStream, options);
  }

  @override
  Future<void> copy(String sourceKey, String destKey) {
    _lastRecorded.remove(destKey);
    return super.copy(sourceKey, destKey);
  }

  @override
  Future<void> delete(String key) {
    _lastRecorded.remove(key);
    return super.delete(key);
  }

  @override
  Future<void> deletePrefix(String prefix) {
    _lastRecorded.removeWhere((key, _) => key.startsWith(prefix));
    return super.deletePrefix(prefix);
  }

  /// Replaces the metadata as the contract says, but keeps the access record: the
  /// object was not forgotten because someone edited its tags.
  @override
  Future<void> updateMetadata(
    String key, {
    String? contentType,
    Map<String, String> metadata = const {},
  }) async {
    checkNotDisposed();
    final info = await inner.head(key);
    final kept = {
      for (final name in const [accessedAtMetadataKey, accessCountMetadataKey])
        if (info?.metadata[name] != null) name: info!.metadata[name]!,
    };
    return inner.updateMetadata(
      key,
      contentType: contentType,
      metadata: {...metadata, ...kept},
    );
  }
}
