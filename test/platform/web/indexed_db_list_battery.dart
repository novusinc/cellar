/// IndexedDB listing reads only manifests — browser-only: it observes the real
/// IndexedDB calls the browser receives. Invoked ONLY by the web runner.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:cellar/cellar_lowlevel.dart';
import 'package:test/test.dart';

/// Counts what a listing asks IndexedDB for, by wrapping the browser's own
/// `IDBObjectStore.get` and `openCursor` for the length of a test.
const String _spyOn = r'''
(function () {
  const proto = IDBObjectStore.prototype;
  const originalGet = proto.get;
  const originalOpenCursor = proto.openCursor;
  const spy = { gets: [], valueCursors: 0 };
  proto.get = function (key) {
    spy.gets.push(String(key));
    return originalGet.apply(this, arguments);
  };
  proto.openCursor = function () {
    spy.valueCursors++;
    return originalOpenCursor.apply(this, arguments);
  };
  spy.restore = function () {
    proto.get = originalGet;
    proto.openCursor = originalOpenCursor;
  };
  globalThis.__cellarIdbSpy = spy;
})();
''';

void _install() => globalContext.callMethod<JSAny?>('eval'.toJS, _spyOn.toJS);

JSObject get _spy => globalContext['__cellarIdbSpy']! as JSObject;

void _remove() {
  (_spy['restore']! as JSFunction).callAsFunction(_spy);
}

List<String> get _gets => [
  for (final key in (_spy['gets']! as JSArray<JSString>).toDart) key.toDart,
];

int get _valueCursors => (_spy['valueCursors']! as JSNumber).toDartInt;

void runIndexedDbListBattery() {
  group('IndexedDbBackend list reads manifests only', () {
    Uint8List sized(int n) =>
        Uint8List.fromList(List.generate(n, (i) => i & 255));

    test('a listing of multi-chunk objects opens no value cursor and reads '
        'no chunk record', () async {
      final backend = IndexedDbBackend(dbName: 'cellar_list_manifests');
      addTearDown(backend.dispose);
      // 200 KiB at the 64 KiB default: four chunk records and a manifest each.
      await backend.write(
        'media/a',
        sized(200 * 1024),
        const WriteOptions(contentType: 'video/mp4', metadata: {'k': 'v'}),
      );
      await backend.write('media/b', sized(130 * 1024));

      _install();
      addTearDown(_remove);
      final listed = await backend.list('media/');

      expect(
        {for (final i in listed) i.key: i.size},
        {'media/a': 200 * 1024, 'media/b': 130 * 1024},
      );
      expect(
        listed.firstWhere((i) => i.key == 'media/a').contentType,
        'video/mp4',
      );
      expect(listed.firstWhere((i) => i.key == 'media/a').metadata['k'], 'v');
      expect(
        _valueCursors,
        0,
        reason: 'a value cursor reads every record body',
      );
      expect(
        _gets.where((key) => key.contains('__g') || key.contains('__c')),
        isEmpty,
        reason: 'no chunk record is read',
      );
      expect(_gets, everyElement(endsWith('__manifest')));
      expect(_gets, hasLength(2), reason: 'one read per manifest');
    });

    test('lists nothing, and honors the prefix', () async {
      final backend = IndexedDbBackend(dbName: 'cellar_list_prefix');
      addTearDown(backend.dispose);
      await backend.write('x/one', sized(100));
      await backend.write('y/two', sized(100));

      expect(await backend.list('z/'), isEmpty);
      expect((await backend.list('x/')).map((i) => i.key), ['x/one']);
    });

    test('lastModified is the manifest\'s, and a rewrite shows once', () async {
      final backend = IndexedDbBackend(dbName: 'cellar_list_rewrite');
      addTearDown(backend.dispose);
      await backend.write('k', sized(150 * 1024));
      await backend.write('k', sized(10));

      final listed = await backend.list('');

      expect(listed, hasLength(1));
      expect(listed.single.size, 10);
      expect(
        listed.single.lastModified,
        (await backend.head('k'))!.lastModified,
      );
    });
  });
}
