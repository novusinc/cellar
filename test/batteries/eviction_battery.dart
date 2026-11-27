/// Eviction policy, `canEvict`, `evictionGuard` and `onEvicted` — pure, runs on
/// every platform.
library;

import 'dart:typed_data';

import 'package:cellar/cellar.dart';
import 'package:cellar/cellar_lowlevel.dart';
import 'package:test/test.dart';

void runEvictionBattery() {
  group('Eviction', () {
    Uint8List sized(int n) => Uint8List(n);

    /// An open cellar with one partition of [lifecycle] over [backing].
    Future<Cellar> open(
      InMemoryBackend backing,
      Lifecycle lifecycle, {
      String? keyPrefix,
      void Function(String, String?, Object)? onError,
    }) async {
      final cellar = Cellar.withBackends(
        {'cache': backing},
        defaultPartition: 'cache',
        keyPrefix: keyPrefix,
        lifecycles: {'cache': lifecycle},
        onEvictionError: onError,
      );
      await cellar.open();
      return cellar;
    }

    /// Writes [keys] (10 bytes each) written in the order given, one second
    /// apart from 2020, so "oldest written" is the first.
    Future<void> seed(
      Cellar cellar,
      InMemoryBackend backing,
      List<String> keys, {
      Map<String, Map<String, String>> metadata = const {},
    }) async {
      for (var i = 0; i < keys.length; i++) {
        final tags = metadata[keys[i]];
        if (tags == null) {
          await cellar.write(keys[i], sized(10));
        } else {
          // cellar.* keys are cellar's: the facade ignores a caller's, so they are
          // written the way a decorator writes them, beneath it.
          await backing.write(keys[i], sized(10), WriteOptions(metadata: tags));
        }
        backing.setLastModified(keys[i], DateTime.utc(2020, 1, 1, 0, 0, i));
      }
    }

    Future<Set<String>> survivors(Cellar cellar) async => {
      for (final info in await cellar.list('')) info.key,
    };

    String at(int second) => DateTime.utc(
      2021,
      1,
      1,
      0,
      0,
      second,
    ).microsecondsSinceEpoch.toString();

    group('policy', () {
      test(
        'oldest written is the default and evicts the oldest first',
        () async {
          final backing = InMemoryBackend();
          final cellar = await open(backing, const Lifecycle(maxBytes: 20));
          await seed(cellar, backing, ['a', 'b', 'c', 'd']);

          await cellar.runLifecycleNow();

          expect(await survivors(cellar), {'c', 'd'});
          await cellar.close();
        },
      );

      test('least recently used evicts what was read longest ago, even if it '
          'was written last', () async {
        final backing = InMemoryBackend();
        final cellar = await open(
          backing,
          const Lifecycle(
            maxBytes: 20,
            evictionPolicy: EvictionPolicy.leastRecentlyUsed,
          ),
        );
        // Written a, b, c, d; read d first, then a, then c; b never read.
        await seed(
          cellar,
          backing,
          ['a', 'b', 'c', 'd'],
          metadata: {
            'a': {accessedAtMetadataKey: at(2)},
            'c': {accessedAtMetadataKey: at(3)},
            'd': {accessedAtMetadataKey: at(1)},
          },
        );

        await cellar.runLifecycleNow();

        // b (never read, written in 2020) and d (read longest ago) go.
        expect(await survivors(cellar), {'a', 'c'});
        await cellar.close();
      });

      test('least recently used counts an object from its write when it was '
          'never read, and ignores a read older than the write', () async {
        final backing = InMemoryBackend();
        final cellar = await open(
          backing,
          const Lifecycle(
            maxBytes: 10,
            evictionPolicy: EvictionPolicy.leastRecentlyUsed,
          ),
        );
        await seed(
          cellar,
          backing,
          ['old', 'new'],
          metadata: {
            // A read stamp from before the object was last written (it was
            // rewritten since): the write is the later use.
            'new': {
              accessedAtMetadataKey: DateTime.utc(
                2000,
              ).microsecondsSinceEpoch.toString(),
            },
          },
        );

        await cellar.runLifecycleNow();

        expect(await survivors(cellar), {'new'});
        await cellar.close();
      });

      test('least frequently used evicts the fewest reads first, then the '
          'least recently used', () async {
        final backing = InMemoryBackend();
        final cellar = await open(
          backing,
          const Lifecycle(
            maxBytes: 20,
            evictionPolicy: EvictionPolicy.leastFrequentlyUsed,
          ),
        );
        await seed(
          cellar,
          backing,
          ['a', 'b', 'c', 'd'],
          metadata: {
            'a': {accessCountMetadataKey: '9'},
            'b': {accessCountMetadataKey: '1', accessedAtMetadataKey: at(5)},
            'c': {accessCountMetadataKey: '1', accessedAtMetadataKey: at(2)},
            // d: no count, so 0.
          },
        );

        await cellar.runLifecycleNow();

        // d (0 reads), then c (1 read, used before b).
        expect(await survivors(cellar), {'a', 'b'});
        await cellar.close();
      });

      test('an unparseable count or stamp is treated as absent', () async {
        final backing = InMemoryBackend();
        final cellar = await open(
          backing,
          const Lifecycle(
            maxBytes: 10,
            evictionPolicy: EvictionPolicy.leastFrequentlyUsed,
          ),
        );
        await seed(
          cellar,
          backing,
          ['a', 'b'],
          metadata: {
            'a': {
              accessCountMetadataKey: 'lots',
              accessedAtMetadataKey: 'soon',
            },
            'b': {accessCountMetadataKey: '3'},
          },
        );

        await cellar.runLifecycleNow();

        expect(await survivors(cellar), {'b'});
        await cellar.close();
      });

      test('a tie is broken by key, so the order is deterministic', () async {
        final backing = InMemoryBackend();
        final cellar = await open(backing, const Lifecycle(maxBytes: 10));
        for (final key in ['c', 'a', 'b']) {
          await cellar.write(key, sized(10));
          backing.setLastModified(key, DateTime.utc(2020));
        }

        await cellar.runLifecycleNow();

        expect(await survivors(cellar), {'c'}, reason: 'a, then b, evicted');
        await cellar.close();
      });

      test('a policy of your own decides the order', () async {
        final backing = InMemoryBackend();
        final cellar = await open(
          backing,
          const Lifecycle(maxBytes: 20, evictionPolicy: _NewestFirst()),
        );
        await seed(cellar, backing, ['a', 'b', 'c', 'd']);

        await cellar.runLifecycleNow();

        expect(await survivors(cellar), {'a', 'b'});
        await cellar.close();
      });

      test('maxAge removes every expired object whatever the policy', () async {
        final backing = InMemoryBackend();
        final cellar = await open(
          backing,
          const Lifecycle(
            maxAge: Duration(days: 7),
            evictionPolicy: EvictionPolicy.leastRecentlyUsed,
          ),
        );
        await seed(cellar, backing, ['old1', 'old2']);
        await cellar.write('fresh', sized(10));

        await cellar.runLifecycleNow();

        expect(await survivors(cellar), {'fresh'});
        await cellar.close();
      });
    });

    group('canEvict', () {
      test('an object it refuses is kept, and the next victim is evicted '
          'in its place', () async {
        final backing = InMemoryBackend();
        final cellar = await open(
          backing,
          Lifecycle(maxBytes: 20, canEvict: (info) => info.key != 'a'),
        );
        await seed(cellar, backing, ['a', 'b', 'c', 'd']);

        await cellar.runLifecycleNow();

        // a is kept; b and c go (40 -> 20 bytes), d stays.
        expect(await survivors(cellar), {'a', 'd'});
        await cellar.close();
      });

      test(
        'refusing every candidate evicts nothing and reports no error',
        () async {
          final backing = InMemoryBackend();
          final errors = <Object>[];
          final cellar = await open(
            backing,
            Lifecycle(maxBytes: 10, canEvict: (_) => false),
            onError: (_, _, error) => errors.add(error),
          );
          await seed(cellar, backing, ['a', 'b', 'c']);

          await cellar.runLifecycleNow();

          expect(await survivors(cellar), {'a', 'b', 'c'});
          expect(errors, isEmpty);
          await cellar.close();
        },
      );

      test('keeps an expired object too', () async {
        final backing = InMemoryBackend();
        final cellar = await open(
          backing,
          Lifecycle(
            maxAge: const Duration(days: 7),
            canEvict: (info) => info.key != 'pinned',
          ),
        );
        await seed(cellar, backing, ['pinned', 'other']);

        await cellar.runLifecycleNow();

        expect(await survivors(cellar), {'pinned'});
        await cellar.close();
      });

      test('may be asynchronous', () async {
        final backing = InMemoryBackend();
        final cellar = await open(
          backing,
          Lifecycle(
            maxBytes: 10,
            canEvict: (info) async {
              await Future<void>.delayed(Duration.zero);
              return info.key != 'a';
            },
          ),
        );
        await seed(cellar, backing, ['a', 'b']);

        await cellar.runLifecycleNow();

        expect(await survivors(cellar), {'a'});
        await cellar.close();
      });

      test('a callback that throws skips the object and is reported', () async {
        final backing = InMemoryBackend();
        final errors = <(String, String?)>[];
        final cellar = await open(
          backing,
          Lifecycle(
            maxBytes: 10,
            canEvict: (info) =>
                info.key == 'a' ? throw StateError('boom') : true,
          ),
          onError: (partition, key, _) => errors.add((partition, key)),
        );
        await seed(cellar, backing, ['a', 'b']);

        await cellar.runLifecycleNow();

        expect(await survivors(cellar), {'a'});
        expect(errors, [('cache', 'a')]);
        await cellar.close();
      });
    });

    group('evictionGuard', () {
      test('without one, an object rewritten after the listing is deleted '
          'from stale information', () async {
        final backing = InMemoryBackend();
        late Cellar cellar;
        cellar = await open(
          backing,
          Lifecycle(
            maxBytes: 10,
            // Runs between the pass's listing and its delete.
            canEvict: (info) async {
              if (info.key == 'a') await cellar.write('a', sized(10));
              return true;
            },
          ),
        );
        await seed(cellar, backing, ['a', 'b']);

        await cellar.runLifecycleNow();

        expect(await cellar.exists('a'), isFalse, reason: 'the hazard');
        await cellar.close();
      });

      test('a guard that re-checks keeps an object rewritten after the '
          'listing', () async {
        final backing = InMemoryBackend();
        late Cellar cellar;
        cellar = await open(
          backing,
          Lifecycle(
            maxBytes: 10,
            canEvict: (info) async {
              if (info.key == 'a') {
                backing.setLastModified('a', DateTime.utc(2024));
              }
              return true;
            },
            evictionGuard: (listed, action) async {
              final now = await action.head();
              if (now == null || now.lastModified != listed.lastModified) {
                return;
              }
              await action.evict();
            },
          ),
        );
        await seed(cellar, backing, ['a', 'b']);

        await cellar.runLifecycleNow();

        // 'a' changed after it was listed, so it stays; the cap is met by 'b'.
        expect(await survivors(cellar), {'a'});
        await cellar.close();
      });

      test('a guard that does not evict skips the object, and the pass moves '
          'on to the next', () async {
        final backing = InMemoryBackend();
        final cellar = await open(
          backing,
          Lifecycle(
            maxBytes: 10,
            evictionGuard: (listed, action) async {
              if (listed.key != 'a') {
                await action.evict();
              }
            },
          ),
        );
        await seed(cellar, backing, ['a', 'b', 'c']);

        await cellar.runLifecycleNow();

        expect(await survivors(cellar), {'a'});
        await cellar.close();
      });

      test('a guard that throws skips the object and is reported', () async {
        final backing = InMemoryBackend();
        final errors = <(String, String?)>[];
        final cellar = await open(
          backing,
          Lifecycle(
            maxBytes: 10,
            evictionGuard: (listed, action) async {
              if (listed.key == 'a') throw StateError('lock timeout');
              await action.evict();
            },
          ),
          onError: (partition, key, _) => errors.add((partition, key)),
        );
        await seed(cellar, backing, ['a', 'b']);

        await cellar.runLifecycleNow();

        expect(await survivors(cellar), {'a'});
        expect(errors, [('cache', 'a')]);
        await cellar.close();
      });

      test('sees the partition-relative key, and reads the object under a '
          'keyPrefix', () async {
        final backing = InMemoryBackend();
        final seen = <String>[];
        final cellar = await open(
          backing,
          Lifecycle(
            maxBytes: 10,
            evictionGuard: (listed, action) async {
              seen.add(listed.key);
              expect((await action.head())!.key, listed.key);
              await action.evict();
            },
          ),
          keyPrefix: 'user/u1',
        );
        await seed(cellar, backing, ['a', 'b']);

        await cellar.runLifecycleNow();

        expect(seen, ['a']);
        expect(await survivors(cellar), {'b'});
        await cellar.close();
      });

      test('canEvict runs before the guard, which is not asked about a kept '
          'object', () async {
        final backing = InMemoryBackend();
        final guarded = <String>[];
        final cellar = await open(
          backing,
          Lifecycle(
            maxBytes: 10,
            canEvict: (info) => info.key != 'a',
            evictionGuard: (listed, action) async {
              guarded.add(listed.key);
              await action.evict();
            },
          ),
        );
        await seed(cellar, backing, ['a', 'b']);

        await cellar.runLifecycleNow();

        expect(guarded, ['b']);
        await cellar.close();
      });
    });

    group('onEvicted', () {
      test('is told what was evicted and why', () async {
        final backing = InMemoryBackend();
        final told = <(String, String, int, EvictionReason)>[];
        final cellar = await open(
          backing,
          Lifecycle(
            maxBytes: 10,
            maxAge: const Duration(days: 7),
            onEvicted: (partition, info, reason) =>
                told.add((partition, info.key, info.size, reason)),
          ),
        );
        await seed(cellar, backing, ['expired']);
        // Two fresh objects over the 10-byte cap: the older goes by size.
        await cellar.write('x', sized(10));
        await cellar.write('y', sized(10));
        backing.setLastModified(
          'x',
          DateTime.now().subtract(const Duration(minutes: 2)),
        );

        await cellar.runLifecycleNow();

        expect(told, [
          ('cache', 'expired', 10, EvictionReason.expired),
          ('cache', 'x', 10, EvictionReason.partitionCap),
        ]);
        await cellar.close();
      });

      test(
        'is not told about an object that was kept or failed to delete',
        () async {
          final backing = InMemoryBackend();
          final told = <String>[];
          final cellar = await open(
            backing,
            Lifecycle(
              maxBytes: 10,
              canEvict: (info) => info.key != 'a',
              onEvicted: (_, info, _) => told.add(info.key),
            ),
          );
          await seed(cellar, backing, ['a', 'b']);

          await cellar.runLifecycleNow();

          expect(told, ['b']);
          await cellar.close();
        },
      );

      test(
        'a callback that throws is reported and does not stop the pass',
        () async {
          final backing = InMemoryBackend();
          final errors = <(String, String?)>[];
          final cellar = await open(
            backing,
            Lifecycle(
              maxBytes: 10,
              onEvicted: (_, _, _) => throw StateError('observer bug'),
            ),
            onError: (partition, key, _) => errors.add((partition, key)),
          );
          await seed(cellar, backing, ['a', 'b', 'c']);

          await cellar.runLifecycleNow();

          expect(await survivors(cellar), {'c'});
          expect(errors, [('cache', 'a'), ('cache', 'b')]);
          await cellar.close();
        },
      );
    });

    group('run by hand', () {
      late InMemoryBackend a;
      late InMemoryBackend b;

      setUp(() {
        a = InMemoryBackend();
        b = InMemoryBackend();
      });

      /// Two partitions, each over a 20-byte cap with three 10-byte objects, written
      /// oldest first; [budget] adds a cap of 25 over both and removes their own.
      Future<Cellar> openTwo({bool budget = false}) async {
        final cap = Lifecycle.cache(maxBytes: 20);
        final cellar = Cellar.withBackends(
          {'a': a, 'b': b},
          defaultPartition: 'a',
          lifecycles: budget ? const {} : {'a': cap, 'b': cap},
          budgets: budget
              ? const {
                  'both': ByteBudget(maxBytes: 25, partitions: {'a', 'b'}),
                }
              : null,
        );
        await cellar.open();
        for (final entry in {'a': a, 'b': b}.entries) {
          for (var i = 0; i < 3; i++) {
            await cellar.write('k$i', sized(10), partition: entry.key);
            entry.value.setLastModified(
              'k$i',
              DateTime.utc(2020, 1, 1, 0, 0, i),
            );
          }
        }
        return cellar;
      }

      Future<int> count(Cellar cellar, String partition) async =>
          (await cellar.list('', partition: partition)).length;

      test(
        'with no partition it runs every partition, as it always did',
        () async {
          final cellar = await openTwo();

          await cellar.runLifecycleNow();

          expect(await count(cellar, 'a'), 2);
          expect(await count(cellar, 'b'), 2);
          await cellar.close();
        },
      );

      test('with a partition it runs that partition and leaves the others over '
          'their caps', () async {
        final cellar = await openTwo();

        await cellar.runLifecycleNow(partition: 'a');

        expect(await count(cellar, 'a'), 2, reason: 'brought under its cap');
        expect(await count(cellar, 'b'), 3, reason: 'not asked');
        await cellar.close();
      });

      test('with a partition it does not run a budget the partition belongs '
          'to', () async {
        final cellar = await openTwo(budget: true);

        await cellar.runLifecycleNow(partition: 'a');
        expect(
          await count(cellar, 'a') + await count(cellar, 'b'),
          6,
          reason: 'a budget is a rule about several partitions',
        );

        await cellar.runLifecycleNow();
        expect(await count(cellar, 'a') + await count(cellar, 'b'), 2);
        await cellar.close();
      });

      test('a name that is not a partition is refused, and a partition with no '
          'rules has nothing to run', () async {
        final cellar = Cellar.withBackends(
          {'a': a, 'b': b},
          defaultPartition: 'a',
          lifecycles: {'a': const Lifecycle.cache(maxBytes: 20)},
        );
        await cellar.open();

        await expectLater(
          cellar.runLifecycleNow(partition: 'nope'),
          throwsArgumentError,
        );
        await cellar.runLifecycleNow(partition: 'b'); // no rules: no error
        await cellar.close();
      });
    });

    group('shrinkTo', () {
      test('evicts in the partition\'s own policy until it fits, and says how '
          'much it freed', () async {
        final backing = InMemoryBackend();
        final cellar = await open(
          backing,
          const Lifecycle(evictionPolicy: EvictionPolicy.leastRecentlyUsed),
        );
        // Written a to e; read c, then a, then d; b and e never read.
        await seed(
          cellar,
          backing,
          ['a', 'b', 'c', 'd', 'e'],
          metadata: {
            'a': {accessedAtMetadataKey: at(2)},
            'c': {accessedAtMetadataKey: at(1)},
            'd': {accessedAtMetadataKey: at(3)},
          },
        );

        final freed = await cellar.shrinkTo(20);

        expect(freed, 30);
        // Least recently used first: b, e (never read, so by write), then c.
        expect(await survivors(cellar), {'a', 'd'});
        await cellar.close();
      });

      test('is a one-off: the configured cap is not changed', () async {
        final backing = InMemoryBackend();
        final cellar = await open(backing, const Lifecycle(maxBytes: 100));
        await seed(cellar, backing, ['a', 'b', 'c', 'd', 'e']);

        await cellar.shrinkTo(10);
        expect(await survivors(cellar), {'e'});

        await seed(cellar, backing, ['f', 'g', 'h']);
        await cellar.runLifecycleNow();
        expect(await survivors(cellar), {
          'e',
          'f',
          'g',
          'h',
        }, reason: 'cap 100');
        await cellar.close();
      });

      test('keeps what canEvict keeps, and frees less', () async {
        final backing = InMemoryBackend();
        final cellar = await open(
          backing,
          Lifecycle(canEvict: (info) => info.key != 'a'),
        );
        await seed(cellar, backing, ['a', 'b', 'c']);

        final freed = await cellar.shrinkTo(0);

        expect(freed, 20, reason: 'a is kept');
        expect(await survivors(cellar), {'a'});
        await cellar.close();
      });

      test(
        'goes through the eviction guard and tells onEvicted shrinkTo',
        () async {
          final backing = InMemoryBackend();
          final told = <EvictionReason>[];
          final cellar = await open(
            backing,
            Lifecycle(
              evictionGuard: (info, action) async {
                if (info.key != 'b') await action.evict();
              },
              onEvicted: (partition, info, reason) => told.add(reason),
            ),
          );
          await seed(cellar, backing, ['a', 'b', 'c']);

          await cellar.shrinkTo(0);

          expect(await survivors(cellar), {
            'b',
          }, reason: 'the guard declined b');
          expect(told, [EvictionReason.shrinkTo, EvictionReason.shrinkTo]);
          await cellar.close();
        },
      );

      test(
        'a target at or over the size frees nothing, and zero frees all that '
        'may go',
        () async {
          final backing = InMemoryBackend();
          final cellar = await open(backing, const Lifecycle());
          await seed(cellar, backing, ['a', 'b', 'c']);

          expect(await cellar.shrinkTo(30), 0);
          expect(await cellar.shrinkTo(99), 0);
          expect(await survivors(cellar), {'a', 'b', 'c'});

          expect(await cellar.shrinkTo(0), 30);
          expect(await survivors(cellar), isEmpty);
          await cellar.close();
        },
      );

      test('reduces the named partition and no other, and the default one when '
          'none is named', () async {
        final a = InMemoryBackend();
        final b = InMemoryBackend();
        final cellar = Cellar.withBackends(
          {'a': a, 'b': b},
          defaultPartition: 'a',
          lifecycles: {'a': const Lifecycle(), 'b': const Lifecycle()},
        );
        await cellar.open();
        for (final partition in ['a', 'b']) {
          for (final key in ['x', 'y', 'z']) {
            await cellar.write(key, sized(10), partition: partition);
          }
        }

        await cellar.shrinkTo(10, partition: 'b');
        expect((await cellar.list('', partition: 'b')).length, 1);
        expect((await cellar.list('', partition: 'a')).length, 3);

        await cellar.shrinkTo(20); // no partition: the default, a
        expect((await cellar.list('', partition: 'a')).length, 2);
        expect((await cellar.list('', partition: 'b')).length, 1);
        await cellar.close();
      });

      test(
        'a partition with a policy and no cap can be shrunk by hand',
        () async {
          final backing = InMemoryBackend();
          final cellar = await open(
            backing,
            const Lifecycle(evictionPolicy: EvictionPolicy.leastRecentlyUsed),
          );
          await seed(cellar, backing, ['a', 'b', 'c']);
          await cellar.runLifecycleNow(); // no rules to run: nothing goes
          expect(await survivors(cellar), {'a', 'b', 'c'});

          await cellar.shrinkTo(10);

          expect(await survivors(cellar), {'c'});
          await cellar.close();
        },
      );

      test('a partition with no lifecycle is permanent: refused, and nothing '
          'is lost', () async {
        final a = InMemoryBackend();
        final b = InMemoryBackend();
        final cellar = Cellar.withBackends(
          {'a': a, 'b': b},
          defaultPartition: 'a',
          lifecycles: {'a': const Lifecycle(maxBytes: 100)},
        );
        await cellar.open();
        await cellar.write('keep', sized(10), partition: 'b');

        await expectLater(cellar.shrinkTo(0, partition: 'b'), throwsStateError);

        expect(await cellar.exists('keep', partition: 'b'), isTrue);
        await cellar.close();
      });

      test('a negative target and an unknown partition are refused', () async {
        final backing = InMemoryBackend();
        final cellar = await open(backing, const Lifecycle());

        await expectLater(cellar.shrinkTo(-1), throwsArgumentError);
        await expectLater(
          cellar.shrinkTo(0, partition: 'nope'),
          throwsArgumentError,
        );
        await cellar.close();
      });
    });

    test('the defaults are what cellar always did', () {
      const lifecycle = Lifecycle.cache(maxBytes: 1);
      expect(lifecycle.evictionPolicy, same(EvictionPolicy.oldestWritten));
      expect(lifecycle.canEvict, isNull);
      expect(lifecycle.evictionGuard, isNull);
      expect(lifecycle.onEvicted, isNull);
      expect(
        const Lifecycle.scratch().evictionPolicy,
        same(EvictionPolicy.oldestWritten),
      );
    });
  });
}

/// A policy of the application's own: the newest written goes first.
class _NewestFirst extends EvictionPolicy {
  const _NewestFirst();

  @override
  int compare(ObjectInfo a, ObjectInfo b) =>
      b.lastModified.compareTo(a.lastModified);
}
