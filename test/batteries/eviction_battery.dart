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
