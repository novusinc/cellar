import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:cellar/cellar_lowlevel.dart' hide FileSystemBackend;
// White-box test of the NATIVE impl: imports the suffixed file directly (the
// switch's analyzer view resolves to the web stub, which cannot carry the
// io-typed `os:` parameter), and the OS seam, so a test can inject an OS that
// dies at a chosen step.
import 'package:cellar/src/backends/file_system/file_system_backend_native.dart';
import 'package:cellar/src/backends/file_system/os/file_system_os.dart';

import '../../harness/temp_dir.dart';

/// Atomic writes: a write, a streamed write and a copy each leave the previous
/// object or the whole new one at the key, never something in between.
///
/// The step that makes a new object visible is `FileSystemOs.renameOver`, so the
/// tests make that step "crash" through the injectable seam: the process dies
/// right before the new data is promoted, and nothing after it (not even cleanup)
/// runs. What the key holds then is what a real crash would leave.
void main() {
  late Directory tempDir;
  late _CrashingOs os;
  late FileSystemBackend backend;

  Uint8List bytes(int length, int seed) =>
      Uint8List.fromList(List.generate(length, (i) => (i + seed) & 0xff));

  setUp(() async {
    tempDir = await makeTempDir('atomic_write_');
    os = _CrashingOs();
    backend = FileSystemBackend(tempDir.path, os: os);
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  /// What a listing and a directory walk see, so a leftover temp is visible to
  /// the test but not to a reader.
  Future<List<String>> files() async => [
    for (final e in tempDir.listSync(recursive: true))
      if (e is File) e.path.substring(tempDir.path.length + 1),
  ]..sort();

  group('a write that dies before the new data is promoted', () {
    test('write keeps the previous object', () async {
      await backend.write(
        'k',
        bytes(100, 1),
        const WriteOptions(contentType: 'a/b'),
      );

      os.crashOnNextRename = true;
      await expectLater(
        backend.write(
          'k',
          bytes(200, 2),
          const WriteOptions(contentType: 'c/d'),
        ),
        throwsA(isA<_Crash>()),
      );

      expect(await backend.read('k'), bytes(100, 1));
      final info = await backend.head('k');
      expect(info!.size, 100);
      expect(info.contentType, 'a/b');
    });

    test('write to a new key leaves no object', () async {
      os.crashOnNextRename = true;
      await expectLater(
        backend.write('k', bytes(100, 1)),
        throwsA(isA<_Crash>()),
      );

      expect(await backend.exists('k'), isFalse);
      expect(await backend.head('k'), isNull);
      expect(await backend.list(''), isEmpty);
    });

    test('writeStream keeps the previous object', () async {
      await backend.write('k', bytes(100, 1));

      os.crashOnNextRename = true;
      await expectLater(
        backend.writeStream('k', Stream.value(bytes(300, 3))),
        throwsA(isA<_Crash>()),
      );

      expect(await backend.read('k'), bytes(100, 1));
    });

    test('copy over an existing key keeps the previous object', () async {
      await backend.write('src', bytes(500, 7));
      await backend.write('dst', bytes(100, 1));

      os.crashOnNextRename = true;
      await expectLater(backend.copy('src', 'dst'), throwsA(isA<_Crash>()));

      expect(await backend.read('dst'), bytes(100, 1));
      expect(await backend.read('src'), bytes(500, 7));
    });

    test('copy to a new key leaves no object', () async {
      await backend.write('src', bytes(500, 7));

      os.crashOnNextRename = true;
      await expectLater(backend.copy('src', 'dst'), throwsA(isA<_Crash>()));

      expect(await backend.exists('dst'), isFalse);
      expect((await backend.list('')).map((o) => o.key), ['src']);
    });

    test('the temp file it leaves is not an object', () async {
      os.crashOnNextRename = true;
      await expectLater(
        backend.write('dir/k', bytes(100, 1)),
        throwsA(isA<_Crash>()),
      );

      final left = await files();
      expect(
        left.where((f) => f.contains(FileSystemBackend.writeTempSuffix)),
        isNotEmpty,
        reason: 'a crash leaves its temp behind; it is inert',
      );
      expect(await backend.list(''), isEmpty);
      expect(await backend.list('dir/'), isEmpty);
    });
  });

  group('a failure that is not a crash', () {
    test(
      'a source stream that fails leaves the previous object and no temp',
      () async {
        await backend.write('k', bytes(100, 1));

        Stream<List<int>> failing() async* {
          yield bytes(50, 9);
          throw StateError('source died');
        }

        await expectLater(
          backend.writeStream('k', failing()),
          throwsStateError,
        );

        expect(await backend.read('k'), bytes(100, 1));
        expect(
          (await files()).where(
            (f) => f.contains(FileSystemBackend.writeTempSuffix),
          ),
          isEmpty,
        );
      },
    );

    test('a copy of a key that does not exist throws and leaves the '
        'destination alone', () async {
      await backend.write('dst', bytes(100, 1));

      await expectLater(backend.copy('missing', 'dst'), throwsA(anything));

      expect(await backend.read('dst'), bytes(100, 1));
    });
  });

  group('temp names', () {
    test(
      'two writes never share a temp file, even at the same instant',
      () async {
        await Future.wait([
          for (var i = 0; i < 100; i++) backend.write('k', bytes(10, i)),
        ]);

        expect(os.promoted, hasLength(100));
        expect(os.promoted.toSet(), hasLength(100));
      },
    );
  });

  group('a completed write', () {
    test('promotes through the OS seam and leaves no temp', () async {
      await backend.write('k', bytes(100, 1));
      await backend.writeStream('s', Stream.value(bytes(100, 2)));
      await backend.copy('k', 'c');

      expect(os.promoted, hasLength(3));
      expect(
        (await files()).where(
          (f) => f.contains(FileSystemBackend.writeTempSuffix),
        ),
        isEmpty,
      );
      expect(await backend.read('c'), bytes(100, 1));
    });
  });
}

class _Crash implements Exception {
  @override
  String toString() => 'simulated crash';
}

/// An OS whose process "dies" at the promote step on demand: [renameOver]
/// throws, and from then on nothing is cleaned up (a dead process runs no
/// `finally`), so what is on disk is what a real crash would leave.
class _CrashingOs extends DefaultFileSystemOs {
  bool crashOnNextRename = false;
  bool _dead = false;

  /// The temp path of every promote that ran.
  final List<String> promoted = [];

  @override
  Future<void> renameOver(File from, String toPath) async {
    if (crashOnNextRename) {
      crashOnNextRename = false;
      _dead = true;
      throw _Crash();
    }
    promoted.add(from.path);
    await super.renameOver(from, toPath);
  }

  @override
  Future<void> deleteFile(File file) async {
    // A dead process deletes nothing; the test reads the wreckage.
    if (_dead && file.path.contains(FileSystemBackend.writeTempSuffix)) return;
    await super.deleteFile(file);
  }
}
