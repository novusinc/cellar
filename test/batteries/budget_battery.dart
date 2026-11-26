/// `ByteBudget` and `Cellar.makeRoom` — pure, runs on every platform.
library;

import 'dart:typed_data';

import 'package:cellar/cellar.dart';
import 'package:cellar/cellar_lowlevel.dart';
import 'package:test/test.dart';

void runBudgetBattery() {
  group('ByteBudget', () {
    late InMemoryBackend files;
    late InMemoryBackend avatars;
    late InMemoryBackend other;

    setUp(() {
      files = InMemoryBackend();
      avatars = InMemoryBackend();
      other = InMemoryBackend();
    });

    /// A cellar over three partitions; `files` and `avatars` share [budget].
    Future<Cellar> open({
      ByteBudget? budget,
      Map<String, Lifecycle> lifecycles = const {},
      void Function(String, String?, Object)? onError,
    }) async {
      final cellar = Cellar.withBackends(
        {'files': files, 'avatars': avatars, 'other': other},
        defaultPartition: 'files',
        lifecycles: lifecycles,
        budgets: {
          'cache':
              budget ??
              const ByteBudget(maxBytes: 40, partitions: {'files', 'avatars'}),
        },
        onEvictionError: onError,
      );
      await cellar.open();
      return cellar;
    }

    /// Writes 10-byte objects into [partition] with the given write order.
    Future<void> seed(
      Cellar cellar,
      InMemoryBackend backing,
      String partition,
      Map<String, int> secondsByKey, {
      Map<String, Map<String, String>> metadata = const {},
    }) async {
      for (final entry in secondsByKey.entries) {
        await cellar.write(
          entry.key,
          Uint8List(10),
          partition: partition,
          metadata: metadata[entry.key] ?? const {},
        );
        backing.setLastModified(
          entry.key,
          DateTime.utc(2020, 1, 1, 0, 0, entry.value),
        );
      }
    }

    Future<Set<String>> keys(Cellar cellar, String partition) async => {
      for (final info in await cellar.list('', partition: partition)) info.key,
    };

    group('enforcement', () {
      test('evicts across partitions, oldest written first, until the total '
          'is under the cap', () async {
        final cellar = await open();
        // 6 objects, 60 bytes, cap 40: the two oldest overall go.
        await seed(cellar, files, 'files', {'f1': 1, 'f2': 4, 'f3': 6});
        await seed(cellar, avatars, 'avatars', {'a1': 2, 'a2': 3, 'a3': 5});

        await cellar.runLifecycleNow();

        expect(await keys(cellar, 'files'), {'f2', 'f3'});
        expect(await keys(cellar, 'avatars'), {'a2', 'a3'});
        await cellar.close();
      });

      test('does nothing while the members are under the cap', () async {
        final cellar = await open();
        await seed(cellar, files, 'files', {'f1': 1, 'f2': 2});
        await seed(cellar, avatars, 'avatars', {'a1': 3, 'a2': 4});

        await cellar.runLifecycleNow();

        expect(await keys(cellar, 'files'), {'f1', 'f2'});
        expect(await keys(cellar, 'avatars'), {'a1', 'a2'});
        await cellar.close();
      });

      test('a partition outside the budget is never touched', () async {
        final cellar = await open();
        await seed(cellar, files, 'files', {'f1': 1, 'f2': 2, 'f3': 3});
        await seed(cellar, avatars, 'avatars', {'a1': 4, 'a2': 5});
        await seed(cellar, other, 'other', {'o1': 0, 'o2': 0, 'o3': 0});

        await cellar.runLifecycleNow();

        expect(await keys(cellar, 'other'), {'o1', 'o2', 'o3'});
        await cellar.close();
      });

      test('uses the budget\'s policy across partitions', () async {
        final cellar = await open(
          budget: const ByteBudget(
            maxBytes: 20,
            partitions: {'files', 'avatars'},
            evictionPolicy: EvictionPolicy.leastRecentlyUsed,
          ),
        );
        await seed(
          cellar,
          files,
          'files',
          {'f1': 1, 'f2': 2},
          metadata: {
            'f1': {accessedAtMetadataKey: _at(30)},
          },
        );
        await seed(
          cellar,
          avatars,
          'avatars',
          {'a1': 3, 'a2': 4},
          metadata: {
            'a2': {accessedAtMetadataKey: _at(20)},
          },
        );

        await cellar.runLifecycleNow();

        // Last used: f2 (written 2), a1 (written 3), a2 (read 20), f1 (read 30).
        expect(await keys(cellar, 'files'), {'f1'});
        expect(await keys(cellar, 'avatars'), {'a2'});
        await cellar.close();
      });

      test('a partition\'s own cap runs first', () async {
        final cellar = await open(
          lifecycles: {'files': const Lifecycle(maxBytes: 20)},
        );
        await seed(cellar, files, 'files', {'f1': 1, 'f2': 2, 'f3': 3});
        await seed(cellar, avatars, 'avatars', {'a1': 4, 'a2': 5});

        await cellar.runLifecycleNow();

        // files trims itself to 20 (f1 goes); 40 in total is then at the cap.
        expect(await keys(cellar, 'files'), {'f2', 'f3'});
        expect(await keys(cellar, 'avatars'), {'a1', 'a2'});
        await cellar.close();
      });

      test('a member\'s canEvict keeps its objects, and a member with no '
          'lifecycle is evicted in their place', () async {
        final told = <(String, String, EvictionReason)>[];
        final guarded = <String>[];
        final cellar = await open(
          budget: const ByteBudget(
            maxBytes: 20,
            partitions: {'files', 'avatars'},
          ),
          lifecycles: {
            'files': Lifecycle(
              canEvict: (info) => info.key != 'pinned',
              evictionGuard: (listed, action) async {
                guarded.add(listed.key);
                await action.evict();
              },
              onEvicted: (partition, info, reason) =>
                  told.add((partition, info.key, reason)),
            ),
          },
        );
        await seed(cellar, files, 'files', {'pinned': 1, 'f2': 3});
        await seed(cellar, avatars, 'avatars', {'a1': 2});

        await cellar.runLifecycleNow();

        // pinned is the oldest but kept; a1 (in a member with no lifecycle) goes,
        // which brings the total from 30 to the cap of 20, so f2 stays.
        expect(await keys(cellar, 'files'), {'pinned', 'f2'});
        expect(await keys(cellar, 'avatars'), isEmpty);
        expect(told, isEmpty);
        expect(guarded, isEmpty, reason: 'nothing of files was evicted');
        await cellar.close();
      });

      test('onEvicted of a member is told budget, and its guard wraps the '
          'delete', () async {
        final told = <(String, String, EvictionReason)>[];
        final guarded = <String>[];
        final cellar = await open(
          budget: const ByteBudget(
            maxBytes: 10,
            partitions: {'files', 'avatars'},
          ),
          lifecycles: {
            'files': Lifecycle(
              evictionGuard: (listed, action) async {
                guarded.add(listed.key);
                await action.evict();
              },
              onEvicted: (partition, info, reason) =>
                  told.add((partition, info.key, reason)),
            ),
          },
        );
        await seed(cellar, files, 'files', {'f1': 1});
        await seed(cellar, avatars, 'avatars', {'a1': 2});

        await cellar.runLifecycleNow();

        expect(await keys(cellar, 'files'), isEmpty);
        expect(guarded, ['f1']);
        expect(told, [('files', 'f1', EvictionReason.budget)]);
        await cellar.close();
      });

      test('a victim that is kept leaves the budget over, and the next one '
          'goes', () async {
        final cellar = await open(
          budget: const ByteBudget(
            maxBytes: 20,
            partitions: {'files', 'avatars'},
          ),
          lifecycles: {'files': Lifecycle(canEvict: (_) => false)},
        );
        await seed(cellar, files, 'files', {'f1': 1, 'f2': 2});
        await seed(cellar, avatars, 'avatars', {'a1': 3, 'a2': 4});

        await cellar.runLifecycleNow();

        expect(await keys(cellar, 'files'), {'f1', 'f2'});
        expect(await keys(cellar, 'avatars'), isEmpty);
        await cellar.close();
      });

      test(
        'a delete that fails is reported under the partition and skipped',
        () async {
          final errors = <(String, String?)>[];
          final stuck = _StickyBackend(InMemoryBackend(), stuckKey: 'a1');
          final cellar = Cellar.withBackends(
            {'files': files, 'avatars': stuck},
            defaultPartition: 'files',
            budgets: {
              'cache': const ByteBudget(
                maxBytes: 10,
                partitions: {'files', 'avatars'},
              ),
            },
            onEvictionError: (partition, key, _) =>
                errors.add((partition, key)),
          );
          await cellar.open();
          await cellar.write('f1', Uint8List(10));
          await cellar.write('a1', Uint8List(10), partition: 'avatars');
          stuck.setLastModifiedOf('a1', DateTime.utc(2019));
          files.setLastModified('f1', DateTime.utc(2020));

          await cellar.runLifecycleNow();

          expect(errors, [('avatars', 'a1')]);
          expect(await cellar.exists('f1'), isFalse);
          expect(await cellar.exists('a1', partition: 'avatars'), isTrue);
          await cellar.close();
        },
      );
    });

    group('makeRoom', () {
      test(
        'frees at least the bytes asked for, in policy order, and stops',
        () async {
          final cellar = await open();
          await seed(cellar, files, 'files', {'f1': 1, 'f2': 4});
          await seed(cellar, avatars, 'avatars', {'a1': 2, 'a2': 3});

          final freed = await cellar.makeRoom(15);

          // 10 is not enough; 20 is (two objects), and it stops there.
          expect(freed, 20);
          expect(await keys(cellar, 'files'), {'f2'});
          expect(await keys(cellar, 'avatars'), {'a2'});
          await cellar.close();
        },
      );

      test('frees space even when the budget is not full', () async {
        final cellar = await open(
          budget: const ByteBudget(maxBytes: 1000, partitions: {'files'}),
        );
        await seed(cellar, files, 'files', {'f1': 1, 'f2': 2});

        expect(await cellar.makeRoom(10), 10);
        expect(await keys(cellar, 'files'), {'f2'});
        await cellar.close();
      });

      test(
        'frees less when the rest is kept, and reports what it freed',
        () async {
          final cellar = await open(
            lifecycles: {
              'files': Lifecycle(canEvict: (info) => info.key != 'pinned'),
            },
          );
          await seed(cellar, files, 'files', {'pinned': 1, 'f2': 2});
          await seed(cellar, avatars, 'avatars', {'a1': 3});

          final freed = await cellar.makeRoom(100);

          expect(freed, 20);
          expect(await keys(cellar, 'files'), {'pinned'});
          await cellar.close();
        },
      );

      test('tells onEvicted makeRoom', () async {
        final told = <EvictionReason>[];
        final cellar = await open(
          lifecycles: {
            'files': Lifecycle(onEvicted: (_, _, reason) => told.add(reason)),
          },
        );
        await seed(cellar, files, 'files', {'f1': 1});

        await cellar.makeRoom(5);

        expect(told, [EvictionReason.makeRoom]);
        await cellar.close();
      });

      test('nothing to free, or nothing asked, is 0', () async {
        final cellar = await open();
        expect(await cellar.makeRoom(10), 0);
        await seed(cellar, files, 'files', {'f1': 1});
        expect(await cellar.makeRoom(0), 0);
        expect(await keys(cellar, 'files'), {'f1'});
        await cellar.close();
      });

      test('names the budget when there are several, and rejects an unknown '
          'one', () async {
        final cellar = Cellar.withBackends(
          {'files': files, 'avatars': avatars},
          defaultPartition: 'files',
          budgets: {
            'one': const ByteBudget(maxBytes: 100, partitions: {'files'}),
            'two': const ByteBudget(maxBytes: 100, partitions: {'avatars'}),
          },
        );
        await cellar.open();
        await cellar.write('f1', Uint8List(10));
        await cellar.write('a1', Uint8List(10), partition: 'avatars');

        await expectLater(cellar.makeRoom(5), throwsArgumentError);
        await expectLater(
          cellar.makeRoom(5, budget: 'nope'),
          throwsArgumentError,
        );
        expect(await cellar.makeRoom(5, budget: 'two'), 10);
        expect(await cellar.exists('f1'), isTrue);
        expect(await cellar.exists('a1', partition: 'avatars'), isFalse);
        await cellar.close();
      });

      test('a cellar with no budget has nothing to make room in', () async {
        final cellar = Cellar.withBackends({
          'files': files,
        }, defaultPartition: 'files');
        await cellar.open();

        await expectLater(cellar.makeRoom(5), throwsStateError);
        await cellar.close();
      });
    });

    group('configuration', () {
      Cellar build(Map<String, ByteBudget> budgets) => Cellar.withBackends(
        {'files': files, 'avatars': avatars},
        defaultPartition: 'files',
        budgets: budgets,
      );

      test('an unknown partition is refused at construction', () {
        expect(
          () => build({
            'b': const ByteBudget(maxBytes: 10, partitions: {'files', 'nope'}),
          }),
          throwsArgumentError,
        );
      });

      test('a partition in two budgets is refused', () {
        expect(
          () => build({
            'a': const ByteBudget(maxBytes: 10, partitions: {'files'}),
            'b': const ByteBudget(
              maxBytes: 10,
              partitions: {'files', 'avatars'},
            ),
          }),
          throwsArgumentError,
        );
      });

      test('a cap that is not positive, or no members, is refused', () {
        expect(
          () => build({
            'b': const ByteBudget(maxBytes: 0, partitions: {'files'}),
          }),
          throwsArgumentError,
        );
        expect(
          () => build({'b': const ByteBudget(maxBytes: 10, partitions: {})}),
          throwsArgumentError,
        );
      });
    });
  });
}

String _at(int second) =>
    DateTime.utc(2021, 1, 1, 0, 0, second).microsecondsSinceEpoch.toString();

/// Refuses to delete one key — a held or locked object.
class _StickyBackend extends ForwardingBackend {
  _StickyBackend(InMemoryBackend super.inner, {required this.stuckKey});

  final String stuckKey;

  void setLastModifiedOf(String key, DateTime when) =>
      (inner as InMemoryBackend).setLastModified(key, when);

  @override
  Future<void> delete(String key) {
    if (key == stuckKey) throw StateError('object is held');
    return super.delete(key);
  }
}
