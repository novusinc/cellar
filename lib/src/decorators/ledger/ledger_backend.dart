import 'dart:typed_data';

import 'package:cellar/src/core/importable_backend.dart';
import 'package:cellar/src/core/movable_backend.dart';
import 'package:cellar/src/core/object_info.dart';
import 'package:cellar/src/core/storage_backend.dart';
import 'package:cellar/src/core/write_options.dart';
import 'package:cellar/src/decorators/forwarding/forwarding_backend.dart';
import 'package:cellar/src/decorators/ledger/usage_ledger.dart';

/// A decorator that keeps a [UsageLedger] of the backend it wraps: after every
/// write, copy, move, import, delete and metadata change it records what the backend
/// now holds, so "how many bytes are stored" is answered from memory.
///
/// It changes nothing about what the calls do. Each is forwarded, and only once it
/// has succeeded is the ledger told, so a write that fails (and so, by the backend's
/// atomic-write contract, leaves the previous object) leaves the ledger as it was.
/// What a write left behind is read back with one `head` of the object, so the
/// ledger holds exactly what a listing would return, including what the backend
/// itself put in the metadata.
///
/// A `list` through it is the ledger's source of truth: it is taken as a complete
/// listing of its prefix, and the ledger is brought into line with it.
///
/// **Place it beneath whatever must see its effect and beneath any decorator that
/// takes locks**, as close to the storage as the calls that matter can reach. A
/// change made to the wrapped backend by another route is not seen until the next
/// listing. A `Cellar` finds the ledger of a partition by looking down its stack, so
/// the stack you build and the lifecycle's rules refer to one ledger.
///
/// Like every decorator it does not dispose what it wraps.
class LedgerBackend extends ForwardingBackend
    implements ImportableBackend, MovableBackend {
  /// Keep [ledger] (a new one by default) for [inner]. [onError] hears a change
  /// whose record failed: the change itself succeeded, and the ledger corrects
  /// itself at its next listing.
  LedgerBackend(super.inner, {UsageLedger? ledger, this.onError})
    : ledger = ledger ?? UsageLedger();

  /// What this backend holds.
  final UsageLedger ledger;

  /// Told when reading an object back to record it failed.
  final void Function(String key, Object error)? onError;

  /// Records what [key] is now. One `head`: the cost of a write is that, and not
  /// a listing.
  Future<void> _refresh(String key) async {
    try {
      final info = await inner.head(key);
      if (info == null) {
        ledger.forget(key);
      } else {
        ledger.record(info);
      }
    } catch (error) {
      // The change happened; only the record of it did not. Better to hold
      // nothing for the key than something that may be out of date.
      ledger.forget(key);
      onError?.call(key, error);
    }
  }

  @override
  Future<void> write(
    String key,
    Uint8List bytes, [
    WriteOptions options = const WriteOptions(),
  ]) async {
    await super.write(key, bytes, options);
    await _refresh(key);
  }

  @override
  Future<void> writeStream(
    String key,
    Stream<List<int>> byteStream, [
    WriteOptions options = const WriteOptions(),
  ]) async {
    await super.writeStream(key, byteStream, options);
    await _refresh(key);
  }

  @override
  Future<void> copy(String sourceKey, String destKey) async {
    await super.copy(sourceKey, destKey);
    await _refresh(destKey);
  }

  /// Moves by rename where [inner] can, and by copy then delete where it cannot
  /// ([moveObject]).
  @override
  Future<void> move(String sourceKey, String destKey) async {
    checkNotDisposed();
    await moveObject(inner, sourceKey, destKey);
    if (sourceKey != destKey) ledger.forget(sourceKey);
    await _refresh(destKey);
  }

  /// Imports the file where [inner] can; throws [UnsupportedError] where it cannot
  /// (a browser has no file to import). Ask `inner` first when that matters.
  @override
  Future<void> importFile(
    String key,
    String path, {
    bool move = false,
    WriteOptions options = const WriteOptions(),
  }) async {
    checkNotDisposed();
    final target = inner;
    if (target is! ImportableBackend) {
      throw UnsupportedError(
        '${target.runtimeType} cannot import a file, so neither can a '
        'LedgerBackend over it',
      );
    }
    await target.importFile(key, path, move: move, options: options);
    await _refresh(key);
  }

  @override
  Future<void> delete(String key) async {
    await super.delete(key);
    ledger.forget(key);
  }

  @override
  Future<void> deletePrefix(String prefix) async {
    await super.deletePrefix(prefix);
    ledger.forgetPrefix(prefix);
  }

  @override
  Future<void> updateMetadata(
    String key, {
    String? contentType,
    Map<String, String> metadata = const {},
  }) async {
    await super.updateMetadata(
      key,
      contentType: contentType,
      metadata: metadata,
    );
    // The backend may add keys of its own, so ask it what the object now is.
    await _refresh(key);
  }

  @override
  Future<void> patchMetadata(String key, Map<String, String?> changes) async {
    await super.patchMetadata(key, changes);
    // A patch changes exactly the keys it names: no need to ask.
    ledger.applyPatch(key, changes);
  }

  /// A complete listing of [prefix]: the ledger is brought into line with it.
  @override
  Future<List<ObjectInfo>> list(String prefix) async {
    checkNotDisposed();
    ledger.beginSnapshot();
    final List<ObjectInfo> listed;
    try {
      listed = await inner.list(prefix);
    } catch (_) {
      ledger.abortSnapshot();
      rethrow;
    }
    ledger.endSnapshot(prefix, listed);
    return listed;
  }
}

/// The ledger of the first [LedgerBackend] in [backend]'s stack, looking down
/// through every `ForwardingBackend` decorator; null when there is none.
UsageLedger? usageLedgerOf(StorageBackend backend) {
  var current = backend;
  while (true) {
    if (current is LedgerBackend) return current.ledger;
    if (current is! ForwardingBackend) return null;
    current = current.inner;
  }
}
