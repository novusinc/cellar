/// LedgerBackend over the REAL filesystem: the contract holds with it in the stack,
/// and a file imported or moved by rename is in the ledger as it lands.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:cellar/cellar_lowlevel.dart';
import 'package:test/test.dart';

import '../../batteries/conformance_battery.dart';
import '../../harness/temp_dir.dart';

void main() {
  late Directory tempRoot;
  var counter = 0;
  setUpAll(() async => tempRoot = await makeTempDir('ledger_fs_'));
  tearDownAll(() async {
    try {
      await tempRoot.delete(recursive: true);
    } on FileSystemException {
      // Best-effort cleanup.
    }
  });

  runStorageBackendConformance(
    'LedgerBackend over FileSystemBackend',
    create: () => LedgerBackend(
      FileSystemBackend('${tempRoot.path}/conformance_${counter++}'),
    ),
    supportsMaterialize: true,
  );

  group('LedgerBackend over FileSystemBackend', () {
    late Directory store;
    late Directory outside;
    late LedgerBackend backend;

    setUp(() async {
      store = Directory('${tempRoot.path}/s${counter++}')..createSync();
      outside = Directory('${tempRoot.path}/o${counter++}')..createSync();
      backend = LedgerBackend(FileSystemBackend(store.path));
    });

    test(
      'a file imported by move is in the ledger, and its source is gone',
      () async {
        final source = File('${outside.path}/video')
          ..writeAsBytesSync(Uint8List(1234));

        await backend.importFile('v/1', source.path, move: true);

        expect(backend.ledger['v/1']?.size, 1234);
        expect(backend.ledger.totalBytes, 1234);
        expect(source.existsSync(), isFalse);
      },
    );

    test(
      'a file imported by copy is in the ledger, and its source stays',
      () async {
        final source = File('${outside.path}/video')
          ..writeAsBytesSync(Uint8List(99));

        await backend.importFile(
          'v/1',
          source.path,
          options: const WriteOptions(metadata: {'kind': 'video'}),
        );

        expect(backend.ledger['v/1']?.size, 99);
        expect(backend.ledger['v/1']?.metadata['kind'], 'video');
        expect(source.existsSync(), isTrue);
      },
    );

    test('a move by rename takes the entry to the new key', () async {
      await backend.write('a', Uint8List(40));

      await backend.move('a', 'b');

      expect(backend.ledger['a'], isNull);
      expect(backend.ledger['b']?.size, 40);
      expect(backend.ledger.totalBytes, 40);
    });

    test('the ledger of a listing is what is on the disk', () async {
      await backend.write('x/1', Uint8List(5));
      await backend.write('x/2', Uint8List(6));
      final fresh = LedgerBackend(FileSystemBackend(store.path));

      await fresh.list('');

      expect(fresh.ledger.totalBytes, 11);
      expect(fresh.ledger.isLoaded(''), isTrue);
    });
  });
}
