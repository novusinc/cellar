import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:cellar/cellar_lowlevel.dart';

/// ChunkedBackend over an in-memory backing — pure, runs on every platform.
void runChunkedBattery() {
  group('ChunkedBackend', () {
    late InMemoryBackend backing;
    late ChunkedBackend chunked;
    const chunkSize = 64;

    setUp(() {
      backing = InMemoryBackend();
      chunked = ChunkedBackend(backing: backing, chunkSize: chunkSize);
    });

    Uint8List seq(int n) =>
        Uint8List.fromList(List.generate(n, (i) => i % 256));

    group('a write that fails leaves no unreferenced chunks', () {
      late InMemoryBackend store;
      late _FlakyBacking flaky;
      late ChunkedBackend over;

      setUp(() {
        store = InMemoryBackend();
        flaky = _FlakyBacking(store);
        over = ChunkedBackend(backing: flaky, chunkSize: chunkSize);
      });

      test('a failed overwrite is reclaimed at once, and the previous object '
          'survives', () async {
        await over.write('k', seq(10)); // manifest + one chunk
        flaky.failChunkPutsAfter = 2;

        await expectLater(over.write('k', seq(300)), throwsA(isA<_Boom>()));

        expect(
          store.objectCount,
          2,
          reason: 'only the previous object\'s records',
        );
        expect(await over.read('k'), seq(10));
      });

      test('a failed streamed overwrite is reclaimed too', () async {
        await over.write('k', seq(10));
        Stream<List<int>> dying() async* {
          yield seq(150);
          throw _Boom();
        }

        await expectLater(
          over.writeStream('k', dying()),
          throwsA(isA<_Boom>()),
        );

        expect(store.objectCount, 2);
        expect(await over.read('k'), seq(10));
      });

      test('chunks a crash left behind are overwritten, and the tail of a '
          'longer failed attempt does not outlive a shorter write', () async {
        await over.write('k', seq(10));
        // A failure whose cleanup also fails stands in for a crash: the failed
        // attempt's chunks stay.
        flaky.failChunkPutsAfter = 4;
        flaky.failDeletes = true;
        await expectLater(over.write('k', seq(500)), throwsA(isA<_Boom>()));
        expect(store.objectCount, greaterThan(2), reason: 'the leak exists');
        flaky.failChunkPutsAfter = null;
        flaky.failDeletes = false;

        await over.write(
          'k',
          seq(10),
        ); // one chunk, shorter than the failed one

        expect(
          store.objectCount,
          2,
          reason: 'manifest + one chunk, nothing else',
        );
        expect(await over.read('k'), seq(10));
      });

      test('deleting removes every generation of the key', () async {
        await over.write('k', seq(10));
        flaky.failChunkPutsAfter = 4;
        flaky.failDeletes = true;
        await expectLater(over.write('k', seq(500)), throwsA(isA<_Boom>()));
        flaky.failChunkPutsAfter = null;
        flaky.failDeletes = false;

        await over.delete('k');

        expect(store.objectCount, 0, reason: 'no record of the key remains');
      });

      test(
        'a first write that fails and is then deleted leaves nothing',
        () async {
          flaky.failChunkPutsAfter = 3;
          flaky.failDeletes = true;
          await expectLater(over.write('k', seq(500)), throwsA(isA<_Boom>()));
          flaky.failChunkPutsAfter = null;
          flaky.failDeletes = false;

          await over.delete('k');

          expect(store.objectCount, 0);
        },
      );

      test(
        'a deletion that fails part-way has already removed the object',
        () async {
          await over.write('k', seq(200));
          flaky.failDeletes = true;

          await expectLater(over.delete('k'), throwsA(isA<_Boom>()));
          flaky.failDeletes = false;

          // The manifest went first, so nothing can read a half-deleted object.
          expect(await over.exists('k'), isFalse);
          await expectLater(over.read('k'), throwsA(isA<FileNotFoundError>()));
          // What is left is unreferenced, and the next write of the key sweeps it.
          await over.write('k', seq(10));
          expect(store.objectCount, 2);
        },
      );

      test(
        'a failed copy is reclaimed, and the destination keeps its object',
        () async {
          await over.write('src', seq(300));
          await over.write('dst', seq(10));
          final before = store.objectCount;
          flaky.failChunkPutsAfter = 2;

          await expectLater(over.copy('src', 'dst'), throwsA(isA<_Boom>()));

          expect(store.objectCount, before);
          expect(await over.read('dst'), seq(10));
        },
      );
    });

    group('list over a backing that can list by suffix', () {
      test('uses it, and reads no chunk record', () async {
        final spy = _SuffixSpyBacking();
        final over = ChunkedBackend(backing: spy, chunkSize: chunkSize);
        await over.write(
          'a',
          seq(200),
          const WriteOptions(contentType: 'x/y', metadata: {'k': 'v'}),
        );
        await over.write('b', seq(10));
        spy.reads.clear();

        final listed = await over.list('');

        expect(listed.map((i) => (i.key, i.size)).toSet(), {
          ('a', 200),
          ('b', 10),
        });
        expect(listed.firstWhere((i) => i.key == 'a').contentType, 'x/y');
        expect(listed.firstWhere((i) => i.key == 'a').metadata, {'k': 'v'});
        expect(spy.listCalls, 0, reason: 'plain list reads every record');
        expect(spy.suffixCalls, [('', '__manifest')]);
        expect(spy.reads, isEmpty, reason: 'nothing was read to answer');
      });

      test('gives the same answer as a backing that cannot', () async {
        final plain = ChunkedBackend(
          backing: InMemoryBackend(),
          chunkSize: chunkSize,
        );
        final suffix = ChunkedBackend(
          backing: _SuffixSpyBacking(),
          chunkSize: chunkSize,
        );
        for (final over in [plain, suffix]) {
          await over.write(
            'd/one',
            seq(130),
            const WriteOptions(metadata: {'a': 'b'}),
          );
          await over.write('d/two', seq(5));
          await over.write('e/three', seq(70));
        }

        // A Map has no value equality, so compare what each listing says as text.
        Future<List<String>> described(
          ChunkedBackend over,
          String prefix,
        ) async => [
          for (final i in await over.list(prefix))
            '${i.key}|${i.size}|${i.contentType}|${i.metadata}',
        ]..sort();

        for (final prefix in ['', 'd/', 'd/o', 'e', 'zzz']) {
          expect(
            await described(suffix, prefix),
            await described(plain, prefix),
            reason: 'prefix "$prefix"',
          );
        }
      });
    });

    group('overwrite reclaims orphan chunks', () {
      test('write shrink deletes the tail chunks', () async {
        await chunked.write('k', seq(200)); // 4 chunks + manifest = 5 records
        expect(backing.objectCount, 5);
        await chunked.write('k', seq(10)); // shrinks to 1 chunk + manifest
        expect(
          backing.objectCount,
          2,
          reason: 'stale chunks from the larger write must be reclaimed',
        );
        expect(await chunked.read('k'), seq(10));
      });

      test('writeStream shrink deletes the tail chunks', () async {
        await chunked.writeStream('k', Stream.value(seq(200)));
        expect(backing.objectCount, 5);
        await chunked.writeStream('k', Stream.value(seq(10)));
        expect(
          backing.objectCount,
          2,
          reason:
              'stale chunks from the larger streamed write must be reclaimed',
        );
        expect(await chunked.read('k'), seq(10));
      });
    });

    group('round-trip', () {
      test('write then read returns identical bytes', () async {
        final data = seq(200);
        await chunked.write('a', data);
        expect(await chunked.read('a'), data);
      });

      test('writeStream produces the same content as write', () async {
        final data = seq(200);
        await chunked.writeStream('a', Stream.value(data));
        expect(await chunked.read('a'), data);
      });

      test('round-trips across boundary sizes', () async {
        for (final size in [
          0,
          1,
          chunkSize - 1,
          chunkSize,
          chunkSize + 1,
          chunkSize * 3,
          chunkSize * 10 + 7,
        ]) {
          final data = seq(size);
          await chunked.write('size-$size', data);
          expect(await chunked.read('size-$size'), data, reason: 'size=$size');
        }
      });
    });

    group('readRange', () {
      setUp(() async {
        await chunked.write('data', seq(200));
      });

      test('returns exact bytes inside one chunk', () async {
        expect(
          await chunked.readRange('data', start: 5, length: 10),
          Uint8List.fromList(List.generate(10, (i) => 5 + i)),
        );
      });

      test('returns exact bytes across two chunks', () async {
        // chunkSize=64; range 60..68 spans chunks 0 and 1.
        expect(
          await chunked.readRange('data', start: 60, length: 8),
          Uint8List.fromList(List.generate(8, (i) => 60 + i)),
        );
      });

      test('returns exact bytes across three chunks', () async {
        // 60..132 spans chunks 0, 1, 2.
        expect(
          await chunked.readRange('data', start: 60, length: 72),
          Uint8List.fromList(List.generate(72, (i) => 60 + i)),
        );
      });

      test('clamps when length runs past end', () async {
        // Total is 200; ask for 50 starting at 180 → only 20 bytes available.
        final out = await chunked.readRange('data', start: 180, length: 50);
        expect(out.length, 20);
      });

      test('returns empty for zero length', () async {
        expect(
          (await chunked.readRange('data', start: 0, length: 0)).length,
          0,
        );
      });

      test('throws FileNotFoundError on missing key', () async {
        expect(
          () => chunked.readRange('missing', start: 0, length: 1),
          throwsA(isA<FileNotFoundError>()),
        );
      });
    });

    group('atomicity', () {
      test('manifest written last makes partial writes invisible', () async {
        // ChunkedBackend writes chunks, then the manifest. After we yank
        // the manifest record out (simulating a crash mid-write), the key
        // should look like it never existed to head/exists/list/read.
        final data = seq(200);
        await chunked.write('a', data);

        // Find and delete the manifest record from the backing store.
        final all = await backing.list('');
        final manifestKey = all
            .firstWhere((info) => info.key.endsWith('__manifest'))
            .key;
        await backing.delete(manifestKey);

        expect(await chunked.exists('a'), isFalse);
        expect(await chunked.head('a'), isNull);
        expect(() => chunked.read('a'), throwsA(isA<FileNotFoundError>()));
      });

      test(
        'subsequent write to same key works after orphaned chunks',
        () async {
          final data = seq(200);
          await chunked.write('a', data);

          // Yank manifest.
          final manifestKey = (await backing.list(
            '',
          )).firstWhere((i) => i.key.endsWith('__manifest')).key;
          await backing.delete(manifestKey);

          // Write again — orphaned chunks should be cleaned up implicitly.
          await chunked.write('a', seq(50));
          expect(await chunked.read('a'), seq(50));
        },
      );
    });

    group('delete', () {
      test('delete removes manifest + all chunks', () async {
        await chunked.write('a', seq(200));
        final beforeCount = backing.objectCount;
        expect(beforeCount, greaterThan(1)); // multiple records

        await chunked.delete('a');
        expect(await chunked.exists('a'), isFalse);
        expect(backing.objectCount, 0);
      });

      test('deletePrefix removes chunked objects under the prefix', () async {
        await chunked.write('photos/a', seq(100));
        await chunked.write('photos/b', seq(100));
        await chunked.write('docs/c', seq(100));

        await chunked.deletePrefix('photos/');
        expect(await chunked.exists('photos/a'), isFalse);
        expect(await chunked.exists('photos/b'), isFalse);
        expect(await chunked.exists('docs/c'), isTrue);
      });
    });

    group('list + head', () {
      test('list returns one entry per logical key (not per chunk)', () async {
        await chunked.write('a', seq(200)); // 4 chunks
        await chunked.write('b', seq(50)); // 1 chunk

        final results = await chunked.list('');
        expect(results.length, 2);
        expect(results.map((i) => i.key).toSet(), {'a', 'b'});
      });

      test('head returns logical size (sum of chunks)', () async {
        await chunked.write('a', seq(200));
        final info = await chunked.head('a');
        expect(info!.size, 200);
      });

      test('lastModified is non-null on chunked head', () async {
        await chunked.write('a', seq(200));
        final info = await chunked.head('a');
        expect(info!.lastModified, isNotNull);
      });
    });
  });
}

/// An in-memory backing that can list by suffix, and records what it is asked.
class _SuffixSpyBacking extends ForwardingBackend
    implements SuffixListableBackend {
  _SuffixSpyBacking() : super(InMemoryBackend());

  int listCalls = 0;
  final List<(String, String)> suffixCalls = [];
  final List<String> reads = [];

  @override
  Future<List<ObjectInfo>> list(String prefix) {
    listCalls++;
    return super.list(prefix);
  }

  @override
  Future<List<ObjectInfo>> listEndingWith(String prefix, String suffix) async {
    suffixCalls.add((prefix, suffix));
    return [
      for (final info in await inner.list(prefix))
        if (info.key.endsWith(suffix)) info,
    ];
  }

  @override
  Future<Uint8List> read(String key) {
    reads.add(key);
    return super.read(key);
  }

  @override
  Future<ObjectInfo?> head(String key) {
    reads.add(key);
    return super.head(key);
  }
}

/// A failure the tests cause on purpose.
class _Boom implements Exception {
  @override
  String toString() => 'boom';
}

/// A backing whose chunk writes can start failing, and whose deletions can fail,
/// to stand in for a full quota and for a crash.
class _FlakyBacking extends ForwardingBackend {
  _FlakyBacking(InMemoryBackend super.inner);

  /// Chunk records that may still be written before every further one fails;
  /// null for no failure.
  int? failChunkPutsAfter;

  /// Whether deletions (of chunks and by prefix) fail.
  bool failDeletes = false;

  int _chunkPuts = 0;

  @override
  Future<void> write(
    String key,
    Uint8List bytes, [
    WriteOptions options = const WriteOptions(),
  ]) {
    if (key.contains('__c')) {
      _chunkPuts++;
      final limit = failChunkPutsAfter;
      if (limit != null && _chunkPuts > limit) throw _Boom();
    }
    return super.write(key, bytes, options);
  }

  @override
  Future<void> delete(String key) {
    if (failDeletes && key.contains('__c')) throw _Boom();
    return super.delete(key);
  }

  @override
  Future<void> deletePrefix(String prefix) {
    if (failDeletes && prefix.contains('__g')) throw _Boom();
    return super.deletePrefix(prefix);
  }
}
