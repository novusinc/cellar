import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:cellar/cellar_lowlevel.dart' hide FileSystemBackend;
// White-box test of the NATIVE impl (its OS seam carries the injected failures).
import 'package:cellar/src/backends/file_system/file_system_backend_native.dart';
import 'package:cellar/src/backends/file_system/os/file_system_os.dart';

import '../../harness/temp_dir.dart';

/// importFile: a file already on disk becomes an object without its bytes being
/// read through the application, and never at the cost of the source before the
/// object exists.
void main() {
  late Directory store;
  late Directory outside;
  late _Os os;
  late FileSystemBackend backend;

  Uint8List bytes(int n, int seed) =>
      Uint8List.fromList(List.generate(n, (i) => (i + seed) & 0xff));

  Future<File> sourceFile(String name, Uint8List data) async {
    final file = File('${outside.path}/$name');
    await file.writeAsBytes(data);
    return file;
  }

  setUp(() async {
    store = await makeTempDir('import_store_');
    outside = await makeTempDir('import_source_');
    os = _Os();
    backend = FileSystemBackend(store.path, os: os);
  });

  tearDown(() async {
    for (final dir in [store, outside]) {
      if (dir.existsSync()) await dir.delete(recursive: true);
    }
  });

  FileSystemBackend reopened() => FileSystemBackend(store.path);

  group('importFile copying', () {
    test(
      'stores the bytes, content type and metadata, and leaves the file',
      () async {
        final file = await sourceFile('pic.png', bytes(5000, 1));

        await backend.importFile(
          'media/pic',
          file.path,
          options: const WriteOptions(
            contentType: 'image/png',
            metadata: {'k': 'v'},
          ),
        );

        expect(await backend.read('media/pic'), bytes(5000, 1));
        final info = (await backend.head('media/pic'))!;
        expect(info.contentType, 'image/png');
        expect(info.metadata, {'k': 'v'});
        expect(file.existsSync(), isTrue, reason: 'a copy leaves the source');
        expect(await file.readAsBytes(), bytes(5000, 1));
      },
    );

    test('replaces an existing object, metadata and all', () async {
      await backend.write(
        'k',
        bytes(10, 9),
        const WriteOptions(contentType: 'old/x', metadata: {'old': '1'}),
      );
      final file = await sourceFile('new.bin', bytes(300, 2));

      await backend.importFile('k', file.path);

      expect(await backend.read('k'), bytes(300, 2));
      final info = (await backend.head('k'))!;
      expect(info.contentType, isNull);
      expect(info.metadata, isEmpty);
    });

    test('a crash before the new body is promoted keeps the previous object '
        'and the source', () async {
      await backend.write('k', bytes(10, 9));
      final file = await sourceFile('new.bin', bytes(300, 2));

      os.crashOnRename = 1;
      await expectLater(
        backend.importFile('k', file.path),
        throwsA(isA<_Crash>()),
      );

      expect(await reopened().read('k'), bytes(10, 9));
      expect(file.existsSync(), isTrue);
    });

    test(
      'a path that is not a file is a FileNotFoundError and stores nothing',
      () async {
        await expectLater(
          backend.importFile('k', '${outside.path}/missing'),
          throwsA(isA<FileNotFoundError>()),
        );
        await expectLater(
          backend.importFile('k', outside.path),
          throwsA(isA<FileNotFoundError>()),
        );

        expect(await backend.exists('k'), isFalse);
      },
    );

    test('the file that is already the stored object is refused', () async {
      await backend.write('k', bytes(10, 1));

      await expectLater(
        backend.importFile('k', '${store.path}/k'),
        throwsArgumentError,
      );
      expect(await backend.read('k'), bytes(10, 1));
    });
  });

  group('importFile moving', () {
    test('renames the file into place: no copy of its bytes', () async {
      final file = await sourceFile('video.mp4', bytes(40000, 3));

      await backend.importFile(
        'v',
        file.path,
        move: true,
        options: const WriteOptions(
          contentType: 'video/mp4',
          metadata: {'k': 'v'},
        ),
      );

      expect(
        os.promoted,
        contains(file.path),
        reason: 'the file itself was renamed',
      );
      expect(
        os.promoted.where((p) => p.contains(FileSystemBackend.writeTempSuffix)),
        hasLength(1),
        reason: 'only the sidecar goes through a temp',
      );
      expect(file.existsSync(), isFalse);
      expect(await backend.read('v'), bytes(40000, 3));
      final info = (await backend.head('v'))!;
      expect(info.contentType, 'video/mp4');
      expect(info.metadata, {'k': 'v'});
    });

    test('when the rename is refused (another volume) it copies, then deletes '
        'the source only after the object exists', () async {
      final file = await sourceFile('video.mp4', bytes(9000, 4));
      os.refuseRenameOf = file.path;

      await backend.importFile('v', file.path, move: true);

      expect(await backend.read('v'), bytes(9000, 4));
      expect(file.existsSync(), isFalse);
      expect(
        os.promoted.where((p) => p.contains(FileSystemBackend.writeTempSuffix)),
        isNotEmpty,
        reason: 'the bytes were copied through a temp and promoted',
      );
    });

    test('a copy that fails after a refused rename leaves the source and the '
        'previous object', () async {
      await backend.write('v', bytes(10, 9));
      final file = await sourceFile('video.mp4', bytes(9000, 4));
      os.refuseRenameOf = file.path;
      os.crashOnRename = 1;

      await expectLater(
        backend.importFile('v', file.path, move: true),
        throwsA(isA<_Crash>()),
      );

      expect(
        file.existsSync(),
        isTrue,
        reason: 'never lost before the object exists',
      );
      expect(await reopened().read('v'), bytes(10, 9));
    });

    test(
      'a crash between the body and its sidecar is completed at open',
      () async {
        final file = await sourceFile('video.mp4', bytes(900, 5));

        os.crashOnRename = 2; // the sidecar's, after the body moved
        await expectLater(
          backend.importFile(
            'v',
            file.path,
            move: true,
            options: const WriteOptions(
              contentType: 'video/mp4',
              metadata: {'k': 'v'},
            ),
          ),
          throwsA(isA<_Crash>()),
        );

        final next = reopened();
        expect((await next.head('v'))!.contentType, isNull, reason: 'not yet');
        await next.recoverInterruptedWrites();
        final info = (await next.head('v'))!;
        expect(info.contentType, 'video/mp4');
        expect(info.metadata, {'k': 'v'});
        expect(await next.read('v'), bytes(900, 5));
      },
    );

    test('keeps the file\'s modification time as lastModified', () async {
      final file = await sourceFile('a.bin', bytes(100, 1));
      final modified = DateTime.utc(2024, 5, 6, 7, 8, 9);
      await file.setLastModified(modified);

      await backend.importFile('k', file.path, move: true);

      expect((await backend.head('k'))!.lastModified, modified);
    });
  });
}

class _Crash implements Exception {}

/// An OS that records the renames that go ahead, can refuse the rename of one
/// path (as a cross-volume rename is refused), and can "crash" at one.
class _Os extends DefaultFileSystemOs {
  final List<String> promoted = [];
  String? refuseRenameOf;
  int? _left;
  bool _dead = false;

  set crashOnRename(int? n) => _left = n;

  @override
  Future<void> renameOver(File from, String toPath) async {
    if (from.path == refuseRenameOf) {
      throw FileSystemException('Cross-device link', from.path);
    }
    final left = _left;
    if (left != null) {
      _left = left - 1;
      if (left == 1) {
        _left = null;
        _dead = true;
        throw _Crash();
      }
    }
    promoted.add(from.path);
    await super.renameOver(from, toPath);
  }

  @override
  Future<void> deleteFile(File file) async {
    if (_dead) return;
    await super.deleteFile(file);
  }
}
