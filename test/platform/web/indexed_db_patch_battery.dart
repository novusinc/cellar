/// patchMetadata is atomic across tabs: a patch racing a write to the same key
/// never leaves the object at a stale chunk pointer. Browser-only. Invoked ONLY
/// by the web runner.
library;

import 'dart:typed_data';

import 'package:cellar/cellar_lowlevel.dart';
import 'package:test/test.dart';

void runIndexedDbPatchBattery() {
  group('IndexedDbBackend patchMetadata across tabs', () {
    Uint8List sized(int n, int seed) =>
        Uint8List.fromList(List.generate(n, (i) => (i + seed) & 255));

    test('a patch racing a write leaves the object readable at the writer\'s '
        'generation, never a stale pointer', () async {
      // Two connections to one database stand in for two tabs.
      const name = 'cellar_patch_race';
      final writer = IndexedDbBackend(dbName: name);
      final patcher = IndexedDbBackend(dbName: name);
      addTearDown(writer.dispose);
      addTearDown(patcher.dispose);
      await writer.write(
        'k',
        sized(100, 0),
        const WriteOptions(metadata: {'n': '0'}),
      );

      for (var round = 1; round <= 25; round++) {
        final bytes = sized(150 * 1024 + round, round); // three chunk records
        await Future.wait([
          writer.write('k', bytes, WriteOptions(metadata: {'n': '$round'})),
          patcher.patchMetadata('k', {'touched': '$round'}),
          patcher.patchMetadata('k', {'touched2': '$round'}),
        ]);

        // Whatever the interleaving, the object is the writer's, whole.
        expect(await patcher.read('k'), bytes, reason: 'round $round');
        expect((await patcher.head('k'))!.size, bytes.length);
      }
    });

    test('a patch is visible to another connection', () async {
      const name = 'cellar_patch_visible';
      final a = IndexedDbBackend(dbName: name);
      final b = IndexedDbBackend(dbName: name);
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      await a.write('k', sized(200 * 1024, 3));

      await a.patchMetadata('k', {'seen': 'yes'});

      expect((await b.head('k'))!.metadata['seen'], 'yes');
      expect(await b.read('k'), sized(200 * 1024, 3));
    });
  });
}
