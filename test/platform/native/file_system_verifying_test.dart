/// VerifyingBackend over the REAL filesystem: a mismatch leaves no temp file and
/// the previous object, a match is stored.
library;

import 'dart:io';

import 'package:cellar/cellar_lowlevel.dart';
import 'package:test/test.dart';

import '../../batteries/verifying_battery.dart';
import '../../harness/temp_dir.dart';

void main() {
  late Directory tempRoot;
  var counter = 0;
  setUpAll(() async => tempRoot = await makeTempDir('verifying_fs_'));
  tearDownAll(() async {
    try {
      await tempRoot.delete(recursive: true);
    } on FileSystemException {
      // Best-effort cleanup.
    }
  });

  runVerifyingBattery(
    'FileSystemBackend',
    create: () => FileSystemBackend('${tempRoot.path}/${counter++}'),
  );
}
