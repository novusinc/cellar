import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:cellar/cellar_lowlevel.dart' hide FileDataStore;
// White-box test of the NATIVE impl: imports the suffixed file directly (the switch's analyzer
// view resolves to the web stub, which cannot carry the io-typed `os:` parameter), and the OS
// seam, so a test can inject an OS that dies, or refuses a rename, at a chosen step.
import 'package:cellar/src/data/file_data_store_native.dart';
import 'package:cellar/src/backends/file_system/os/file_system_os.dart';

import '../../harness/temp_dir.dart';

/// The bytes-only native store: one file per object, written atomically, streamed, listed
/// by a walk and a `stat`, adopted by rename.
void main() {
  late Directory tempDir;
  late _FaultyOs os;
  late FileDataStore store;

  Uint8List bytes(int length, int seed) =>
      Uint8List.fromList(List.generate(length, (i) => (i + seed) & 0xff));

  setUp(() async {
    tempDir = await makeTempDir('data_store_');
    os = _FaultyOs();
    store = FileDataStore('${tempDir.path}/root', os: os);
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  /// Every file under the root, relative to it, temp files included.
  List<String> filesOnDisk() {
    final root = Directory('${tempDir.path}/root');
    if (!root.existsSync()) return [];
    return [
      for (final e in root.listSync(recursive: true))
        if (e is File) e.path.substring(root.path.length + 1),
    ]..sort();
  }

  group('an object is one file of bytes', () {
    test('write, read, stat and exists round trip', () async {
      await store.write('a/b', bytes(100, 1));

      expect(await store.read('a/b'), bytes(100, 1));
      expect(await store.exists('a/b'), isTrue);
      final entry = await store.stat('a/b');
      expect(entry!.key, 'a/b');
      expect(entry.size, 100);
      expect(entry.modified.isUtc, isTrue);
      expect(
        entry.modified.difference(DateTime.now().toUtc()).inMinutes.abs(),
        lessThan(2),
      );
    });

    test('there is no sidecar: the directory holds the one file', () async {
      await store.write('a/b', bytes(10, 1));

      expect(filesOnDisk(), ['a/b']);
    });

    test('a write replaces what was at the key', () async {
      await store.write('k', bytes(100, 1));
      await store.write('k', bytes(40, 2));

      expect(await store.read('k'), bytes(40, 2));
      expect((await store.stat('k'))!.size, 40);
    });

    test('a missing object reads as not found, and stats as null', () async {
      expect(await store.stat('nope'), isNull);
      expect(await store.exists('nope'), isFalse);
      await expectLater(store.read('nope'), throwsA(isA<FileNotFoundError>()));
      await expectLater(
        store.readStream('nope').toList(),
        throwsA(isA<FileNotFoundError>()),
      );
      await expectLater(
        store.readRange('nope', start: 0, length: 1),
        throwsA(isA<FileNotFoundError>()),
      );
      await expectLater(
        store.materialize('nope'),
        throwsA(isA<FileNotFoundError>()),
      );
    });

    test('a key that could leave the root is refused', () async {
      for (final key in ['../x', '/x', 'a/../b', 'a b', '']) {
        await expectLater(
          store.write(key, bytes(1, 1)),
          throwsA(isA<InvalidKeyError>()),
          reason: key,
        );
      }
      expect(filesOnDisk(), isEmpty);
    });

    test('using it after dispose fails', () async {
      await store.dispose();

      await expectLater(store.write('k', bytes(1, 1)), throwsStateError);
      await expectLater(store.read('k'), throwsStateError);
    });
  });

  group('streams and ranges', () {
    test('writeStream stores what it is given and reports progress', () async {
      final progress = <int>[];

      await store.writeStream(
        'k',
        Stream.fromIterable([bytes(30, 1), bytes(20, 2), bytes(10, 3)]),
        onProgress: progress.add,
      );

      expect(await store.read('k'), [
        ...bytes(30, 1),
        ...bytes(20, 2),
        ...bytes(10, 3),
      ]);
      expect(progress, [30, 50, 60]);
    });

    test('readStream yields the bytes', () async {
      await store.write('k', bytes(1000, 5));

      final read = [for (final c in await store.readStream('k').toList()) ...c];

      expect(read, bytes(1000, 5));
    });

    test('readRange reads only what is asked, and fewer at the end', () async {
      await store.write('k', bytes(100, 0));

      expect(await store.readRange('k', start: 10, length: 5), bytes(5, 10));
      expect(
        await store.readRange('k', start: 95, length: 50),
        bytes(5, 95),
        reason: 'the object ends before the range does',
      );
      expect(await store.readRange('k', start: 100, length: 5), isEmpty);
    });
  });

  group('a write is atomic', () {
    test('a stream that fails part-way keeps the previous object and leaves '
        'no temp', () async {
      await store.write('k', bytes(100, 1));
      Stream<List<int>> failing() async* {
        yield bytes(50, 9);
        throw StateError('the source broke');
      }

      await expectLater(store.writeStream('k', failing()), throwsStateError);

      expect(await store.read('k'), bytes(100, 1));
      expect(filesOnDisk(), ['k']);
    });

    test(
      'a stream that fails with no previous object leaves nothing',
      () async {
        Stream<List<int>> failing() async* {
          yield bytes(50, 9);
          throw StateError('the source broke');
        }

        await expectLater(store.writeStream('k', failing()), throwsStateError);

        expect(await store.exists('k'), isFalse);
        expect(filesOnDisk(), isEmpty);
      },
    );

    test('a process that dies before the promote keeps the previous object; '
        'what it left is not an object', () async {
      await store.write('k', bytes(100, 1));

      os.crashOnNextRename = true;
      await expectLater(
        store.write('k', bytes(200, 2)),
        throwsA(isA<_Crash>()),
      );

      expect(await store.read('k'), bytes(100, 1));
      expect(
        filesOnDisk().where((f) => f.contains(FileDataStore.writeTempSuffix)),
        hasLength(1),
        reason: 'a dead process cleans nothing up',
      );
      expect((await store.list('')).map((e) => e.key), ['k']);
    });

    test('a write to a new key that dies leaves no object', () async {
      os.crashOnNextRename = true;
      await expectLater(
        store.writeStream('k', Stream.value(bytes(300, 3))),
        throwsA(isA<_Crash>()),
      );

      expect(await store.exists('k'), isFalse);
      expect(await store.list(''), isEmpty);
    });

    test('sweepLeftovers removes a temp old enough that no write owns it, '
        'and leaves a fresh one', () async {
      os.crashOnNextRename = true;
      await expectLater(store.write('a', bytes(10, 1)), throwsA(isA<_Crash>()));
      os.crashOnNextRename = true;
      await expectLater(store.write('b', bytes(10, 1)), throwsA(isA<_Crash>()));
      os.dead = false;
      await store.write('keep', bytes(10, 1));
      final temps = Directory('${tempDir.path}/root')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains(FileDataStore.writeTempSuffix))
          .toList();
      // One temp is made old; the other is a write that is still going.
      temps.first.setLastModifiedSync(
        DateTime.now().subtract(const Duration(minutes: 10)),
      );

      await store.sweepLeftovers();

      expect(
        filesOnDisk().where((f) => f.contains(FileDataStore.writeTempSuffix)),
        hasLength(1),
      );
      expect(await store.read('keep'), bytes(10, 1));
    });
  });

  group('list', () {
    setUp(() async {
      await store.write('photos/a', bytes(10, 1));
      await store.write('photos/b/c', bytes(20, 1));
      await store.write('photos_old/d', bytes(30, 1));
      await store.write('other', bytes(40, 1));
    });

    Future<Map<String, int>> sizes(String prefix) async => {
      for (final e in await store.list(prefix)) e.key: e.size,
    };

    test('an empty prefix lists everything, with sizes', () async {
      expect(await sizes(''), {
        'photos/a': 10,
        'photos/b/c': 20,
        'photos_old/d': 30,
        'other': 40,
      });
    });

    test('a prefix ending in a slash is a subtree', () async {
      expect(await sizes('photos/'), {'photos/a': 10, 'photos/b/c': 20});
    });

    test('a bare prefix is a raw string prefix', () async {
      expect(await sizes('photos'), {
        'photos/a': 10,
        'photos/b/c': 20,
        'photos_old/d': 30,
      });
    });

    test('a prefix nothing has is empty', () async {
      expect(await store.list('nothing/'), isEmpty);
    });

    test('a tombstone and a write temp are not listed', () async {
      File(
        '${tempDir.path}/root/other${FileDataStore.tombstoneSuffix}1',
      ).writeAsBytesSync([1]);
      File(
        '${tempDir.path}/root/other${FileDataStore.writeTempSuffix}ab',
      ).writeAsBytesSync([1]);

      expect((await sizes('other')).keys, ['other']);
    });

    test('a listing of many objects stats every one', () async {
      for (var i = 0; i < 60; i++) {
        await store.write('many/k$i', bytes(i + 1, 0));
      }

      final listed = await sizes('many/');

      expect(listed.length, 60);
      expect(listed['many/k59'], 60);
    });
  });

  group('delete', () {
    setUp(() async {
      await store.write('photos/a', bytes(10, 1));
      await store.write('photos/b/c', bytes(20, 1));
      await store.write('photos_old/d', bytes(30, 1));
      await store.write('other', bytes(40, 1));
    });

    test(
      'delete removes the one object, and is harmless when there is none',
      () async {
        await store.delete('other');
        await store.delete('other');

        expect(await store.exists('other'), isFalse);
        expect(await store.exists('photos/a'), isTrue);
      },
    );

    test('a slash-terminated prefix removes the subtree only', () async {
      await store.deletePrefix('photos/');

      expect((await store.list('')).map((e) => e.key).toSet(), {
        'photos_old/d',
        'other',
      });
    });

    test(
      'a bare prefix removes siblings that share the partial segment',
      () async {
        await store.deletePrefix('photos');

        expect((await store.list('')).map((e) => e.key), ['other']);
      },
    );

    test('an empty prefix removes every object and keeps the root', () async {
      await store.deletePrefix('');

      expect(await store.list(''), isEmpty);
      expect(Directory('${tempDir.path}/root').existsSync(), isTrue);
    });
  });

  group('importFile', () {
    late File source;

    setUp(() async {
      source = File('${tempDir.path}/picked.bin')
        ..writeAsBytesSync(bytes(500, 7));
    });

    test('copies the file and leaves the source', () async {
      await store.importFile('k', source.path);

      expect(await store.read('k'), bytes(500, 7));
      expect(source.existsSync(), isTrue);
    });

    test('with move, the file itself is renamed into place', () async {
      await store.importFile('k', source.path, move: true);

      expect(await store.read('k'), bytes(500, 7));
      expect(source.existsSync(), isFalse);
      expect(os.renamed, contains(source.path));
      expect(
        os.renamed.where((p) => p.contains(FileDataStore.writeTempSuffix)),
        isEmpty,
        reason: 'no copy through a temp: the bytes were not copied',
      );
    });

    test('with move, a refused rename falls back to a copy and deletes the '
        'source only afterwards', () async {
      os.refuseRenameOf = source.path;

      await store.importFile('k', source.path, move: true);

      expect(await store.read('k'), bytes(500, 7));
      expect(source.existsSync(), isFalse);
    });

    test('a move that falls back and then fails keeps the source', () async {
      os.refuseRenameOf = source.path;
      os.crashOnNextRename = true;
      // The refused rename is not the crash: the promote of the copy is.
      os.crashAfterRefusal = true;

      await expectLater(
        store.importFile('k', source.path, move: true),
        throwsA(isA<_Crash>()),
      );

      expect(source.existsSync(), isTrue);
      expect(await store.exists('k'), isFalse);
    });

    test('a path that is not a file is not found', () async {
      await expectLater(
        store.importFile('k', '${tempDir.path}/nope'),
        throwsA(isA<FileNotFoundError>()),
      );
    });

    test('the file already stored at the key is refused', () async {
      await store.write('k', bytes(10, 1));

      await expectLater(
        store.importFile('k', '${tempDir.path}/root/k'),
        throwsArgumentError,
      );
      expect(await store.read('k'), bytes(10, 1));
    });
  });

  group('materialize', () {
    test('shared gives the object\'s own path, with no copy', () async {
      await store.write('k', bytes(10, 1));

      final handle = await store.materialize('k');

      expect(handle.localPath, '${tempDir.path}/root/k');
      await handle.release();
      expect(
        await store.exists('k'),
        isTrue,
        reason: 'release keeps the object',
      );
    });

    test('exclusive gives a private copy that release deletes', () async {
      await store.write('k', bytes(10, 1));

      final handle = await store.materialize('k', exclusive: true);

      expect(handle.localPath, isNot('${tempDir.path}/root/k'));
      expect(File(handle.localPath).readAsBytesSync(), bytes(10, 1));
      await handle.release();
      expect(File(handle.localPath).existsSync(), isFalse);
      expect(await store.read('k'), bytes(10, 1));
    });
  });
}

class _Crash implements Exception {}

/// An OS that can "die" at the promote step, refuse one rename (as a different volume does),
/// and records every rename that ran.
class _FaultyOs extends DefaultFileSystemOs {
  bool crashOnNextRename = false;
  bool crashAfterRefusal = false;
  bool dead = false;
  String? refuseRenameOf;

  /// The source path of every rename that ran.
  final List<String> renamed = [];

  @override
  Future<void> renameOver(File from, String toPath) async {
    if (from.path == refuseRenameOf) {
      refuseRenameOf = null;
      // A refused rename moves nothing: a different volume says so.
      if (!crashAfterRefusal) crashOnNextRename = false;
      throw const FileSystemException('cross-device link');
    }
    if (crashOnNextRename) {
      crashOnNextRename = false;
      dead = true;
      throw _Crash();
    }
    renamed.add(from.path);
    await super.renameOver(from, toPath);
  }

  @override
  Future<void> deleteFile(File file) async {
    // A dead process deletes nothing; the test reads the wreckage.
    if (dead && file.path.contains(FileDataStore.writeTempSuffix)) return;
    await super.deleteFile(file);
  }
}
