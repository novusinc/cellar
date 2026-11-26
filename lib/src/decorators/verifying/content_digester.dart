import 'dart:async';

/// Bring-your-own content hashing for `VerifyingBackend`.
///
/// cellar ships no hashing: which digest a file is checked against (MD5 because
/// that is what the storage service reports, SHA-256 because that is what you
/// trust) is the application's choice, as is how it is computed (on the UI
/// isolate, in a worker, through a native library). Implement this over the hash
/// of your choice and pass it to `VerifyingBackend`.
///
/// The digest is an opaque string: the backend only compares it for equality with
/// the one the caller expects, so use whatever spelling that caller has (lowercase
/// hex, base64).
abstract interface class ContentDigester {
  /// A short name for the algorithm (`'md5'`, `'sha256'`), recorded with the
  /// digest so a later reader knows what it is comparing.
  String get algorithm;

  /// Begin hashing one object. A session is used for one stream and then
  /// discarded.
  ContentDigestSession start();
}

/// The running hash of one stream.
abstract interface class ContentDigestSession {
  /// Feed the next chunk, in order. May be asynchronous (a hash computed off the
  /// calling isolate); the stream waits for it, so a slow digester slows the
  /// write rather than buffering.
  FutureOr<void> add(List<int> chunk);

  /// The digest of everything added, spelled the way the caller expects it.
  FutureOr<String> finish();
}
