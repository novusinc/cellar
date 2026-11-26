/// HookedBackend over the REAL filesystem: a vetoed write leaves no file, no temp.
library;

import 'dart:io';

import 'package:cellar/cellar_lowlevel.dart';
import 'package:test/test.dart';

import '../../batteries/hooks_battery.dart';
import '../../harness/temp_dir.dart';

void main() {
  late Directory tempRoot;
  var counter = 0;
  setUpAll(() async => tempRoot = await makeTempDir('hooks_fs_'));
  tearDownAll(() async {
    try {
      await tempRoot.delete(recursive: true);
    } on FileSystemException {
      // Best-effort cleanup.
    }
  });

  runHooksBattery(
    'FileSystemBackend',
    create: () => FileSystemBackend('${tempRoot.path}/${counter++}'),
  );
}
