import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:cellar/cellar_lowlevel.dart';

/// ForwardingBackend — the public base for decorators. Pure, runs on every
/// platform. The conformance runs prove a bare wrapper behaves like its
/// inner backend; this battery pins what conformance cannot see: that each of
/// the 13 methods reaches `inner` with its arguments intact, that disposing
/// the wrapper leaves `inner` alone, and that a subclass override composes.
void runForwardingBattery() {
  group('ForwardingBackend', () {
    late _RecordingBackend inner;
    late ForwardingBackend wrapper;

    setUp(() {
      inner = _RecordingBackend();
      wrapper = ForwardingBackend(inner);
    });

    final bytes = Uint8List.fromList([1, 2, 3]);
    const options = WriteOptions(
      contentType: 'image/png',
      metadata: {'kind': 'avatar'},
    );

    test('forwards write with its options', () async {
      await wrapper.write('a', bytes, options);
      expect(inner.calls, ['write a [1, 2, 3] image/png {kind: avatar}']);
    });

    test('forwards writeStream with its options', () async {
      await wrapper.writeStream('a', Stream.value(bytes), options);
      expect(inner.calls, ['writeStream a image/png {kind: avatar}']);
    });

    test('forwards read, readStream, readRange', () async {
      await wrapper.read('a');
      await wrapper.readStream('a').drain<void>();
      await wrapper.readRange('a', start: 4, length: 8);
      expect(inner.calls, ['read a', 'readStream a', 'readRange a 4 8']);
    });

    test('forwards head, exists, list', () async {
      await wrapper.head('a');
      await wrapper.exists('a');
      await wrapper.list('p/');
      expect(inner.calls, ['head a', 'exists a', 'list p/']);
    });

    test('forwards delete, deletePrefix, copy', () async {
      await wrapper.delete('a');
      await wrapper.deletePrefix('p/');
      await wrapper.copy('a', 'b');
      expect(inner.calls, ['delete a', 'deletePrefix p/', 'copy a b']);
    });

    test('forwards updateMetadata with both arguments', () async {
      await wrapper.updateMetadata(
        'a',
        contentType: 'text/plain',
        metadata: const {'x': 'y'},
      );
      expect(inner.calls, ['updateMetadata a text/plain {x: y}']);
    });

    test('forwards materialize with both flags', () async {
      final file = await wrapper.materialize(
        'a',
        decrypt: false,
        exclusive: true,
      );
      expect(inner.calls, ['materialize a false true']);
      expect(file.key, 'a');
    });

    test(
      'returns what inner returns, and rethrows what inner throws',
      () async {
        final backing = InMemoryBackend();
        final over = ForwardingBackend(backing);
        await over.write('k', bytes);
        expect(await over.read('k'), bytes);
        expect(
          () => over.read('missing'),
          throwsA(isA<FileNotFoundError>()),
          reason: 'a typed error from inner reaches the caller unchanged',
        );
      },
    );

    test('a subclass override composes with the forwarded rest', () async {
      final backing = InMemoryBackend();
      final counting = _CountingReads(backing);
      await counting.write('k', bytes);
      await counting.read('k');
      await counting.read('k');
      expect(counting.reads, 2);
      expect(backing.objectCount, 1, reason: 'write was forwarded, not eaten');
    });

    group('dispose', () {
      test('is idempotent and does not dispose inner', () async {
        await wrapper.dispose();
        await wrapper.dispose();
        expect(inner.disposed, isFalse, reason: 'the creator disposes inner');
      });

      test(
        'every method throws StateError afterwards, reaching nothing',
        () async {
          await wrapper.dispose();
          await expectLater(wrapper.write('a', bytes), throwsStateError);
          await expectLater(wrapper.read('a'), throwsStateError);
          await expectLater(wrapper.head('a'), throwsStateError);
          await expectLater(wrapper.list(''), throwsStateError);
          await expectLater(wrapper.delete('a'), throwsStateError);
          await expectLater(wrapper.copy('a', 'b'), throwsStateError);
          await expectLater(wrapper.materialize('a'), throwsStateError);
          await expectLater(wrapper.readStream('a').toList(), throwsStateError);
          expect(inner.calls, isEmpty);
        },
      );

      test('the error names the subclass', () async {
        final counting = _CountingReads(InMemoryBackend());
        await counting.dispose();
        await expectLater(
          counting.read('a'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('_CountingReads'),
            ),
          ),
        );
      });
    });
  });
}

class _CountingReads extends ForwardingBackend {
  _CountingReads(super.inner);

  int reads = 0;

  @override
  Future<Uint8List> read(String key) {
    reads++;
    return super.read(key);
  }
}

/// Records every call it receives as one line, and answers with the cheapest
/// valid value, so a test can assert what reached it and with which arguments.
class _RecordingBackend implements StorageBackend {
  final List<String> calls = [];
  bool disposed = false;

  @override
  Future<void> write(
    String key,
    Uint8List bytes, [
    WriteOptions options = const WriteOptions(),
  ]) async {
    calls.add('write $key $bytes ${options.contentType} ${options.metadata}');
  }

  @override
  Future<void> writeStream(
    String key,
    Stream<List<int>> byteStream, [
    WriteOptions options = const WriteOptions(),
  ]) async {
    await byteStream.drain<void>();
    calls.add('writeStream $key ${options.contentType} ${options.metadata}');
  }

  @override
  Stream<List<int>> readStream(String key) {
    calls.add('readStream $key');
    return const Stream.empty();
  }

  @override
  Future<Uint8List> read(String key) async {
    calls.add('read $key');
    return Uint8List(0);
  }

  @override
  Future<Uint8List> readRange(
    String key, {
    required int start,
    required int length,
  }) async {
    calls.add('readRange $key $start $length');
    return Uint8List(0);
  }

  @override
  Future<ObjectInfo?> head(String key) async {
    calls.add('head $key');
    return null;
  }

  @override
  Future<bool> exists(String key) async {
    calls.add('exists $key');
    return false;
  }

  @override
  Future<void> delete(String key) async {
    calls.add('delete $key');
  }

  @override
  Future<void> deletePrefix(String prefix) async {
    calls.add('deletePrefix $prefix');
  }

  @override
  Future<List<ObjectInfo>> list(String prefix) async {
    calls.add('list $prefix');
    return const [];
  }

  @override
  Future<void> copy(String sourceKey, String destKey) async {
    calls.add('copy $sourceKey $destKey');
  }

  @override
  Future<void> updateMetadata(
    String key, {
    String? contentType,
    Map<String, String> metadata = const {},
  }) async {
    calls.add('updateMetadata $key $contentType $metadata');
  }

  @override
  Future<MaterializedFile> materialize(
    String key, {
    bool decrypt = true,
    bool exclusive = false,
  }) async {
    calls.add('materialize $key $decrypt $exclusive');
    return MaterializedFile(
      localPath: '/x/$key',
      key: key,
      release: () async {},
    );
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}
