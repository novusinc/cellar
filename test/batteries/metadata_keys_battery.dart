/// cellar's own metadata keys live under `cellar.`, objects written by cellar
/// 1.0.0 still read, and a caller's keys can be named anything. Pure, runs on
/// every platform.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cellar/cellar.dart';
import 'package:cellar/cellar_lowlevel.dart';
import 'package:test/test.dart';

import '../fixtures/cellar_1_0_0_fixtures.dart';
import '../harness/fake_encryptor.dart';

/// The plaintext of a fixture object, as the generator made it.
Uint8List _plain(int size, int seed) =>
    Uint8List.fromList(List.generate(size, (i) => (i * 7 + seed) & 0xff));

/// The raw store a fixture describes: what cellar 1.0.0 left on disk.
Future<InMemoryBackend> _legacyStore(String stack) async {
  final raw = InMemoryBackend();
  final records =
      (cellar100Fixtures[stack]! as Map)['records']! as Map<String, Object?>;
  for (final entry in records.entries) {
    final record = entry.value! as Map<String, Object?>;
    await raw.write(
      entry.key,
      base64.decode(record['bytes']! as String),
      WriteOptions(
        contentType: record['contentType'] as String?,
        metadata: Map<String, String>.from(record['metadata']! as Map),
      ),
    );
  }
  return raw;
}

Map<String, Map<String, Object?>> _objects(String stack) => {
  for (final e
      in ((cellar100Fixtures[stack]! as Map)['objects']!
              as Map<String, Object?>)
          .entries)
    e.key: Map<String, Object?>.from(e.value! as Map),
};

/// The metadata keys cellar adds, as a caller sees them.
Map<String, String> _cellarKeys(Map<String, String> metadata) => {
  for (final e in metadata.entries)
    if (e.key.startsWith('cellar.')) e.key: e.value,
};

Map<String, String> _callerKeys(Map<String, String> metadata) => {
  for (final e in metadata.entries)
    if (!e.key.startsWith('cellar.')) e.key: e.value,
};

void runMetadataKeysBattery() {
  group('cellar. metadata keys', () {
    ChunkedBackend chunkedOver(StorageBackend raw) =>
        ChunkedBackend(backing: raw, chunkSize: 64);

    EncryptedBackend encryptedOver(StorageBackend inner) => EncryptedBackend(
      inner: inner,
      encryptor: FakeEncryptor(),
      keyResolver: const FixedKeyResolver('fixture-key'),
    );

    group('objects written by cellar 1.0.0 still read', () {
      test('through the chunked layer, with cellar\'s keys hidden', () async {
        final raw = await _legacyStore('chunked');
        final chunked = chunkedOver(raw);

        for (final entry in _objects('chunked').entries) {
          final o = entry.value;
          expect(
            await chunked.read(entry.key),
            _plain(o['size']! as int, o['seed']! as int),
          );
          final info = (await chunked.head(entry.key))!;
          expect(info.size, o['size']);
          expect(info.contentType, o['contentType']);
          expect(info.metadata, o['metadata'], reason: entry.key);
        }
        final listed = {for (final i in await chunked.list('')) i.key: i};
        expect(listed.keys, _objects('chunked').keys.toSet());
        expect(listed['doc']!.size, 150);
        expect(listed['doc']!.metadata, {'owner': 'u1'});
      });

      test(
        'through the encryption layer, with one stable name for its keys',
        () async {
          final enc = encryptedOver(await _legacyStore('encrypted'));

          for (final entry in _objects('encrypted').entries) {
            final o = entry.value;
            expect(
              await enc.read(entry.key),
              _plain(o['size']! as int, o['seed']! as int),
              reason: entry.key,
            );
            final info = (await enc.head(entry.key))!;
            expect(info.size, o['size']);
            expect(info.contentType, o['contentType']);
            expect(_callerKeys(info.metadata), o['metadata']);
            if (o['encrypted']! as bool) {
              expect(info.metadata['cellar.encrypted'], 'true');
              expect(
                info.metadata.containsKey('encrypted'),
                isFalse,
                reason: 'the old name is mapped, not shown beside the new one',
              );
              expect(info.metadata.containsKey('originalSize'), isFalse);
            } else {
              expect(_cellarKeys(info.metadata), isEmpty);
            }
          }
          // list agrees with head.
          for (final info in await enc.list('')) {
            final o = _objects('encrypted')[info.key]!;
            expect(info.size, o['size']);
            expect(_callerKeys(info.metadata), o['metadata']);
          }
        },
      );

      test(
        'through encryption over chunking, the stack an app builds',
        () async {
          final stack = encryptedOver(
            chunkedOver(await _legacyStore('encryptedOverChunked')),
          );

          for (final entry in _objects('encryptedOverChunked').entries) {
            final o = entry.value;
            expect(
              await stack.read(entry.key),
              _plain(o['size']! as int, o['seed']! as int),
              reason: entry.key,
            );
            final info = (await stack.head(entry.key))!;
            expect(info.size, o['size']);
            expect(_callerKeys(info.metadata), o['metadata']);
            expect(
              info.metadata['cellar.encrypted'],
              (o['encrypted']! as bool) ? 'true' : null,
            );
          }
          final streamed = await stack.readStream('streamed').toList();
          expect(
            Uint8List.fromList(streamed.expand((c) => c).toList()),
            _plain(220, 8),
          );
        },
      );
    });

    group('updating a legacy object moves it to the current names', () {
      test('chunked: the manifest is rewritten under cellar.', () async {
        final raw = await _legacyStore('chunked');
        final chunked = chunkedOver(raw);
        expect(
          (await raw.head('doc__manifest'))!.metadata,
          contains('generation'),
        );

        await chunked.updateMetadata(
          'doc',
          contentType: 'application/pdf',
          metadata: const {'owner': 'u9'},
        );

        final manifest = (await raw.head('doc__manifest'))!.metadata;
        expect(
          manifest.keys,
          containsAll(<String>[
            'cellar.generation',
            'cellar.chunkCount',
            'cellar.totalSize',
          ]),
        );
        expect(manifest.containsKey('generation'), isFalse);
        expect(manifest.containsKey('totalSize'), isFalse);
        expect(manifest['owner'], 'u9');
        expect(await chunked.read('doc'), _plain(150, 3));
        expect((await chunked.head('doc'))!.metadata, {'owner': 'u9'});
      });

      test(
        'encrypted: the flag and size are rewritten under cellar.',
        () async {
          final raw = await _legacyStore('encrypted');
          final enc = encryptedOver(raw);
          expect((await raw.head('buffered'))!.metadata['encrypted'], 'true');

          await enc.updateMetadata('buffered', metadata: const {'owner': 'u9'});

          final stored = (await raw.head('buffered'))!.metadata;
          expect(stored['cellar.encrypted'], 'true');
          expect(stored['cellar.originalSize'], '100');
          expect(stored.containsKey('encrypted'), isFalse);
          expect(stored.containsKey('originalSize'), isFalse);
          expect(await enc.read('buffered'), _plain(100, 4));
          expect((await enc.head('buffered'))!.size, 100);
        },
      );

      test('a legacy plaintext object gets the marker, so its caller keys '
          'are theirs from then on', () async {
        final raw = await _legacyStore('encrypted');
        final enc = encryptedOver(raw);

        await enc.updateMetadata(
          'plain',
          contentType: 'image/png',
          metadata: const {'encrypted': 'true'}, // the caller's own key
        );

        expect(await enc.read('plain'), _plain(30, 6));
        final info = (await enc.head('plain'))!;
        expect(info.metadata['encrypted'], 'true');
        expect(info.metadata['cellar.encrypted'], 'false');
      });

      test('copying a legacy encrypted object writes the new format', () async {
        final raw = await _legacyStore('encrypted');
        final enc = encryptedOver(raw);

        await enc.copy('buffered', 'copied');

        expect(await enc.read('copied'), _plain(100, 4));
        final stored = (await raw.head('copied'))!.metadata;
        expect(stored['cellar.encrypted'], 'true');
        expect(stored.containsKey('encrypted'), isFalse);
      });
    });

    group('a caller may name its keys anything', () {
      const collide = {
        'generation': '7',
        'chunkCount': '99',
        'totalSize': '1',
        'encrypted': 'true',
        'originalSize': '5',
        'owner': 'u1',
      };

      test('chunked: the caller\'s generation, chunkCount and totalSize are '
          'stored and returned, and do not touch the chunk pointer', () async {
        final raw = InMemoryBackend();
        final chunked = chunkedOver(raw);
        final bytes = _plain(200, 1);

        await chunked.write('k', bytes, const WriteOptions(metadata: collide));
        await chunked.writeStream(
          's',
          Stream.value(bytes),
          const WriteOptions(metadata: collide),
        );

        for (final key in ['k', 's']) {
          expect(await chunked.read(key), bytes, reason: key);
          final info = (await chunked.head(key))!;
          expect(info.size, 200);
          expect(info.metadata, collide, reason: 'exactly the caller\'s keys');
        }
        expect(
          {for (final i in await chunked.list('')) i.key: i.size},
          {'k': 200, 's': 200},
        );
      });

      test('a new object stores cellar\'s keys only under cellar.', () async {
        final raw = InMemoryBackend();
        await chunkedOver(raw).write(
          'k',
          _plain(100, 1),
          const WriteOptions(metadata: {'owner': 'u1'}),
        );

        final stored = (await raw.head('k__manifest'))!.metadata;
        expect(stored.keys.toSet(), {
          'cellar.generation',
          'cellar.chunkCount',
          'cellar.totalSize',
          'owner',
        });
      });

      test('a caller\'s encrypted: true on a plaintext object does not make it '
          'read as ciphertext', () async {
        final raw = InMemoryBackend();
        final enc = encryptedOver(raw);
        final bytes = _plain(50, 2);

        await enc.write(
          'p',
          bytes,
          const WriteOptions(encrypt: false, metadata: {'encrypted': 'true'}),
        );

        expect(await enc.read('p'), bytes, reason: 'plaintext, as written');
        final info = (await enc.head('p'))!;
        expect(info.size, 50);
        expect(info.metadata['encrypted'], 'true', reason: 'the caller\'s');
        expect(info.metadata['cellar.encrypted'], 'false', reason: 'cellar\'s');
      });

      test('a caller\'s encrypted: false and originalSize on an encrypted '
          'object do not override cellar\'s', () async {
        final raw = InMemoryBackend();
        final enc = encryptedOver(raw);
        final bytes = _plain(120, 3);

        await enc.write(
          'e',
          bytes,
          const WriteOptions(
            metadata: {'encrypted': 'false', 'originalSize': '5'},
          ),
        );
        await enc.writeStream(
          'e2',
          Stream.value(bytes),
          const WriteOptions(
            metadata: {'encrypted': 'false', 'originalSize': '5'},
          ),
        );

        for (final key in ['e', 'e2']) {
          expect(await enc.read(key), bytes, reason: key);
          final info = (await enc.head(key))!;
          expect(info.size, 120, reason: 'not the caller\'s 5');
          expect(info.metadata['encrypted'], 'false');
          expect(info.metadata['originalSize'], '5');
          expect(info.metadata['cellar.encrypted'], 'true');
          expect(info.metadata['cellar.originalSize'], '120');
        }
      });

      test('the whole stack round-trips all five names', () async {
        final stack = encryptedOver(chunkedOver(InMemoryBackend()));
        final bytes = _plain(400, 4);

        await stack.write('k', bytes, const WriteOptions(metadata: collide));
        await stack.writeStream(
          's',
          Stream.value(bytes),
          const WriteOptions(metadata: collide),
        );

        for (final key in ['k', 's']) {
          expect(await stack.read(key), bytes, reason: key);
          final info = (await stack.head(key))!;
          expect(info.size, 400);
          expect(_callerKeys(info.metadata), collide);
          expect(info.metadata['cellar.encrypted'], 'true');
        }
      });
    });

    group('the facade', () {
      Future<Cellar> open() async {
        final cellar = Cellar.withBackends(
          {'a': InMemoryBackend(), 'b': InMemoryBackend()},
          defaultPartition: 'a',
          encryption: CellarEncryption(
            encryptor: FakeEncryptor(),
            keyResolver: const FixedKeyResolver('facade-key'),
          ),
        );
        await cellar.open();
        return cellar;
      }

      test('copying and moving an encrypted object across partitions keeps it '
          'encrypted and readable', () async {
        final cellar = await open();
        final bytes = _plain(300, 5);
        await cellar.write(
          'k',
          bytes,
          partition: 'a',
          contentType: 'x/y',
          metadata: {'owner': 'u1'},
        );

        await cellar.copyAcrossPartitions(
          fromPartition: 'a',
          fromKey: 'k',
          toPartition: 'b',
          toKey: 'copied',
        );
        await cellar.moveAcrossPartitions(
          fromPartition: 'a',
          fromKey: 'k',
          toPartition: 'b',
          toKey: 'moved',
        );

        for (final key in ['copied', 'moved']) {
          expect(await cellar.read(key, partition: 'b'), bytes, reason: key);
          final info = (await cellar.head(key, partition: 'b'))!;
          expect(info.size, 300);
          expect(info.contentType, 'x/y');
          expect(info.metadata['owner'], 'u1');
          expect(info.metadata['cellar.encrypted'], 'true');
          expect(info.metadata['cellar.originalSize'], '300');
        }
        expect(await cellar.exists('k', partition: 'a'), isFalse);
        await cellar.close();
      });
    });
  });
}
