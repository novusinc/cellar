/// `UsageLedger`, `LedgerBackend` and `Lifecycle.enforceOnWrite` — pure, runs on every
/// platform.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:cellar/cellar.dart';
import 'package:cellar/cellar_lowlevel.dart';
import 'package:test/test.dart';

/// Counts the listings it is asked for: the cost the ledger exists to avoid.
class _Counting extends ForwardingBackend {
  _Counting(super.inner);

  int lists = 0;

  @override
  Future<List<ObjectInfo>> list(String prefix) {
    lists++;
    return super.list(prefix);
  }
}

/// Fails writes on request, to show a failed write leaves the ledger as it was.
class _Failing extends ForwardingBackend {
  _Failing(super.inner);

  bool failWrites = false;
  bool failHeads = false;

  @override
  Future<void> write(
    String key,
    Uint8List bytes, [
    WriteOptions options = const WriteOptions(),
  ]) {
    if (failWrites) throw StateError('disk full');
    return super.write(key, bytes, options);
  }

  @override
  Future<ObjectInfo?> head(String key) {
    if (failHeads) throw StateError('cannot read');
    return super.head(key);
  }
}

ObjectInfo _info(
  String key,
  int size, {
  Map<String, String> metadata = const {},
}) => ObjectInfo(
  key: key,
  size: size,
  lastModified: DateTime.utc(2020),
  metadata: metadata,
);

void runLedgerBattery() {
  group('UsageLedger', () {
    late UsageLedger ledger;

    setUp(() => ledger = UsageLedger());

    test('totals follow what is recorded and forgotten', () {
      ledger
        ..record(_info('a', 10))
        ..record(_info('b', 5));
      expect(ledger.totalBytes, 15);
      expect(ledger.count, 2);

      ledger.record(_info('a', 3)); // replaced, not added
      expect(ledger.totalBytes, 8);

      ledger.forget('b');
      expect(ledger.totalBytes, 3);

      ledger
        ..record(_info('x/1', 4))
        ..record(_info('x/2', 6));
      expect(ledger.bytesUnder('x/'), 10);
      expect(ledger.entriesUnder('x/').map((i) => i.key), {'x/1', 'x/2'});

      ledger.forgetPrefix('x/');
      expect(ledger.totalBytes, 3);
      expect(ledger.count, 1);
    });

    test('knows nothing is loaded until a complete listing has been taken', () {
      expect(ledger.isLoaded(''), isFalse);

      ledger
        ..beginSnapshot()
        ..endSnapshot('a/', [_info('a/1', 1)]);

      expect(ledger.isLoaded('a/'), isTrue);
      expect(ledger.isLoaded('a/deeper/'), isTrue);
      expect(ledger.isLoaded('b/'), isFalse, reason: 'another prefix');
      expect(ledger.isLoaded(''), isFalse, reason: 'wider than the listing');

      ledger
        ..beginSnapshot()
        ..endSnapshot('', const []);
      expect(ledger.isLoaded('b/'), isTrue);
    });

    test('says nothing of growth before the first complete listing', () {
      var told = 0;
      ledger
        ..addGrowthListener(() => told++)
        ..record(_info('a', 10));
      expect(
        told,
        0,
        reason: 'a total that is only partly known decides nothing',
      );

      ledger
        ..beginSnapshot()
        ..endSnapshot('', [_info('a', 10)]);
      expect(told, greaterThan(0));
      final afterLoad = told;

      ledger.record(_info('b', 1));
      expect(told, afterLoad + 1);

      ledger.record(_info('b', 1)); // the same size: not growth
      ledger.forget('b');
      expect(told, afterLoad + 1);
    });

    test('a listing does not undo what was written while it ran', () {
      ledger.record(_info('old', 7));

      ledger.beginSnapshot();
      ledger
        ..record(_info('new', 10)) // written after the listing read the backend
        ..forget('old'); // deleted after it too
      ledger.endSnapshot('', [_info('old', 7), _info('other', 1)]);

      expect(ledger['new']?.size, 10, reason: 'the listing never saw it');
      expect(
        ledger['old'],
        isNull,
        reason: 'the listing must not bring it back',
      );
      expect(ledger['other']?.size, 1);
      expect(ledger.totalBytes, 11);
    });

    test('a listing removes what it did not see, and corrects what it did', () {
      ledger
        ..record(_info('gone', 4))
        ..record(_info('kept', 4));

      ledger
        ..beginSnapshot()
        ..endSnapshot('', [_info('kept', 9)]);

      expect(ledger['gone'], isNull);
      expect(ledger['kept']?.size, 9);
      expect(ledger.totalBytes, 9);
    });

    test('a listing of a prefix leaves the rest alone', () {
      ledger
        ..record(_info('a/1', 4))
        ..record(_info('b/1', 4));

      ledger
        ..beginSnapshot()
        ..endSnapshot('a/', const []);

      expect(ledger['a/1'], isNull);
      expect(ledger['b/1']?.size, 4);
    });

    test('a listing that failed changes nothing', () {
      ledger
        ..record(_info('a', 4))
        ..beginSnapshot();
      ledger.record(_info('b', 1));
      ledger.abortSnapshot();

      expect(ledger.totalBytes, 5);
      // And the next listing is not held back by the one that failed.
      ledger
        ..beginSnapshot()
        ..endSnapshot('', [_info('a', 4)]);
      expect(ledger['b'], isNull);
    });

    test('a delete of a prefix while a listing ran is not undone by it', () {
      ledger.record(_info('p/1', 3));
      ledger
        ..beginSnapshot()
        ..forgetPrefix('p/')
        ..endSnapshot('', [_info('p/1', 3)]);
      expect(ledger['p/1'], isNull);
    });

    test('touch notes the use at once and asks for a record once a window', () {
      final t0 = DateTime.utc(2030);
      ledger.record(_info('a', 1));

      final first = ledger.touch('a', t0);
      expect(first, {
        accessedAtMetadataKey: '${t0.microsecondsSinceEpoch}',
        accessCountMetadataKey: '1',
      });

      final soon = t0.add(const Duration(seconds: 10));
      expect(ledger.touch('a', soon), isNull, reason: 'recorded a moment ago');
      expect(
        ledger['a']!.metadata[accessedAtMetadataKey],
        '${soon.microsecondsSinceEpoch}',
        reason: 'but the ledger knows at once, so eviction order is exact',
      );

      final later = t0.add(const Duration(seconds: 61));
      final again = ledger.touch('a', later);
      expect(again?[accessCountMetadataKey], '2');
    });

    test('touch of an object the ledger does not hold is nothing', () {
      expect(ledger.touch('missing', DateTime.now()), isNull);
    });

    test('a touch decides who is least recently used', () {
      final written = DateTime.utc(2020);
      ledger
        ..record(ObjectInfo(key: 'first', size: 1, lastModified: written))
        ..record(
          ObjectInfo(
            key: 'second',
            size: 1,
            lastModified: written.add(const Duration(seconds: 1)),
          ),
        )
        ..touch('first', DateTime.utc(2030));

      final order = ledger.entriesUnder('')
        ..sort(EvictionPolicy.leastRecentlyUsed.compare);

      expect(order.map((i) => i.key), ['second', 'first']);
    });

    test('applyPatch sets and removes keys, as the backend did', () {
      ledger
        ..record(_info('a', 1, metadata: {'x': '1', 'y': '2'}))
        ..applyPatch('a', {'x': null, 'z': '3'});
      expect(ledger['a']!.metadata, {'y': '2', 'z': '3'});

      ledger.applyPatch('missing', {'x': '1'}); // nothing to patch: no error
    });
  });

  group('LedgerBackend', () {
    late InMemoryBackend backing;
    late LedgerBackend backend;

    setUp(() {
      backing = InMemoryBackend();
      backend = LedgerBackend(backing);
    });

    /// What the ledger holds is what a listing of the backend returns.
    Future<void> expectMatchesBacking(String step) async {
      final listed = {for (final i in await backing.list('')) i.key: i};
      expect(
        backend.ledger.entriesUnder('').map((i) => i.key).toSet(),
        listed.keys.toSet(),
        reason: step,
      );
      for (final entry in listed.entries) {
        final held = backend.ledger[entry.key]!;
        expect(held.size, entry.value.size, reason: '$step: ${entry.key}');
        expect(held.metadata, entry.value.metadata, reason: step);
        expect(held.lastModified, entry.value.lastModified, reason: step);
      }
      expect(
        backend.ledger.totalBytes,
        listed.values.fold<int>(0, (a, i) => a + i.size),
        reason: step,
      );
    }

    test('holds what the backend holds after every kind of change', () async {
      await backend.write(
        'a',
        Uint8List(10),
        const WriteOptions(metadata: {'t': '1'}),
      );
      await expectMatchesBacking('write');

      await backend.writeStream(
        'b',
        Stream.fromIterable([Uint8List(10), Uint8List(15)]),
      );
      await expectMatchesBacking('writeStream');

      await backend.write('a', Uint8List(4)); // replaced by a smaller one
      await expectMatchesBacking('overwrite');
      expect(backend.ledger.totalBytes, 29);

      await backend.copy('a', 'c');
      await expectMatchesBacking('copy');

      await backend.move('b', 'd');
      await expectMatchesBacking('move');
      expect(backend.ledger['b'], isNull);

      await backend.updateMetadata('a', metadata: {'t': '2'});
      await expectMatchesBacking('updateMetadata');

      await backend.patchMetadata('c', {'x': '1'});
      await expectMatchesBacking('patchMetadata');

      await backend.delete('a');
      await expectMatchesBacking('delete');

      await backend.write('p/1', Uint8List(3));
      await backend.write('p/2', Uint8List(3));
      await backend.deletePrefix('p/');
      await expectMatchesBacking('deletePrefix');

      await backend.move('c', 'c'); // onto itself: unchanged
      await expectMatchesBacking('move onto itself');
    });

    test('a write that fails leaves the ledger as it was', () async {
      final failing = _Failing(backing);
      final over = LedgerBackend(failing);
      await over.write('a', Uint8List(10));

      failing.failWrites = true;
      await expectLater(
        over.write('a', Uint8List(99)),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        over.write('new', Uint8List(5)),
        throwsA(isA<StateError>()),
      );

      expect(over.ledger['a']?.size, 10);
      expect(over.ledger['new'], isNull);
      expect(over.ledger.totalBytes, 10);
    });

    test('a record that cannot be read back is reported and forgotten, and '
        'the write still stands', () async {
      final failing = _Failing(backing);
      final errors = <String>[];
      final over = LedgerBackend(
        failing,
        onError: (key, error) => errors.add(key),
      );

      failing.failHeads = true;
      await over.write('a', Uint8List(10));

      expect(errors, ['a']);
      expect(over.ledger['a'], isNull, reason: 'nothing is better than stale');
      expect(await backing.exists('a'), isTrue);
    });

    test('a listing through it is the truth: it loads the ledger and corrects '
        'it', () async {
      await backing.write('seen', Uint8List(10));
      await backing.write('also', Uint8List(5));
      expect(backend.ledger.isLoaded(''), isFalse);

      final listed = await backend.list('');

      expect(listed, hasLength(2));
      expect(backend.ledger.isLoaded(''), isTrue);
      expect(backend.ledger.totalBytes, 15);

      // The backend changed behind the ledger's back: the next listing corrects it.
      await backing.delete('seen');
      await backing.write('added', Uint8List(1));
      await backend.list('');
      expect(backend.ledger['seen'], isNull);
      expect(backend.ledger['added']?.size, 1);
      expect(backend.ledger.totalBytes, 6);
    });

    test('a write that finishes while a listing runs is kept', () async {
      await backing.write('a', Uint8List(1));
      final gate = Completer<void>();
      final slow = _SlowList(backing, gate.future);
      final over = LedgerBackend(slow);

      final listing = over.list('');
      await slow.started; // the listing has read the backend, and waits
      await over.write('b', Uint8List(20)); // not in what it read
      gate.complete();
      await listing;

      expect(over.ledger['b']?.size, 20);
      expect(over.ledger['a']?.size, 1);
    });

    test('importFile is refused over a backend that cannot import', () async {
      await expectLater(
        backend.importFile('k', '/nowhere'),
        throwsUnsupportedError,
      );
    });

    test('usageLedgerOf finds the ledger down the stack, and only there', () {
      final stacked = ForwardingBackend(ForwardingBackend(backend));
      expect(usageLedgerOf(stacked), same(backend.ledger));
      expect(usageLedgerOf(backing), isNull);
      expect(usageLedgerOf(ForwardingBackend(backing)), isNull);
    });
  });

  group('eviction on write', () {
    late InMemoryBackend backing;

    setUp(() => backing = InMemoryBackend());

    /// A cellar over [stack] (the backing by default), capped at [maxBytes].
    Future<Cellar> open({
      StorageBackend? stack,
      int maxBytes = 40,
      bool enforce = true,
      EvictionPolicy policy = EvictionPolicy.oldestWritten,
      CanEvict? canEvict,
      EvictionGuard? guard,
      void Function(String, String?, Object)? onError,
    }) async {
      final cellar = Cellar.withBackends(
        {'main': stack ?? backing},
        defaultPartition: 'main',
        lifecycles: {
          'main': Lifecycle.cache(
            maxBytes: maxBytes,
            enforceOnWrite: enforce,
            evictionPolicy: policy,
            canEvict: canEvict,
            evictionGuard: guard,
          ),
        },
        onEvictionError: onError,
      );
      await cellar.open();
      return cellar;
    }

    /// Ten bytes at each of [keys], in order. Written in order, so an eviction
    /// that goes oldest first goes in this order (ties in time break by key).
    Future<void> put(Cellar cellar, List<String> keys) async {
      for (final key in keys) {
        await cellar.write(key, Uint8List(10));
      }
    }

    Future<Set<String>> keysOf(StorageBackend backend) async => {
      for (final info in await backend.list('')) info.key,
    };

    test('a write that takes the partition over its cap evicts at once, with '
        'no timer and no call to run the lifecycle', () async {
      final cellar = await open();

      await put(cellar, ['k1', 'k2', 'k3', 'k4', 'k5']); // 50 bytes, cap 40
      await cellar.settle();

      expect(await keysOf(backing), {'k2', 'k3', 'k4', 'k5'});
      await cellar.close();
    });

    test(
      'without the switch, nothing is evicted until the timer\'s pass',
      () async {
        final cellar = await open(enforce: false);

        await put(cellar, ['k1', 'k2', 'k3', 'k4', 'k5']);
        await cellar.settle();
        expect(await keysOf(backing), hasLength(5));

        await cellar.runLifecycleNow();
        expect(await keysOf(backing), {'k2', 'k3', 'k4', 'k5'});
        await cellar.close();
      },
    );

    test('a write costs no listing, under the cap or over it', () async {
      final counting = _Counting(backing);
      final cellar = await open(stack: counting);
      await cellar.settle();
      final loadedWith = counting.lists;
      expect(loadedWith, 1, reason: 'one listing builds the ledger');

      await put(cellar, ['k1', 'k2', 'k3', 'k4']); // exactly the cap
      await cellar.settle();
      expect(counting.lists, loadedWith, reason: 'under the cap');

      await put(cellar, ['k5', 'k6']); // over it: evicts from the ledger
      await cellar.settle();
      expect(
        counting.lists,
        loadedWith,
        reason: 'over it, victims from memory',
      );
      expect(await keysOf(backing), {'k3', 'k4', 'k5', 'k6'});
      await cellar.close();
    });

    test('passes of one partition never overlap, however many writes come '
        'at once, and the partition ends under its cap', () async {
      var inGuard = 0;
      var mostAtOnce = 0;
      final cellar = await open(
        guard: (info, action) async {
          mostAtOnce = ++inGuard > mostAtOnce ? inGuard : mostAtOnce;
          await Future<void>.delayed(const Duration(milliseconds: 1));
          await action.evict();
          inGuard--;
        },
      );

      await Future.wait([
        for (var i = 0; i < 30; i++)
          cellar.write('k${i.toString().padLeft(2, '0')}', Uint8List(10)),
      ]);
      await cellar.settle();

      expect(mostAtOnce, 1);
      expect(await keysOf(backing), hasLength(4));
      await cellar.close();
    });

    test(
      'canEvict keeps an object, and the next in order goes in its place',
      () async {
        final cellar = await open(canEvict: (info) => info.key != 'k1');

        await put(cellar, ['k1', 'k2', 'k3', 'k4', 'k5']);
        await cellar.settle();

        expect(await keysOf(backing), {'k1', 'k3', 'k4', 'k5'});
        await cellar.close();
      },
    );

    test(
      'a guard that declines leaves the object, and the pass goes on',
      () async {
        final cellar = await open(
          guard: (info, action) async {
            if (info.key != 'k1') await action.evict();
          },
        );

        await put(cellar, ['k1', 'k2', 'k3', 'k4', 'k5']);
        await cellar.settle();

        expect(await keysOf(backing), {'k1', 'k3', 'k4', 'k5'});
        await cellar.close();
      },
    );

    test('keeping everything leaves the partition over its cap and ends the '
        'pass, rather than looping', () async {
      final cellar = await open(canEvict: (info) => false);

      await put(cellar, ['k1', 'k2', 'k3', 'k4', 'k5']);
      await cellar.settle();

      expect(await keysOf(backing), hasLength(5));
      await cellar.close();
    });

    test(
      'an object removed behind the cellar\'s back is dropped from the '
      'ledger when the guard finds it gone, and costs no live object',
      () async {
        final stack = LedgerBackend(backing);
        final cellar = await open(
          stack: stack,
          guard: (info, action) async {
            if (await action.head() == null) return;
            await action.evict();
          },
        );
        await put(cellar, ['k1', 'k2', 'k3', 'k4']);
        await cellar.settle();

        await backing.delete('k1'); // the ledger still counts it
        await cellar.write('k5', Uint8List(10)); // ledger says 50, truth is 40
        await cellar.settle();

        expect(await keysOf(backing), {'k2', 'k3', 'k4', 'k5'});
        expect(stack.ledger.count, 4);
        expect(stack.ledger.totalBytes, 40);
        await cellar.close();
      },
    );

    test('a partition already over its cap is brought under it when the '
        'cellar opens', () async {
      for (var i = 1; i <= 6; i++) {
        await backing.write('k$i', Uint8List(10));
        backing.setLastModified('k$i', DateTime.utc(2020, 1, 1, 0, 0, i));
      }

      final cellar = await open();
      await cellar.settle();

      expect(await keysOf(backing), {'k3', 'k4', 'k5', 'k6'});
      await cellar.close();
    });

    test('least recently used order is read from the ledger, so a use is felt '
        'at once', () async {
      final stack = LedgerBackend(backing);
      final cellar = await open(
        stack: stack,
        policy: EvictionPolicy.leastRecentlyUsed,
      );
      await put(cellar, ['k1', 'k2', 'k3', 'k4']);
      await cellar.settle();

      // k1 is the oldest written, but it has just been used.
      stack.ledger.touch('k1', DateTime.now().add(const Duration(days: 1)));
      await cellar.write('k5', Uint8List(10));
      await cellar.settle();

      expect(await keysOf(backing), {'k1', 'k3', 'k4', 'k5'});
      await cellar.close();
    });

    test('a ledger the application placed in the stack sees what is written '
        'beneath the facade; one the cellar adds does not', () async {
      final placed = LedgerBackend(backing);
      final withPlaced = await open(stack: placed);
      for (final key in ['k1', 'k2', 'k3', 'k4', 'k5']) {
        await placed.write(key, Uint8List(10)); // not through the facade
      }
      await withPlaced.settle();
      expect(await keysOf(backing), {'k2', 'k3', 'k4', 'k5'});
      await withPlaced.close();

      final other = InMemoryBackend();
      final added = await open(stack: other);
      await added.settle();
      for (final key in ['k1', 'k2', 'k3', 'k4', 'k5']) {
        await other.write(key, Uint8List(10)); // behind the cellar's back
      }
      await added.settle();
      expect(
        await keysOf(other),
        hasLength(5),
        reason: 'not seen, not evicted',
      );

      await added.runLifecycleNow(); // the listing corrects the ledger
      expect(await keysOf(other), hasLength(4));
      await added.close();
    });

    test('close waits for a pass that is running', () async {
      final release = Completer<void>();
      var evicted = false;
      final cellar = await open(
        guard: (info, action) async {
          await release.future;
          await action.evict();
          evicted = true;
        },
      );
      await put(cellar, ['k1', 'k2', 'k3', 'k4', 'k5']);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      final closing = cellar.close();
      release.complete();
      await closing;

      expect(
        evicted,
        isTrue,
        reason: 'the pass finished before close returned',
      );
    });

    group('with a budget', () {
      late InMemoryBackend a;
      late InMemoryBackend b;
      late _Counting aCounting;
      late _Counting bCounting;

      setUp(() {
        a = InMemoryBackend();
        b = InMemoryBackend();
        aCounting = _Counting(a);
        bCounting = _Counting(b);
      });

      Future<Cellar> openBudget({bool enforce = true}) async {
        final cellar = Cellar.withBackends(
          {'a': aCounting, 'b': bCounting},
          defaultPartition: 'a',
          budgets: {
            'cache': ByteBudget(
              maxBytes: 40,
              partitions: const {'a', 'b'},
              enforceOnWrite: enforce,
            ),
          },
        );
        await cellar.open();
        return cellar;
      }

      test('a write that takes the members over the cap evicts across them, '
          'oldest first', () async {
        final cellar = await openBudget();

        for (final key in ['a1', 'a2', 'a3']) {
          await cellar.write(key, Uint8List(10), partition: 'a');
        }
        for (final key in ['b1', 'b2']) {
          await cellar.write(key, Uint8List(10), partition: 'b');
        }
        await cellar.settle();

        expect(await keysOf(a), {'a2', 'a3'});
        expect(await keysOf(b), {'b1', 'b2'});
        await cellar.close();
      });

      test('without the switch the budget waits for the timer', () async {
        final cellar = await openBudget(enforce: false);

        for (final key in ['a1', 'a2', 'a3']) {
          await cellar.write(key, Uint8List(10), partition: 'a');
        }
        await cellar.write('b1', Uint8List(10), partition: 'b');
        await cellar.write('b2', Uint8List(10), partition: 'b');
        await cellar.settle();

        expect(await keysOf(a), hasLength(3));
        expect(await keysOf(b), hasLength(2));
        await cellar.close();
      });

      test(
        'makeRoom frees what was asked from the ledgers, with no listing',
        () async {
          final cellar = await openBudget();
          await cellar.settle();
          for (final key in ['a1', 'a2']) {
            await cellar.write(key, Uint8List(10), partition: 'a');
          }
          await cellar.write('b1', Uint8List(10), partition: 'b');
          await cellar.settle();
          final listed = aCounting.lists + bCounting.lists;

          final freed = await cellar.makeRoom(15);

          expect(freed, 20, reason: 'whole objects: two of ten bytes');
          expect(aCounting.lists + bCounting.lists, listed);
          expect(await keysOf(a), isEmpty, reason: 'the two oldest, a1 and a2');
          expect(await keysOf(b), {'b1'}, reason: 'the newest stays');
          await cellar.close();
        },
      );
    });
  });
}

/// A backend whose listing reads the backend, tells `started`, and then waits for
/// `gate` before it returns: a window in which a write can happen after the listing
/// read the backend and before it finishes.
class _SlowList extends ForwardingBackend {
  _SlowList(super.inner, this._gate);

  final Future<void> _gate;
  final Completer<void> _started = Completer<void>();

  Future<void> get started => _started.future;

  @override
  Future<List<ObjectInfo>> list(String prefix) async {
    final listed = await super.list(prefix);
    _started.complete();
    await _gate;
    return listed;
  }
}
