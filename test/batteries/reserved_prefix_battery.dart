/// The `cellar.` prefix belongs to cellar: the facade refuses a caller's unknown
/// key in it, ignores the ones cellar returns, and every key any decorator puts in
/// storage starts with it. Pure, runs on every platform.
library;

import 'dart:typed_data';

import 'package:cellar/cellar.dart';
import 'package:cellar/cellar_lowlevel.dart';
import 'package:test/test.dart';

import '../harness/fake_digester.dart';
import '../harness/fake_encryptor.dart';

void runReservedPrefixBattery() {
  group('the cellar. prefix', () {
    Future<Cellar> open({bool encrypted = false}) async {
      final cellar = Cellar.withBackends(
        {'a': InMemoryBackend()},
        defaultPartition: 'a',
        encryption: encrypted
            ? CellarEncryption(
                encryptor: FakeEncryptor(),
                keyResolver: const FixedKeyResolver('k'),
              )
            : null,
      );
      await cellar.open();
      return cellar;
    }

    Uint8List bytes(int n) => Uint8List(n);

    group('the facade', () {
      test('refuses a key of the caller\'s in the prefix, on write, '
          'writeStream and updateMetadata, and stores nothing', () async {
        final cellar = await open();
        await cellar.write('exists', bytes(1));

        await expectLater(
          cellar.write('w', bytes(1), metadata: {'cellar.mine': '1'}),
          throwsArgumentError,
        );
        await expectLater(
          cellar.writeStream(
            's',
            Stream.value(bytes(1)),
            metadata: {'cellar.mine': '1'},
          ),
          throwsArgumentError,
        );
        await expectLater(
          cellar.updateMetadata('exists', metadata: {'cellar.mine': '1'}),
          throwsArgumentError,
        );

        expect(await cellar.exists('w'), isFalse);
        expect(await cellar.exists('s'), isFalse);
        expect((await cellar.head('exists'))!.metadata, isEmpty);
        await cellar.close();
      });

      test(
        'the error names the key, and a mixed map is refused whole',
        () async {
          final cellar = await open();

          await expectLater(
            cellar.write(
              'w',
              bytes(1),
              metadata: {'fine': '1', 'cellar.nope': '2'},
            ),
            throwsA(
              isA<ArgumentError>().having(
                (e) => e.invalidValue,
                'invalidValue',
                'cellar.nope',
              ),
            ),
          );
          expect(await cellar.exists('w'), isFalse);
          await cellar.close();
        },
      );

      test('a key that merely looks similar is the caller\'s', () async {
        final cellar = await open();
        const own = {
          'cellar': '1',
          'cellarx': '2',
          'cellar_x': '3',
          'Cellar.x': '4',
          'my.cellar.x': '5',
          'generation': '6',
        };

        await cellar.write('k', bytes(1), metadata: own);

        expect((await cellar.head('k'))!.metadata, own);
        await cellar.close();
      });

      test(
        'the keys cellar returns can be passed back, and are ignored',
        () async {
          final cellar = await open(encrypted: true);
          await cellar.write('src', bytes(200), metadata: {'owner': 'u1'});
          final returned = (await cellar.head('src'))!.metadata;
          expect(returned['cellar.encrypted'], 'true');

          // A caller that passes a head's metadata on, with values that are not true.
          await cellar.write(
            'dst',
            bytes(50),
            metadata: {
              ...returned,
              'cellar.originalSize': '99999',
              'cellar.accessCount': '777',
              'cellar.accessedAt': '1',
              'cellar.contentSize': '1',
              'cellar.contentDigest': 'x',
              'cellar.contentDigestAlgorithm': 'x',
            },
          );
          await cellar.updateMetadata(
            'dst',
            metadata: {...returned, 'owner': 'u2'},
          );

          final head = (await cellar.head('dst'))!;
          expect(
            head.size,
            50,
            reason: 'cellar\'s own size, not the caller\'s 99999',
          );
          expect(head.metadata['owner'], 'u2');
          expect(head.metadata['cellar.encrypted'], 'true');
          expect(head.metadata['cellar.originalSize'], '50');
          for (final key in [
            'cellar.accessCount',
            'cellar.accessedAt',
            'cellar.contentSize',
            'cellar.contentDigest',
            'cellar.contentDigestAlgorithm',
          ]) {
            expect(head.metadata.containsKey(key), isFalse, reason: key);
          }
          expect(await cellar.read('dst'), bytes(50));
          await cellar.close();
        },
      );

      test('cellar\'s own cross-partition copy, which passes head metadata '
          'straight in, still works', () async {
        final cellar = Cellar.withBackends(
          {'a': InMemoryBackend(), 'b': InMemoryBackend()},
          defaultPartition: 'a',
          encryption: CellarEncryption(
            encryptor: FakeEncryptor(),
            keyResolver: const FixedKeyResolver('k'),
          ),
        );
        await cellar.open();
        await cellar.write('k', bytes(120), metadata: {'owner': 'u1'});

        await cellar.copyAcrossPartitions(
          fromPartition: 'a',
          fromKey: 'k',
          toPartition: 'b',
          toKey: 'k2',
        );

        expect(
          (await cellar.head('k2', partition: 'b'))!.metadata['owner'],
          'u1',
        );
        expect(await cellar.read('k2', partition: 'b'), bytes(120));
        await cellar.close();
      });
    });

    group('nothing unprefixed of cellar\'s is ever stored', () {
      const digester = FakeDigester();

      /// Every metadata key of every record in [raw] starts with `cellar.`.
      Future<void> expectOnlyCellarKeys(
        InMemoryBackend raw,
        String reason,
      ) async {
        final records = await raw.list('');
        expect(records, isNotEmpty, reason: reason);
        for (final record in records) {
          for (final key in record.metadata.keys) {
            expect(
              key,
              startsWith('cellar.'),
              reason: '$reason: ${record.key} carries "$key"',
            );
          }
        }
      }

      EncryptedBackend encrypt(StorageBackend inner) => EncryptedBackend(
        inner: inner,
        encryptor: FakeEncryptor(),
        keyResolver: const FixedKeyResolver('k'),
      );

      final stacks = <String, StorageBackend Function(InMemoryBackend raw)>{
        'chunked': (raw) => ChunkedBackend(backing: raw, chunkSize: 64),
        'encrypted': encrypt,
        'encrypted over chunked': (raw) =>
            encrypt(ChunkedBackend(backing: raw, chunkSize: 64)),
        'verifying over encrypted over chunked': (raw) => VerifyingBackend(
          encrypt(ChunkedBackend(backing: raw, chunkSize: 64)),
          digester: digester,
        ),
        'access tracking over encrypted over chunked': (raw) =>
            AccessTrackingBackend(
              encrypt(ChunkedBackend(backing: raw, chunkSize: 64)),
              minInterval: Duration.zero,
            ),
        'every layer': (raw) => VerifyingBackend(
          AccessTrackingBackend(
            encrypt(ChunkedBackend(backing: raw, chunkSize: 64)),
            minInterval: Duration.zero,
          ),
          digester: digester,
        ),
      };

      for (final entry in stacks.entries) {
        test('${entry.key}: an object written with no metadata of its own, '
            'then read, then its metadata updated and patched', () async {
          final raw = InMemoryBackend();
          final stack = entry.value(raw);
          final data = Uint8List.fromList(List.generate(300, (i) => i & 255));

          await stack.write('plain', data);
          await stack.writeStream('streamed', Stream.value(data));
          await stack.write('clear', data, const WriteOptions(encrypt: false));
          if (stack is VerifyingBackend) {
            await stack.writeVerified(
              'verified',
              Stream.value(data),
              expectedSize: 300,
              expectedDigest: FakeDigester.of(data),
            );
          }
          for (final key in ['plain', 'streamed', 'clear']) {
            await stack.read(key);
            await stack.readStream(key).drain<void>();
          }
          if (stack is AccessTrackingBackend) await stack.idle();
          if (stack is VerifyingBackend) {
            final inner = stack.inner;
            if (inner is AccessTrackingBackend) await inner.idle();
          }
          await patchMetadata(stack, 'plain', {'cellar.accessedAt': '1'});
          await expectOnlyCellarKeys(raw, entry.key);

          await stack.updateMetadata('plain'); // no caller metadata at all
          await expectOnlyCellarKeys(raw, '${entry.key} after updateMetadata');
          await stack.copy('plain', 'copied');
          await expectOnlyCellarKeys(raw, '${entry.key} after copy');
        });
      }
    });
  });
}
