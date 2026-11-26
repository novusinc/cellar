/// A full browser quota surfaces as a typed QuotaExceededError, and a write is
/// reported only once the browser has committed it. Browser-only: it makes the
/// real IndexedDB fail the way a full quota does. Invoked ONLY by the web runner.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:cellar/cellar_lowlevel.dart';
import 'package:test/test.dart';

/// Makes `IDBObjectStore.put` fail like a full quota, for the length of a test.
///
/// `mode` is one of:
/// - `throw`: `put` throws a `QuotaExceededError` DOMException (from the `after`-th
///   call on), as a browser may when it knows at once the value cannot fit;
/// - `abort`: `put` is accepted and its request succeeds, but the transaction then
///   aborts with a `QuotaExceededError`, which is how a browser reports that the
///   commit does not fit. Only the transaction's end says so.
const String _failPuts = r'''
(function () {
  const proto = IDBObjectStore.prototype;
  const originalPut = proto.put;
  const state = { mode: 'throw', after: 0, calls: 0 };
  const quota = () => new DOMException('The quota has been exceeded.', 'QuotaExceededError');
  proto.put = function (value, key) {
    state.calls++;
    if (state.calls <= state.after) return originalPut.apply(this, arguments);
    if (state.mode === 'throw') throw quota();
    const request = originalPut.apply(this, arguments);
    const tx = this.transaction;
    request.addEventListener('success', function () {
      Object.defineProperty(tx, 'error', { configurable: true, get: quota });
      tx.abort();
    });
    return request;
  };
  state.restore = function () { proto.put = originalPut; };
  globalThis.__cellarQuota = state;
})();
''';

JSObject get _state => globalContext['__cellarQuota']! as JSObject;

/// Fail every `put` after the first [after] ones, in [mode], until [_restore].
void _fail(String mode, {int after = 0}) {
  globalContext.callMethod<JSAny?>('eval'.toJS, _failPuts.toJS);
  _state['mode'] = mode.toJS;
  _state['after'] = after.toJS;
}

void _restore() {
  final state = globalContext['__cellarQuota'];
  if (state != null) {
    ((state as JSObject)['restore']! as JSFunction).callAsFunction(state);
    globalContext['__cellarQuota'] = null;
  }
}

void runIndexedDbQuotaBattery() {
  group('IndexedDbBackend on a full quota', () {
    Uint8List sized(int n, [int seed = 0]) =>
        Uint8List.fromList(List.generate(n, (i) => (i + seed) & 255));

    late IndexedDbBackend backend;
    var n = 0;

    setUp(() {
      backend = IndexedDbBackend(dbName: 'cellar_quota_${n++}');
    });

    tearDown(() async {
      _restore();
      await backend.dispose();
    });

    test('a put the browser refuses throws QuotaExceededError, a WriteError, '
        'and stores nothing', () async {
      await backend.write('kept', sized(100, 1));
      _fail('throw');

      await expectLater(
        backend.write('new', sized(200 * 1024)),
        throwsA(
          isA<QuotaExceededError>()
              .having((e) => e.key, 'key', isNotEmpty)
              .having((e) => e, 'is a WriteError', isA<WriteError>()),
        ),
      );
      _restore();

      expect(await backend.exists('new'), isFalse);
      expect(await backend.read('kept'), sized(100, 1));
      expect((await backend.list('')).map((i) => i.key), ['kept']);
    });

    test(
      'a commit the browser refuses after accepting the put throws '
      'QuotaExceededError instead of reporting a write that is not stored',
      () async {
        await backend.write('kept', sized(100, 1));
        _fail('abort');

        await expectLater(
          backend.write('new', sized(1000)),
          throwsA(isA<QuotaExceededError>()),
        );
        _restore();

        expect(await backend.exists('new'), isFalse);
        expect(await backend.read('kept'), sized(100, 1));
      },
    );

    test('a failure part-way through a long write leaves the previous object '
        'readable and the new one absent', () async {
      await backend.write('k', sized(100, 1));
      // 200 KiB is four chunk records; the third put fails.
      _fail('throw', after: 2);

      await expectLater(
        backend.write('k', sized(200 * 1024, 5)),
        throwsA(isA<QuotaExceededError>()),
      );
      _restore();

      expect(await backend.read('k'), sized(100, 1));
      expect((await backend.head('k'))!.size, 100);
    });

    test(
      'a metadata update and a copy that hit the quota throw it too',
      () async {
        await backend.write('k', sized(100, 1));
        _fail('abort');

        await expectLater(
          backend.updateMetadata('k', contentType: 'a/b'),
          throwsA(isA<QuotaExceededError>()),
        );
        await expectLater(
          backend.copy('k', 'k2'),
          throwsA(isA<QuotaExceededError>()),
        );
        _restore();

        expect((await backend.head('k'))!.contentType, isNull);
        expect(await backend.exists('k2'), isFalse);
      },
    );

    test('with room, writes work and are reported after the commit', () async {
      await backend.write('k', sized(300 * 1024, 2));

      expect(await backend.read('k'), sized(300 * 1024, 2));
      // A second connection sees it: it was committed, not merely accepted.
      final other = IndexedDbBackend(dbName: 'cellar_quota_${n - 1}');
      addTearDown(other.dispose);
      expect(await other.read('k'), sized(300 * 1024, 2));
    });
  });
}
