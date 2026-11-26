/// AccessTrackingBackend over the REAL filesystem: the access record lives in
/// the sidecar, replaced atomically, and the body's modification time never moves.
library;

import 'dart:io';

import 'package:cellar/cellar_lowlevel.dart';
import 'package:test/test.dart';

import '../../batteries/access_tracking_battery.dart';
import '../../harness/temp_dir.dart';

void main() {
  late Directory tempRoot;
  var counter = 0;
  setUpAll(() async => tempRoot = await makeTempDir('access_fs_'));
  tearDownAll(() async {
    try {
      await tempRoot.delete(recursive: true);
    } on FileSystemException {
      // Best-effort cleanup.
    }
  });

  runAccessTrackingBattery(
    'FileSystemBackend',
    create: () => FileSystemBackend('${tempRoot.path}/${counter++}'),
  );
}
