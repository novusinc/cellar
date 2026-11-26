/// VerifyingBackend over any backend: a write that is not what it was said to be
/// stores nothing, and what was stored is guarded on read. Platform-blind; each
/// runner invokes it over the backends it can host.
library;

import 'dart:typed_data';

import 'package:cellar/cellar_lowlevel.dart';
import 'package:test/test.dart';

import '../harness/fake_digester.dart';

/// Runs the battery over the backend [create] makes (one per test). The tests
/// that damage an object do it through that backend directly, behind the
/// decorator's back.
void runVerifyingBattery(
  String label, {
  required StorageBackend Function() create,
}) {
  group('VerifyingBackend over $label', () {
    late StorageBackend base;
    late VerifyingBackend verifying;

    setUp(() {
      base = create();
      verifying = VerifyingBackend(base, digester: const FakeDigester());
    });

    Uint8List bytes(int n, [int seed = 0]) =>
        Uint8List.fromList(List.generate(n, (i) => (i * 3 + seed) & 0xff));

    /// [data] split into chunks of [size], as a download delivers it.
    Stream<List<int>> chunks(Uint8List data, [int size = 100]) async* {
      for (var at = 0; at < data.length; at += size) {
        yield Uint8List.sublistView(
          data,
          at,
          at + size > data.length ? data.length : at + size,
        );
      }
    }

    Future<void> writeVerified(
      String key,
      Uint8List data, {
      int? size,
      String? digest,
      WriteOptions options = const WriteOptions(),
    }) => verifying.writeVerified(
      key,
      chunks(data),
      expectedSize: size ?? data.length,
      expectedDigest: digest ?? FakeDigester.of(data),
      options: options,
    );

    group('a write that matches', () {
      test('is stored, with the verified size, digest and algorithm', () async {
        final data = bytes(450);

        await writeVerified(
          'k',
          data,
          options: const WriteOptions(
            contentType: 'image/png',
            metadata: {'owner': 'u1'},
          ),
        );

        expect(await verifying.read('k'), data);
        final info = (await verifying.head('k'))!;
        expect(info.size, 450);
        expect(info.contentType, 'image/png');
        expect(info.metadata['owner'], 'u1');
        expect(info.metadata[contentSizeMetadataKey], '450');
        expect(info.metadata[contentDigestMetadataKey], FakeDigester.of(data));
        expect(info.metadata[contentDigestAlgorithmMetadataKey], 'fnv32');
      });

      test('an empty object verifies', () async {
        await writeVerified('e', Uint8List(0));

        expect(await verifying.read('e'), isEmpty);
        expect(
          (await verifying.head('e'))!.metadata[contentSizeMetadataKey],
          '0',
        );
      });

      test('passes the caller\'s options on to the wrapped backend', () async {
        final recorder = _OptionsRecorder(base);
        final over = VerifyingBackend(recorder, digester: const FakeDigester());
        void onProgress(int done, int? total) {}

        await over.writeVerified(
          'k',
          chunks(bytes(300)),
          expectedSize: 300,
          expectedDigest: FakeDigester.of(bytes(300)),
          options: WriteOptions(
            contentType: 'a/b',
            metadata: const {'m': '1'},
            onProgress: onProgress,
          ),
        );

        final seen = recorder.options.single;
        expect(seen.contentType, 'a/b');
        expect(seen.metadata['m'], '1');
        expect(identical(seen.onProgress, onProgress), isTrue);
      });
    });

    group('a write that does not match stores nothing', () {
      test('a wrong digest', () async {
        final data = bytes(300);

        await expectLater(
          writeVerified('k', data, digest: 'deadbeef'),
          throwsA(
            isA<ContentVerificationError>()
                .having(
                  (e) => e.failure,
                  'failure',
                  ContentVerificationFailure.digest,
                )
                .having((e) => e.expected, 'expected', 'deadbeef')
                .having((e) => e.actual, 'actual', FakeDigester.of(data))
                .having((e) => e.key, 'key', 'k'),
          ),
        );

        expect(await verifying.exists('k'), isFalse);
        expect(await base.list(''), isEmpty, reason: 'no record is left');
      });

      test('a stream that ends short', () async {
        final data = bytes(300);

        await expectLater(
          writeVerified('k', data, size: 400),
          throwsA(
            isA<ContentVerificationError>()
                .having(
                  (e) => e.failure,
                  'failure',
                  ContentVerificationFailure.size,
                )
                .having((e) => e.expected, 'expected', '400')
                .having((e) => e.actual, 'actual', '300'),
          ),
        );

        expect(await verifying.exists('k'), isFalse);
        expect(await base.list(''), isEmpty);
      });

      test('a stream that runs long is stopped, not stored', () async {
        final data = bytes(300);

        await expectLater(
          writeVerified('k', data, size: 250, digest: FakeDigester.of(data)),
          throwsA(
            isA<ContentVerificationError>().having(
              (e) => e.failure,
              'failure',
              ContentVerificationFailure.size,
            ),
          ),
        );

        expect(await verifying.exists('k'), isFalse);
        expect(await base.list(''), isEmpty);
      });

      test(
        'a mismatch over an existing object keeps the previous one',
        () async {
          final before = bytes(120, 1);
          await writeVerified('k', before);

          await expectLater(
            writeVerified('k', bytes(200, 2), digest: 'deadbeef'),
            throwsA(isA<ContentVerificationError>()),
          );

          expect(await verifying.read('k'), before);
          expect((await verifying.head('k'))!.size, 120);
        },
      );

      test(
        'a source stream that fails is that failure, and stores nothing',
        () async {
          Stream<List<int>> dying() async* {
            yield bytes(100);
            throw StateError('network died');
          }

          await expectLater(
            verifying.writeVerified(
              'k',
              dying(),
              expectedSize: 300,
              expectedDigest: 'x',
            ),
            throwsStateError,
          );

          expect(await verifying.exists('k'), isFalse);
        },
      );
    });

    group('reads are guarded', () {
      test('an object that is no longer the length it was verified at is '
          'rejected by read, readStream and readRange', () async {
        await writeVerified('k', bytes(300));
        // Damage it behind the decorator's back: a torn body, metadata intact.
        final info = (await base.head('k'))!;
        await base.write(
          'k',
          bytes(120),
          WriteOptions(contentType: info.contentType, metadata: info.metadata),
        );

        await expectLater(
          verifying.read('k'),
          throwsA(
            isA<ContentVerificationError>()
                .having(
                  (e) => e.failure,
                  'failure',
                  ContentVerificationFailure.size,
                )
                .having((e) => e.expected, 'expected', '300')
                .having((e) => e.actual, 'actual', '120'),
          ),
        );
        await expectLater(
          verifying.readStream('k').toList(),
          throwsA(isA<ContentVerificationError>()),
        );
        await expectLater(
          verifying.readRange('k', start: 0, length: 10),
          throwsA(isA<ContentVerificationError>()),
        );
      });

      test('an object that was never verified is read as it is', () async {
        await verifying.write('plain', bytes(50));

        expect(await verifying.read('plain'), bytes(50));
        expect(
          (await verifying.head(
            'plain',
          ))!.metadata.containsKey(contentSizeMetadataKey),
          isFalse,
        );
      });

      test('guardReads: false skips the check', () async {
        final unguarded = VerifyingBackend(
          base,
          digester: const FakeDigester(),
          guardReads: false,
        );
        await unguarded.writeVerified(
          'k',
          chunks(bytes(300)),
          expectedSize: 300,
          expectedDigest: FakeDigester.of(bytes(300)),
        );
        final info = (await base.head('k'))!;
        await base.write(
          'k',
          bytes(120),
          WriteOptions(metadata: info.metadata),
        );

        expect((await unguarded.read('k')).length, 120);
      });

      test('a missing key is still a missing key', () async {
        await expectLater(
          verifying.read('nope'),
          throwsA(isA<FileNotFoundError>()),
        );
      });
    });

    group('verify', () {
      test('passes for an intact object, and for one never verified', () async {
        await writeVerified('k', bytes(400));
        await verifying.write('plain', bytes(40));

        await verifying.verify('k');
        await verifying.verify('plain');
      });

      test('catches a changed byte that kept the length', () async {
        final data = bytes(400);
        await writeVerified('k', data);
        final info = (await base.head('k'))!;
        final flipped = Uint8List.fromList(data)..[200] ^= 0xff;
        await base.write('k', flipped, WriteOptions(metadata: info.metadata));

        await expectLater(
          verifying.verify('k'),
          throwsA(
            isA<ContentVerificationError>().having(
              (e) => e.failure,
              'failure',
              ContentVerificationFailure.digest,
            ),
          ),
        );
        // The length guard on read cannot see it; that is what verify is for.
        expect(await verifying.read('k'), flipped);
      });

      test('a missing key is not found', () async {
        await expectLater(
          verifying.verify('nope'),
          throwsA(isA<FileNotFoundError>()),
        );
      });
    });

    group('metadata and copies keep what was verified', () {
      test(
        'updateMetadata replaces the metadata but not the verified record',
        () async {
          final data = bytes(200);
          await writeVerified(
            'k',
            data,
            options: const WriteOptions(metadata: {'a': '1'}),
          );

          await verifying.updateMetadata(
            'k',
            contentType: 'x/y',
            metadata: {'b': '2'},
          );

          final info = (await verifying.head('k'))!;
          expect(info.contentType, 'x/y');
          expect(info.metadata['b'], '2');
          expect(info.metadata.containsKey('a'), isFalse);
          expect(info.metadata[contentSizeMetadataKey], '200');
          expect(
            info.metadata[contentDigestMetadataKey],
            FakeDigester.of(data),
          );
          await verifying.verify('k');
        },
      );

      test('a copy carries it, and is verified the same', () async {
        final data = bytes(333);
        await writeVerified('k', data);

        await verifying.copy('k', 'k2');

        expect(await verifying.read('k2'), data);
        expect(
          (await verifying.head('k2'))!.metadata[contentSizeMetadataKey],
          '333',
        );
        await verifying.verify('k2');
      });

      test(
        'an ordinary write replaces a verified object and its record',
        () async {
          await writeVerified('k', bytes(100));

          await verifying.write('k', bytes(60));

          expect(await verifying.read('k'), bytes(60));
          expect(
            (await verifying.head(
              'k',
            ))!.metadata.containsKey(contentDigestMetadataKey),
            isFalse,
          );
        },
      );
    });

    test('is a CorruptedFileError, so existing handlers and exhaustive '
        'switches still cover it', () async {
      await expectLater(
        writeVerified('k', bytes(10), digest: 'bad'),
        throwsA(isA<CorruptedFileError>()),
      );
      String describe(StorageError e) => switch (e) {
        FileNotFoundError() => 'missing',
        EncryptionKeyMissingError() => 'key',
        CorruptedFileError() => 'corrupt',
        CorruptedMetadataError() => 'metadata',
        ChunkVerificationError() => 'chunk',
        InvalidHeaderError() => 'header',
        InvalidKeyError() => 'invalid key',
        WriteError() => 'write',
      };
      expect(
        describe(
          const ContentVerificationError('k', ContentVerificationFailure.size),
        ),
        'corrupt',
      );
    });

    test('dispose leaves the wrapped backend alone', () async {
      await verifying.dispose();

      await base.write('still', bytes(5));
      expect(await base.read('still'), bytes(5));
      await expectLater(verifying.read('still'), throwsStateError);
    });
  });
}

/// Remembers the options of every `writeStream` it forwards.
class _OptionsRecorder extends ForwardingBackend {
  _OptionsRecorder(super.inner);

  final List<WriteOptions> options = [];

  @override
  Future<void> writeStream(
    String key,
    Stream<List<int>> byteStream, [
    WriteOptions options = const WriteOptions(),
  ]) {
    this.options.add(options);
    return super.writeStream(key, byteStream, options);
  }
}
