import 'dart:async';
import 'dart:typed_data';

import 'package:cellar/src/core/errors.dart';
import 'package:cellar/src/core/object_info.dart';
import 'package:cellar/src/core/write_options.dart';
import 'package:cellar/src/decorators/forwarding/forwarding_backend.dart';
import 'package:cellar/src/decorators/verifying/content_digester.dart';

/// Metadata key under which [VerifyingBackend] records the length (in bytes) an
/// object was verified at.
const String contentSizeMetadataKey = 'cellar.contentSize';

/// Metadata key under which [VerifyingBackend] records the digest an object was
/// verified against.
const String contentDigestMetadataKey = 'cellar.contentDigest';

/// Metadata key under which [VerifyingBackend] records the algorithm of the
/// digest ([ContentDigester.algorithm]).
const String contentDigestAlgorithmMetadataKey =
    'cellar.contentDigestAlgorithm';

/// A decorator that stores an object only if its bytes are the ones the caller
/// said they must be.
///
/// cellar checks nothing about content: a write that completes is stored. For an
/// application that holds a record of what a file must contain (a document's size
/// and hash) that is not enough, since a truncated or wrong download is stored and
/// then served as if it were the file.
///
/// [writeVerified] takes the expected size and digest with the bytes. If the
/// stream is longer than expected the write is stopped as soon as it goes over;
/// at the end of the stream the length and then the digest are compared. A mismatch
/// fails the source stream *at its end*, so the inner backend's atomic write keeps
/// nothing (the previous object, if any, stays), and the call throws a
/// [ContentVerificationError]. A match stores the object with its verified size and
/// digest in metadata ([contentSizeMetadataKey], [contentDigestMetadataKey],
/// [contentDigestAlgorithmMetadataKey]).
///
/// Reads are then guarded: [read], [readStream] and [readRange] of an object that
/// has a recorded size compare it with the stored length first, and throw a
/// [ContentVerificationError] if they differ (a torn or truncated file).
/// [verify] re-hashes an object and compares it with the recorded digest, which
/// costs a full read, so it is for when you need that certainty.
///
/// Ordinary `write` and `writeStream` pass through unverified, and record nothing.
///
/// Put it outermost of the data decorators, over encryption, so the size and the
/// digest are those of the plaintext the caller knows about.
///
/// Like every decorator it does not dispose the backend it wraps.
class VerifyingBackend extends ForwardingBackend {
  /// Wrap [inner]; hash with [digester]. [guardReads] (default true) turns the
  /// length check on reads off, for a caller that cannot afford a `head` per read.
  VerifyingBackend(
    super.inner, {
    required ContentDigester digester,
    this.guardReads = true,
  }) : _digester = digester;

  final ContentDigester _digester;

  /// Whether reads check the recorded length first.
  final bool guardReads;

  /// Write [bytes] only if they are [expectedSize] bytes long and hash to
  /// [expectedDigest] (spelled as this backend's [ContentDigester] spells it).
  ///
  /// Throws [ContentVerificationError] and stores nothing otherwise; whatever the
  /// key held before is kept. [options] are those of `writeStream`; its metadata
  /// is kept and the verified size and digest are added to it.
  Future<void> writeVerified(
    String key,
    Stream<List<int>> bytes, {
    required int expectedSize,
    required String expectedDigest,
    WriteOptions options = const WriteOptions(),
  }) async {
    checkNotDisposed();
    await inner.writeStream(
      key,
      _verified(key, bytes, expectedSize, expectedDigest),
      WriteOptions(
        encrypt: options.encrypt,
        encryptionKey: options.encryptionKey,
        contentType: options.contentType,
        metadata: {
          ...options.metadata,
          contentSizeMetadataKey: '$expectedSize',
          contentDigestMetadataKey: expectedDigest,
          contentDigestAlgorithmMetadataKey: _digester.algorithm,
        },
        onProgress: options.onProgress,
      ),
    );
  }

  /// [source], passed on unchanged, and then failed at its end if it was not what
  /// was expected.
  Stream<List<int>> _verified(
    String key,
    Stream<List<int>> source,
    int expectedSize,
    String expectedDigest,
  ) async* {
    final session = _digester.start();
    var seen = 0;
    await for (final chunk in source) {
      seen += chunk.length;
      if (seen > expectedSize) {
        // Longer than the document says: stop now instead of storing the rest.
        throw ContentVerificationError(
          key,
          ContentVerificationFailure.size,
          expected: '$expectedSize',
          actual: '$seen+',
        );
      }
      await session.add(chunk);
      yield chunk;
    }
    if (seen != expectedSize) {
      throw ContentVerificationError(
        key,
        ContentVerificationFailure.size,
        expected: '$expectedSize',
        actual: '$seen',
      );
    }
    final actual = await session.finish();
    if (actual != expectedDigest) {
      throw ContentVerificationError(
        key,
        ContentVerificationFailure.digest,
        expected: expectedDigest,
        actual: actual,
      );
    }
  }

  /// Re-hash the stored object and compare it with the digest it was verified
  /// against. Reads the whole object.
  ///
  /// Returns normally for an object with no recorded digest (it was never verified,
  /// so there is nothing to compare). Throws [FileNotFoundError] for a missing key
  /// and [ContentVerificationError] for a mismatch.
  Future<void> verify(String key) async {
    checkNotDisposed();
    final info = await inner.head(key);
    if (info == null) throw FileNotFoundError(key);
    final digest = info.metadata[contentDigestMetadataKey];
    if (digest == null) return;
    _checkLength(key, info);
    final session = _digester.start();
    await for (final chunk in inner.readStream(key)) {
      await session.add(chunk);
    }
    final actual = await session.finish();
    if (actual != digest) {
      throw ContentVerificationError(
        key,
        ContentVerificationFailure.digest,
        expected: digest,
        actual: actual,
      );
    }
  }

  Future<void> _guard(String key) async {
    if (!guardReads) return;
    final info = await inner.head(key);
    if (info != null) _checkLength(key, info);
  }

  /// Throws if [info] is not the length its object was verified at.
  void _checkLength(String key, ObjectInfo info) {
    final recorded = int.tryParse(info.metadata[contentSizeMetadataKey] ?? '');
    if (recorded != null && recorded != info.size) {
      throw ContentVerificationError(
        key,
        ContentVerificationFailure.size,
        expected: '$recorded',
        actual: '${info.size}',
      );
    }
  }

  @override
  Future<Uint8List> read(String key) async {
    checkNotDisposed();
    await _guard(key);
    return inner.read(key);
  }

  @override
  Stream<List<int>> readStream(String key) async* {
    checkNotDisposed();
    await _guard(key);
    yield* inner.readStream(key);
  }

  @override
  Future<Uint8List> readRange(
    String key, {
    required int start,
    required int length,
  }) async {
    checkNotDisposed();
    await _guard(key);
    return inner.readRange(key, start: start, length: length);
  }

  /// Replaces the metadata as the contract says, but keeps what was recorded
  /// about the content: the object's bytes did not change, so neither did what it
  /// was verified as.
  @override
  Future<void> updateMetadata(
    String key, {
    String? contentType,
    Map<String, String> metadata = const {},
  }) async {
    checkNotDisposed();
    final info = await inner.head(key);
    final recorded = info == null
        ? const <String, String>{}
        : {
            for (final k in const [
              contentSizeMetadataKey,
              contentDigestMetadataKey,
              contentDigestAlgorithmMetadataKey,
            ])
              if (info.metadata[k] != null) k: info.metadata[k]!,
          };
    return inner.updateMetadata(
      key,
      contentType: contentType,
      metadata: {...metadata, ...recorded},
    );
  }
}
