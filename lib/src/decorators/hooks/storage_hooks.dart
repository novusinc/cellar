import 'dart:async';

import 'package:cellar/src/core/write_options.dart';

/// Runs before an object is written (`write`, `writeStream`, and the destination of
/// `copy`, which has no options of its own: [options] is then empty). Returns the
/// options to write with, which may be [options] itself or a changed copy. **Throw to
/// veto the write**: nothing is stored and the error reaches the caller.
typedef BeforeWriteHook =
    FutureOr<WriteOptions> Function(String key, WriteOptions options);

/// Runs after an object was written, with the options it was written with. It cannot
/// undo the write; a failure is reported to [StorageHooks.onHookError].
typedef AfterWriteHook =
    FutureOr<void> Function(String key, WriteOptions options);

/// Runs before a `delete` of [key], or a `deletePrefix` of it ([prefix] is true).
/// **Throw to veto**: nothing is deleted and the error reaches the caller.
typedef BeforeDeleteHook =
    FutureOr<void> Function(String key, {required bool prefix});

/// Runs after a delete, with the same arguments as [BeforeDeleteHook]. A failure is
/// reported to [StorageHooks.onHookError].
typedef AfterDeleteHook =
    FutureOr<void> Function(String key, {required bool prefix});

/// Runs after [key] was read: after `read`, `readRange` and `materialize` return, and
/// after `readStream` has delivered its last chunk (not when it fails or is cancelled
/// part-way). A failure is reported to [StorageHooks.onHookError].
typedef AfterReadHook = FutureOr<void> Function(String key);

/// Called with the hook that failed (`'afterWrite'`, `'afterDelete'`, `'afterRead'`),
/// the key, and what it threw.
typedef HookErrorCallback =
    void Function(String hook, String key, Object error);

/// Application code to run around storage calls: the extension seam for behavior
/// that belongs to the app and not to cellar (an audit trail, a quota check, stamping
/// metadata on every write).
///
/// Hooks **observe or veto, and hold no locks**: a `before` hook that throws stops
/// the call, an `after` hook cannot undo what happened, and nothing here serializes
/// calls (cellar leaves locking to the application). A hook is run in the caller's
/// call, so a slow one slows it; do slow work in the background.
///
/// `updateMetadata` and `patchMetadata` are not hooked: they change tags, not content.
class StorageHooks {
  /// Hooks for `HookedBackend`; each may be left out.
  const StorageHooks({
    this.beforeWrite,
    this.afterWrite,
    this.beforeDelete,
    this.afterDelete,
    this.afterRead,
    this.onHookError,
  });

  /// See [BeforeWriteHook].
  final BeforeWriteHook? beforeWrite;

  /// See [AfterWriteHook].
  final AfterWriteHook? afterWrite;

  /// See [BeforeDeleteHook].
  final BeforeDeleteHook? beforeDelete;

  /// See [AfterDeleteHook].
  final AfterDeleteHook? afterDelete;

  /// See [AfterReadHook].
  final AfterReadHook? afterRead;

  /// Told when an `after` hook failed. Null ignores the failure.
  final HookErrorCallback? onHookError;
}
