/// HookedBackend over any backend: before hooks may change or veto, after hooks
/// observe and never fail the call. Platform-blind.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:cellar/cellar_lowlevel.dart';
import 'package:test/test.dart';

/// Runs the battery over the backend [create] makes (one per test).
void runHooksBattery(
  String label, {
  required StorageBackend Function() create,
}) {
  group('HookedBackend over $label', () {
    late StorageBackend base;
    late List<String> log;
    late List<(String, String, Object)> errors;

    setUp(() {
      base = create();
      log = [];
      errors = [];
    });

    Uint8List bytes(int n) =>
        Uint8List.fromList(List.generate(n, (i) => i & 255));

    HookedBackend hooked({
      BeforeWriteHook? beforeWrite,
      AfterWriteHook? afterWrite,
      BeforeDeleteHook? beforeDelete,
      AfterDeleteHook? afterDelete,
      AfterReadHook? afterRead,
    }) => HookedBackend(
      base,
      hooks: StorageHooks(
        beforeWrite:
            beforeWrite ??
            (key, options) {
              log.add('beforeWrite $key');
              return options;
            },
        afterWrite:
            afterWrite ??
            (key, options) {
              log.add('afterWrite $key');
            },
        beforeDelete:
            beforeDelete ??
            (key, {required prefix}) {
              log.add('beforeDelete $key prefix=$prefix');
            },
        afterDelete:
            afterDelete ??
            (key, {required prefix}) {
              log.add('afterDelete $key prefix=$prefix');
            },
        afterRead:
            afterRead ??
            (key) {
              log.add('afterRead $key');
            },
        onHookError: (hook, key, error) => errors.add((hook, key, error)),
      ),
    );

    test('every hook runs, in order, around the call it belongs to', () async {
      final backend = hooked();

      await backend.write('a', bytes(10));
      await backend.read('a');
      await backend.readRange('a', start: 0, length: 5);
      await backend.readStream('a').drain<void>();
      await backend.copy('a', 'b');
      await backend.delete('a');
      await backend.deletePrefix('b');

      expect(log, [
        'beforeWrite a',
        'afterWrite a',
        'afterRead a',
        'afterRead a',
        'afterRead a',
        'beforeWrite b',
        'afterWrite b',
        'beforeDelete a prefix=false',
        'afterDelete a prefix=false',
        'beforeDelete b prefix=true',
        'afterDelete b prefix=true',
      ]);
    });

    test('writeStream is hooked like write', () async {
      final backend = hooked();

      await backend.writeStream('s', Stream.value(bytes(40)));

      expect(log, ['beforeWrite s', 'afterWrite s']);
      expect(await base.read('s'), bytes(40));
    });

    test('a before hook that throws vetoes the write: nothing is stored and '
        'the caller gets the error', () async {
      final backend = hooked(
        beforeWrite: (key, options) =>
            key == 'no' ? throw StateError('vetoed') : options,
      );

      await expectLater(backend.write('no', bytes(5)), throwsStateError);
      await expectLater(
        backend.writeStream('no', Stream.value(bytes(5))),
        throwsStateError,
      );
      await expectLater(backend.copy('yes', 'no'), throwsA(anything));

      expect(await base.exists('no'), isFalse);
      await backend.write('yes', bytes(5));
      expect(await base.exists('yes'), isTrue);
    });

    test(
      'a before hook may change the options the object is written with',
      () async {
        final backend = hooked(
          beforeWrite: (key, options) => WriteOptions(
            contentType: 'stamped/by-hook',
            metadata: {...options.metadata, 'stamp': key},
          ),
        );

        await backend.write(
          'k',
          bytes(5),
          const WriteOptions(metadata: {'own': '1'}),
        );
        await backend.writeStream('s', Stream.value(bytes(5)));

        final info = (await base.head('k'))!;
        expect(info.contentType, 'stamped/by-hook');
        expect(info.metadata['stamp'], 'k');
        expect(info.metadata['own'], '1');
        expect((await base.head('s'))!.metadata['stamp'], 's');
        expect((await base.head('s'))!.contentType, 'stamped/by-hook');
      },
    );

    test(
      'an after hook sees the options the object was written with',
      () async {
        WriteOptions? seen;
        final backend = hooked(
          beforeWrite: (key, options) =>
              WriteOptions(metadata: {...options.metadata, 'x': 'y'}),
          afterWrite: (key, options) => seen = options,
        );

        await backend.write('k', bytes(5));

        expect(seen!.metadata['x'], 'y');
      },
    );

    test('an after hook that throws neither undoes nor fails the call, and is '
        'reported', () async {
      final backend = hooked(
        afterWrite: (key, options) => throw StateError('boom write'),
        afterRead: (key) => throw StateError('boom read'),
        afterDelete: (key, {required prefix}) => throw StateError('boom del'),
      );

      await backend.write('k', bytes(5));
      expect(await backend.read('k'), bytes(5));
      await backend.delete('k');

      expect(
        await base.exists('k'),
        isFalse,
        reason: 'the delete went through',
      );
      expect(errors.map((e) => (e.$1, e.$2)), [
        ('afterWrite', 'k'),
        ('afterRead', 'k'),
        ('afterDelete', 'k'),
      ]);
      expect(errors.every((e) => e.$3 is StateError), isTrue);
    });

    test(
      'a before hook that throws vetoes a delete and leaves the object',
      () async {
        final backend = hooked(
          beforeDelete: (key, {required prefix}) => throw StateError('keep it'),
        );
        await backend.write('k', bytes(5));

        await expectLater(backend.delete('k'), throwsStateError);
        await expectLater(backend.deletePrefix(''), throwsStateError);

        expect(await base.read('k'), bytes(5));
      },
    );

    test('after hooks do not run for a call that failed', () async {
      final backend = hooked();

      await expectLater(
        backend.read('missing'),
        throwsA(isA<FileNotFoundError>()),
      );
      Stream<List<int>> dying() async* {
        yield bytes(3);
        throw StateError('source died');
      }

      await expectLater(backend.writeStream('k', dying()), throwsStateError);

      expect(log, ['beforeWrite k'], reason: 'no afterRead, no afterWrite');
    });

    test('afterRead of a stream runs when it has been read to its end, not '
        'when it is cancelled', () async {
      final backend = hooked();
      await base.write('k', bytes(300));

      final subscription = backend.readStream('k').listen((_) {});
      await subscription.cancel();
      expect(log, isEmpty);

      await backend.readStream('k').drain<void>();
      expect(log, ['afterRead k']);
    });

    test('with no hooks it is a plain pass-through', () async {
      final plain = HookedBackend(base, hooks: const StorageHooks());

      await plain.write('k', bytes(20), const WriteOptions(contentType: 'a/b'));

      expect(await plain.read('k'), bytes(20));
      expect((await plain.head('k'))!.contentType, 'a/b');
      await plain.delete('k');
      expect(await plain.exists('k'), isFalse);
    });

    test('dispose leaves the wrapped backend alone', () async {
      final backend = hooked();
      await backend.dispose();

      await base.write('k', bytes(3));
      expect(await base.read('k'), bytes(3));
      await expectLater(backend.write('x', bytes(1)), throwsStateError);
      expect(log, isEmpty, reason: 'a disposed backend runs no hooks');
    });
  });
}
