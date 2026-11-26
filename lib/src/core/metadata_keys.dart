/// The metadata keys cellar writes itself, and how to read them.
///
/// cellar keeps its own bookkeeping in the same `Map<String, String>` as the
/// metadata a caller passes (the chunked layer's chunk pointer and size, the
/// encryption layer's flag and plaintext size). Under cellar 1.0.0 those keys had
/// ordinary names (`generation`, `totalSize`, `encrypted`, ...), so a caller's
/// own key of the same name collided with them in storage.
///
/// They now live under the `cellar.` prefix, which belongs to cellar. Callers pass
/// and read their own keys exactly as given and never add the prefix; the layer
/// that owns a key adds it. **Objects written by cellar 1.0.0 still read:** an
/// object without the layer's current marker is read with the old names.
library;

/// One metadata key cellar owns: its current, prefixed name, and the unprefixed
/// name cellar 1.0.0 wrote.
class CellarMetadataKey {
  const CellarMetadataKey._(this.legacyName);

  /// The name cellar 1.0.0 stored, read only from objects it wrote.
  final String legacyName;

  /// The current name: `cellar.` + [legacyName].
  String get name => '$cellarMetadataPrefix$legacyName';
}

/// The prefix of every metadata key cellar writes.
const String cellarMetadataPrefix = 'cellar.';

/// The keys cellar owns, by the layer that maintains them.
abstract final class CellarMetadata {
  /// Chunked layer: which generation of chunk records the manifest points at.
  /// Its presence marks a manifest written by the current format.
  static const CellarMetadataKey generation = CellarMetadataKey._('generation');

  /// Chunked layer: how many chunk records the object has.
  static const CellarMetadataKey chunkCount = CellarMetadataKey._('chunkCount');

  /// Chunked layer: the object's size in bytes.
  static const CellarMetadataKey totalSize = CellarMetadataKey._('totalSize');

  /// Encryption layer: `'true'` when the stored bytes are ciphertext, `'false'`
  /// when the layer wrote them as plaintext. Its presence marks an object
  /// written by the current format, so an unprefixed `encrypted` key is then the
  /// caller's.
  static const CellarMetadataKey encrypted = CellarMetadataKey._('encrypted');

  /// Encryption layer: the plaintext size in bytes, when it is known.
  static const CellarMetadataKey originalSize = CellarMetadataKey._(
    'originalSize',
  );

  /// The value of [key] in [metadata].
  ///
  /// [marker] is the key whose presence says the object was written by the
  /// current format: then the current name is read and an unprefixed key of the
  /// same name belongs to the caller. Without it the object is cellar 1.0.0's and
  /// the old name is read.
  static String? read(
    Map<String, String> metadata,
    CellarMetadataKey key, {
    required CellarMetadataKey marker,
  }) => metadata.containsKey(marker.name)
      ? metadata[key.name]
      : metadata[key.legacyName];

  /// [metadata] as the encryption layer shows it to a caller: an encrypted object
  /// written by cellar 1.0.0 has its two keys renamed to the current names (so a
  /// caller reads one stable name for old and new objects alike); everything else
  /// is returned as it is.
  static Map<String, String> encryptionForCaller(Map<String, String> metadata) {
    final legacy = metadata[encrypted.legacyName] == 'true';
    if (!legacy || metadata.containsKey(encrypted.name)) return metadata;
    final size = metadata[originalSize.legacyName];
    return {
      for (final entry in metadata.entries)
        if (entry.key != encrypted.legacyName &&
            entry.key != originalSize.legacyName)
          entry.key: entry.value,
      encrypted.name: 'true',
      originalSize.name: ?size,
    };
  }
}
