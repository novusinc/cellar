import 'package:cellar/cellar_lowlevel.dart';

/// A [ContentDigester] for tests: a 32-bit FNV-1a hash, spelled as lowercase hex.
/// Not cryptographic; deterministic and sensitive to a single changed byte, which is
/// all the tests need. It hashes in chunks, so a stream split differently gives the
/// same digest.
class FakeDigester implements ContentDigester {
  const FakeDigester();

  /// The digest of [bytes], as a session would give it.
  static String of(List<int> bytes) {
    var hash = 0x811c9dc5;
    for (final byte in bytes) {
      hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  @override
  String get algorithm => 'fnv32';

  @override
  ContentDigestSession start() => _Session();
}

class _Session implements ContentDigestSession {
  int _hash = 0x811c9dc5;

  @override
  void add(List<int> chunk) {
    for (final byte in chunk) {
      _hash = ((_hash ^ byte) * 0x01000193) & 0xffffffff;
    }
  }

  @override
  String finish() => _hash.toRadixString(16).padLeft(8, '0');
}
