import 'dart:convert';
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

/// The sidecar (`<key>.meta.json`) holds an object's content type and metadata,
/// which cannot be derived from its bytes. These tests pin that it is written
/// atomically, that it is never believed for a body it does not belong to, and
/// that an interrupted write is finished at the next open.
///
/// A write promotes two files: the body, then the sidecar. The tests make a
/// chosen promote "crash" through the injectable `FileSystemOs` seam, with the
/// process dead afterwards (no cleanup runs), so the disk holds what a real crash
/// would leave.
void main() {
  late Directory tempDir;
  late _CrashingOs os;
  late FileSystemBackend backend;

  Uint8List bytes(int length, int seed) =>
      Uint8List.fromList(List.generate(length, (i) => (i + seed) & 0xff));

  setUp(() async {
    tempDir = await makeTempDir('sidecar_');
    os = _CrashingOs();
    backend = FileSystemBackend(tempDir.path, os: os);
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  File sidecar(String key) => File('${tempDir.path}/$key.meta.json');

  List<File> sidecarTemps() => [
    for (final e in tempDir.listSync(recursive: true))
      if (e is File &&
          e.path.contains('.meta.json${FileSystemBackend.writeTempSuffix}'))
        e,
  ];

  /// A backend over the same directory as a new process would open it: a healthy OS.
  FileSystemBackend reopened() => FileSystemBackend(tempDir.path);

  group('the sidecar is written atomically', () {
    test('a crash while promoting it leaves the old sidecar whole', () async {
      await backend.write(
        'k',
        bytes(10, 1),
        const WriteOptions(contentType: 'a/b', metadata: {'v': '1'}),
      );
      final before = await sidecar('k').readAsString();

      os.crashOnRename = 2; // the body is promoted, the sidecar is not
      await expectLater(
        backend.write(
          'k',
          bytes(20, 2),
          const WriteOptions(contentType: 'c/d', metadata: {'v': '2'}),
        ),
        throwsA(isA<_Crash>()),
      );

      expect(await sidecar('k').readAsString(), before);
      expect(
        () => jsonDecode(before),
        returnsNormally,
        reason: 'the sidecar on disk parses',
      );
    });

    test('updateMetadata that dies before the promote keeps the old '
        'sidecar', () async {
      await backend.write(
        'k',
        bytes(10, 1),
        const WriteOptions(contentType: 'a/b', metadata: {'v': '1'}),
      );

      os.crashOnRename = 1;
      await expectLater(
        backend.updateMetadata(
          'k',
          contentType: 'c/d',
          metadata: const {'v': '2'},
        ),
        throwsA(isA<_Crash>()),
      );

      final info = await reopened().head('k');
      expect(info!.contentType, 'a/b');
      expect(info.metadata, {'v': '1'});
    });

    test(
      'updateMetadata does not change the body or its lastModified',
      () async {
        await backend.write(
          'k',
          bytes(10, 1),
          const WriteOptions(contentType: 'a/b'),
        );
        final before = await backend.head('k');

        await backend.updateMetadata(
          'k',
          contentType: 'c/d',
          metadata: const {'v': '2'},
        );

        final after = await backend.head('k');
        expect(after!.contentType, 'c/d');
        expect(after.metadata, {'v': '2'});
        expect(after.lastModified, before!.lastModified);
        expect(after.size, before.size);
        expect(await backend.read('k'), bytes(10, 1));
      },
    );

    test('updateMetadata on a key that does not exist throws and writes '
        'nothing', () async {
      await expectLater(
        backend.updateMetadata('missing', contentType: 'a/b'),
        throwsA(isA<FileNotFoundError>()),
      );
      expect(sidecar('missing').existsSync(), isFalse);
    });
  });

  group('a sidecar is never believed for another body', () {
    test('a crash between the two promotes does not show the old metadata '
        'with the new bytes', () async {
      await backend.write(
        'k',
        bytes(10, 1),
        const WriteOptions(contentType: 'a/b', metadata: {'v': '1'}),
      );

      os.crashOnRename = 2;
      await expectLater(
        backend.write(
          'k',
          bytes(20, 2),
          const WriteOptions(contentType: 'c/d', metadata: {'v': '2'}),
        ),
        throwsA(isA<_Crash>()),
      );

      final info = await reopened().head('k');
      expect(info!.size, 20, reason: 'the new body is what is there');
      expect(info.contentType, isNull, reason: 'not the previous object\'s');
      expect(info.metadata, isEmpty);
    });

    test('a body replaced behind the sidecar\'s back reads without its '
        'metadata', () async {
      await backend.write(
        'k',
        bytes(10, 1),
        const WriteOptions(contentType: 'a/b', metadata: {'v': '1'}),
      );
      await File('${tempDir.path}/k').writeAsBytes(bytes(33, 5));

      final info = await backend.head('k');
      expect(info!.size, 33);
      expect(info.contentType, isNull);
      expect(info.metadata, isEmpty);
    });

    test('a write with no metadata over one that had some clears it', () async {
      await backend.write(
        'k',
        bytes(10, 1),
        const WriteOptions(contentType: 'a/b', metadata: {'v': '1'}),
      );
      await backend.write('k', bytes(11, 1));

      final info = await backend.head('k');
      expect(info!.contentType, isNull);
      expect(info.metadata, isEmpty);
      expect(sidecar('k').existsSync(), isFalse);
    });

    test('a crash after the body of a write with no metadata promotes leaves '
        'the old sidecar unbelieved', () async {
      await backend.write(
        'k',
        bytes(10, 1),
        const WriteOptions(contentType: 'a/b'),
      );

      os.crashOnDeleteOfSidecar = true;
      await expectLater(
        backend.write('k', bytes(40, 3)),
        throwsA(isA<_Crash>()),
      );

      final info = await reopened().head('k');
      expect(info!.size, 40);
      expect(info.contentType, isNull);
    });

    test('copy gives the destination the source\'s metadata, and clears '
        'what its previous object had', () async {
      await backend.write(
        'dst',
        bytes(5, 1),
        const WriteOptions(contentType: 'old/x', metadata: {'old': '1'}),
      );
      await backend.write('src', bytes(9, 2));

      await backend.copy('src', 'dst');

      final plain = await backend.head('dst');
      expect(plain!.contentType, isNull);
      expect(plain.metadata, isEmpty);

      await backend.write(
        'tagged',
        bytes(7, 3),
        const WriteOptions(contentType: 'img/png', metadata: {'k': 'v'}),
      );
      await backend.copy('tagged', 'copy');
      final copied = await backend.head('copy');
      expect(copied!.contentType, 'img/png');
      expect(copied.metadata, {'k': 'v'});
      expect(await backend.read('copy'), bytes(7, 3));
    });
  });

  group('recovery at open', () {
    test('completes a write interrupted between the two promotes', () async {
      await backend.write(
        'k',
        bytes(10, 1),
        const WriteOptions(contentType: 'a/b', metadata: {'v': '1'}),
      );
      os.crashOnRename = 2;
      await expectLater(
        backend.write(
          'k',
          bytes(20, 2),
          const WriteOptions(contentType: 'c/d', metadata: {'v': '2'}),
        ),
        throwsA(isA<_Crash>()),
      );
      expect(sidecarTemps(), hasLength(1));

      final next = reopened();
      await next.recoverInterruptedWrites();

      final info = await next.head('k');
      expect(info!.size, 20);
      expect(info.contentType, 'c/d');
      expect(info.metadata, {'v': '2'});
      expect(sidecarTemps(), isEmpty);
    });

    test('keeps a fresh leftover whose body was never promoted, and deletes '
        'it once it is old', () async {
      await backend.write(
        'k',
        bytes(10, 1),
        const WriteOptions(contentType: 'a/b'),
      );
      os.crashOnRename = 1; // before the body is promoted
      await expectLater(
        backend.write(
          'k',
          bytes(20, 2),
          const WriteOptions(contentType: 'c/d'),
        ),
        throwsA(isA<_Crash>()),
      );
      final leftover = sidecarTemps().single;

      final next = reopened();
      await next.recoverInterruptedWrites();
      expect(
        leftover.existsSync(),
        isTrue,
        reason: 'it may belong to a write still in progress',
      );
      expect(
        (await next.head('k'))!.contentType,
        'a/b',
        reason: 'and is never promoted onto a body it does not match',
      );

      leftover.setLastModifiedSync(
        DateTime.now().subtract(const Duration(minutes: 5)),
      );
      await next.recoverInterruptedWrites();
      expect(leftover.existsSync(), isFalse);
      expect((await next.head('k'))!.contentType, 'a/b');
    });

    test('is a no-op on a directory that does not exist yet', () async {
      await FileSystemBackend(
        '${tempDir.path}/not_yet',
      ).recoverInterruptedWrites();
    });
  });

  group('older sidecars', () {
    test(
      'one written by cellar 1.0.0, with no identity, is still read',
      () async {
        await File('${tempDir.path}/old').writeAsBytes(bytes(8, 1));
        await File('${tempDir.path}/old.meta.json').writeAsString(
          jsonEncode({
            'contentType': 'text/plain',
            'metadata': {'a': 'b'},
          }),
        );

        final info = await backend.head('old');
        expect(info!.contentType, 'text/plain');
        expect(info.metadata, {'a': 'b'});
      },
    );

    test(
      'a sidecar written now carries fields an older cellar ignores',
      () async {
        await backend.write(
          'k',
          bytes(10, 1),
          const WriteOptions(contentType: 'a/b', metadata: {'v': '1'}),
        );

        final json = jsonDecode(await sidecar('k').readAsString()) as Map;
        expect(json['contentType'], 'a/b');
        expect(json['metadata'], {'v': '1'});
        expect(json['size'], 10);
        expect(json['bodyModified'], isA<int>());
      },
    );
  });
}

class _Crash implements Exception {
  @override
  String toString() => 'simulated crash';
}

/// An OS whose process "dies" at a chosen promote, with nothing cleaned up after.
class _CrashingOs extends DefaultFileSystemOs {
  int? _renamesLeft;

  /// Dies at the [n]th `renameOver` from now (1 is the next one); null clears it.
  set crashOnRename(int? n) => _renamesLeft = n;

  /// Dies when the sidecar of a body-only write is deleted, after the body
  /// was promoted.
  bool crashOnDeleteOfSidecar = false;

  bool _dead = false;

  @override
  Future<void> renameOver(File from, String toPath) async {
    final left = _renamesLeft;
    if (left != null) {
      _renamesLeft = left - 1;
      if (left == 1) {
        _renamesLeft = null;
        _dead = true;
        throw _Crash();
      }
    }
    await super.renameOver(from, toPath);
  }

  @override
  Future<void> deleteFile(File file) async {
    if (_dead) return; // a dead process deletes nothing
    if (crashOnDeleteOfSidecar && file.path.endsWith('.meta.json')) {
      crashOnDeleteOfSidecar = false;
      _dead = true;
      throw _Crash();
    }
    await super.deleteFile(file);
  }
}
