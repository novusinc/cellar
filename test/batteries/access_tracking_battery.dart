/// AccessTrackingBackend over any backend: reads are recorded in the object's own
/// metadata, in the background, throttled, and never change lastModified.
/// Platform-blind; each runner invokes it over the backends it can host.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:cellar/cellar.dart';
import 'package:cellar/cellar_lowlevel.dart';
import 'package:test/test.dart';

/// Runs the battery over the backend [create] makes (one per test).
void runAccessTrackingBattery(
  String label, {
  required StorageBackend Function() create,
}) {
  group('AccessTrackingBackend over $label', () {
    late StorageBackend base;
    late DateTime clock;
    late List<(String, Object)> errors;
    late AccessTrackingBackend tracker;

    setUp(() {
      base = create();
      clock = DateTime.utc(2026, 11, 26, 12);
      errors = [];
      tracker = AccessTrackingBackend(
        base,
        minInterval: const Duration(minutes: 1),
        now: () => clock,
        onError: (key, error) => errors.add((key, error)),
      );
    });

    Uint8List bytes(int n) =>
        Uint8List.fromList(List.generate(n, (i) => i & 255));

    Future<Map<String, String>> metadataOf(String key) async {
      await tracker.idle();
      return (await base.head(key))!.metadata;
    }

    int micros(DateTime t) => t.toUtc().microsecondsSinceEpoch;

    test('a read records when it happened and that it happened once', () async {
      await tracker.write(
        'k',
        bytes(100),
        const WriteOptions(metadata: {'owner': 'u1'}),
      );

      expect(await tracker.read('k'), bytes(100));

      final metadata = await metadataOf('k');
      expect(metadata[accessedAtMetadataKey], '${micros(clock)}');
      expect(metadata[accessCountMetadataKey], '1');
      expect(
        metadata['owner'],
        'u1',
        reason: 'the caller\'s keys are untouched',
      );
    });

    test('every kind of read records, once its stream has started', () async {
      for (final key in ['a', 'b', 'c']) {
        await tracker.write(key, bytes(300));
      }

      await tracker.read('a');
      await tracker.readStream('b').toList();
      await tracker.readRange('c', start: 10, length: 20);

      for (final key in ['a', 'b', 'c']) {
        expect(
          (await metadataOf(key))[accessCountMetadataKey],
          '1',
          reason: key,
        );
      }
    });

    test(
      'reads within the interval are recorded once, and a later one again',
      () async {
        await tracker.write('k', bytes(10));

        await tracker.read('k');
        clock = clock.add(const Duration(seconds: 30));
        await tracker.read('k');
        await tracker.read('k');
        var metadata = await metadataOf('k');
        expect(metadata[accessCountMetadataKey], '1');
        expect(
          metadata[accessedAtMetadataKey],
          '${micros(DateTime.utc(2026, 11, 26, 12))}',
        );

        clock = clock.add(const Duration(seconds: 31));
        await tracker.read('k');
        metadata = await metadataOf('k');
        expect(metadata[accessCountMetadataKey], '2');
        expect(metadata[accessedAtMetadataKey], '${micros(clock)}');
      },
    );

    test('keys are throttled separately', () async {
      await tracker.write('a', bytes(10));
      await tracker.write('b', bytes(10));

      await tracker.read('a');
      await tracker.read('b');

      expect((await metadataOf('a'))[accessCountMetadataKey], '1');
      expect((await metadataOf('b'))[accessCountMetadataKey], '1');
    });

    test(
      'lastModified and the bytes are the same after any number of reads',
      () async {
        await tracker.write(
          'k',
          bytes(5000),
          const WriteOptions(contentType: 'x/y'),
        );
        final before = (await base.head('k'))!;

        for (var i = 0; i < 4; i++) {
          clock = clock.add(const Duration(minutes: 2));
          await tracker.read('k');
          await tracker.idle();
        }

        final after = (await base.head('k'))!;
        expect(after.metadata[accessCountMetadataKey], '4');
        expect(
          after.lastModified,
          before.lastModified,
          reason: 'maxAge reads it',
        );
        expect(after.size, before.size);
        expect(after.contentType, 'x/y');
        expect(await base.read('k'), bytes(5000));
      },
    );

    test('a missing key throws and records nothing', () async {
      await expectLater(
        tracker.read('nope'),
        throwsA(isA<FileNotFoundError>()),
      );
      await tracker.idle();

      expect(await base.exists('nope'), isFalse);
      expect(errors, isEmpty);
    });

    group('a read never waits for, or fails because of, the record', () {
      test('a record that is slow does not delay the read', () async {
        final gate = Completer<void>();
        final slow = _SlowPatch(base, gate.future);
        final over = AccessTrackingBackend(slow, now: () => clock);
        await over.write('k', bytes(10));

        expect(await over.read('k'), bytes(10)); // returns with the patch held

        gate.complete();
        await over.idle();
        expect((await base.head('k'))!.metadata[accessCountMetadataKey], '1');
      });

      test(
        'a record that fails is reported, and the read still succeeds',
        () async {
          final over = AccessTrackingBackend(
            _FailingPatch(base),
            now: () => clock,
            onError: (key, error) => errors.add((key, error)),
          );
          await over.write('k', bytes(10));

          expect(await over.read('k'), bytes(10));
          await over.idle();

          expect(errors.map((e) => e.$1), ['k']);
          expect(errors.single.$2, isA<StateError>());
          expect(await over.read('k'), bytes(10), reason: 'and keeps working');
        },
      );

      test('a failure with no onError is silent', () async {
        final over = AccessTrackingBackend(
          _FailingPatch(base),
          now: () => clock,
        );
        await over.write('k', bytes(10));

        expect(await over.read('k'), bytes(10));
        await over.idle();
      });
    });

    group('metadata and objects it forgets', () {
      test('updateMetadata keeps the access record', () async {
        await tracker.write('k', bytes(10));
        await tracker.read('k');
        await tracker.idle();

        await tracker.updateMetadata(
          'k',
          contentType: 'a/b',
          metadata: {'t': '1'},
        );

        final metadata = (await base.head('k'))!.metadata;
        expect(metadata['t'], '1');
        expect(metadata[accessCountMetadataKey], '1');
        expect(metadata[accessedAtMetadataKey], isNotNull);
      });

      test('a rewritten object starts with no access record, and its first '
          'read is recorded even inside the interval', () async {
        await tracker.write('k', bytes(10));
        await tracker.read('k');
        await tracker.idle();

        await tracker.write(
          'k',
          bytes(20),
        ); // same instant: inside the interval
        expect(
          (await base.head('k'))!.metadata.containsKey(accessCountMetadataKey),
          isFalse,
        );
        await tracker.read('k');

        expect((await metadataOf('k'))[accessCountMetadataKey], '1');
      });

      test('a deleted object is forgotten, and a new one under the same key '
          'is tracked afresh', () async {
        await tracker.write('k', bytes(10));
        await tracker.read('k');
        await tracker.idle();
        await tracker.delete('k');
        await tracker.write('k', bytes(10));

        await tracker.read('k');

        expect((await metadataOf('k'))[accessCountMetadataKey], '1');
      });
    });

    test('dispose leaves the wrapped backend alone, and a pending record does '
        'not outlive a disposed inner', () async {
      await tracker.write('k', bytes(10));
      await tracker.read('k');
      await tracker.dispose();
      await tracker.idle();

      await base.write('still', bytes(3));
      expect(await base.read('still'), bytes(3));
      await expectLater(tracker.read('k'), throwsStateError);
    });
  });

  group('AccessTrackingBackend feeds least-recently-used eviction', () {
    test('what was read is kept, and what was not is evicted', () async {
      final backing = InMemoryBackend();
      var clock = DateTime.utc(2026, 11, 26, 12);
      final tracker = AccessTrackingBackend(
        backing,
        minInterval: Duration.zero,
        now: () => clock,
      );
      final cellar = Cellar.withBackends(
        {'cache': tracker},
        defaultPartition: 'cache',
        lifecycles: {
          'cache': const Lifecycle(
            maxBytes: 20,
            evictionPolicy: EvictionPolicy.leastRecentlyUsed,
          ),
        },
      );
      await cellar.open();
      for (var i = 0; i < 4; i++) {
        await cellar.write('item-$i', Uint8List(10));
        backing.setLastModified('item-$i', DateTime.utc(2020, 1, 1, 0, 0, i));
      }
      // item-0 is the oldest written, but is used most recently; item-2 next.
      clock = clock.add(const Duration(seconds: 1));
      await cellar.read('item-2');
      clock = clock.add(const Duration(seconds: 1));
      await cellar.read('item-0');
      await tracker.idle();

      await cellar.runLifecycleNow();

      expect(
        {for (final i in await cellar.list('')) i.key},
        {'item-0', 'item-2'},
      );
      await cellar.close();
    });
  });
}

/// A backend whose patches wait for [_release] before they happen.
class _SlowPatch extends ForwardingBackend {
  _SlowPatch(super.inner, this._release);

  final Future<void> _release;

  @override
  Future<void> patchMetadata(String key, Map<String, String?> changes) async {
    await _release;
    return super.patchMetadata(key, changes);
  }
}

/// A backend whose patches always fail.
class _FailingPatch extends ForwardingBackend {
  _FailingPatch(super.inner);

  @override
  Future<void> patchMetadata(String key, Map<String, String?> changes) =>
      Future.error(StateError('patch refused'));
}
