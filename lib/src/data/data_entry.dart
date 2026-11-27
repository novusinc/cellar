/// What a `DataStore` knows about one object: where it is, how large it is and when its
/// bytes were last written. Nothing else: a content type, a caller's metadata and how often
/// the object is used belong to the metadata store, not to the bytes.
class DataEntry {
  /// An entry for the object at [key], [size] bytes long, last written at [modified].
  const DataEntry({
    required this.key,
    required this.size,
    required this.modified,
  });

  /// The object's key, `/`-separated, relative to the store's root.
  final String key;

  /// The object's length in bytes.
  final int size;

  /// When the object's bytes were last written (UTC).
  final DateTime modified;

  @override
  bool operator ==(Object other) =>
      other is DataEntry &&
      other.key == key &&
      other.size == size &&
      other.modified == modified;

  @override
  int get hashCode => Object.hash(key, size, modified);

  @override
  String toString() => 'DataEntry($key, $size bytes, $modified)';
}
