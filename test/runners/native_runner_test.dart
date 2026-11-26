/// Runs every platform-blind battery on the VM. The SAME batteries run
/// in real Chrome via web_runner_test.dart — one spec, two worlds, a
/// platform-dependent result is a red build, not an unknown.
///
/// Platform-bound suites (real filesystem, Blob URLs) are quarantined
/// in test/platform/ and never appear here.
library;

import '../batteries/cellar_battery.dart';
import '../batteries/access_tracking_battery.dart';
import '../batteries/budget_battery.dart';
import '../batteries/chunked_battery.dart';
import '../batteries/conformance_battery.dart';
import '../batteries/core_battery.dart';
import '../batteries/encrypted_battery.dart';
import '../batteries/eviction_battery.dart';
import '../batteries/forwarding_battery.dart';
import '../batteries/hooks_battery.dart';
import '../batteries/metadata_keys_battery.dart';
import '../batteries/reserved_prefix_battery.dart';
import '../batteries/scope_battery.dart';
import '../batteries/stack_battery.dart';
import '../batteries/verifying_battery.dart';
import '../harness/fake_encryptor.dart';

import 'package:cellar/cellar_lowlevel.dart';

void main() {
  // ── The contract, over every pure backend ──
  runStorageBackendConformance('InMemoryBackend', create: InMemoryBackend.new);
  runStorageBackendConformance(
    'ForwardingBackend over InMemory',
    create: () => ForwardingBackend(InMemoryBackend()),
  );
  runStorageBackendConformance(
    'ChunkedBackend over InMemory',
    create: () =>
        ChunkedBackend(backing: InMemoryBackend(), chunkSize: 64 * 1024),
  );
  runStorageBackendConformance(
    'EncryptedBackend over InMemory',
    create: () => EncryptedBackend(
      inner: InMemoryBackend(),
      encryptor: FakeEncryptor(),
      keyResolver: const FixedKeyResolver('conformance-key'),
    ),
  );

  // ── The feature batteries ──
  runCoreBattery();
  runScopeBattery();
  runChunkedBattery();
  runEncryptedBattery();
  runForwardingBattery();
  runCellarBattery();
  runEvictionBattery();
  runBudgetBattery();
  runMetadataKeysBattery();
  runReservedPrefixBattery();

  // ── AccessTrackingBackend over each stack the runner can host ──
  runAccessTrackingBattery('InMemoryBackend', create: InMemoryBackend.new);
  runAccessTrackingBattery(
    'ChunkedBackend over InMemory',
    create: () =>
        ChunkedBackend(backing: InMemoryBackend(), chunkSize: 64 * 1024),
  );

  // ── HookedBackend over each stack the runner can host ──
  runHooksBattery('InMemoryBackend', create: InMemoryBackend.new);
  runHooksBattery(
    'ChunkedBackend over InMemory',
    create: () =>
        ChunkedBackend(backing: InMemoryBackend(), chunkSize: 64 * 1024),
  );

  // ── VerifyingBackend over each stack the runner can host ──
  runVerifyingBattery('InMemoryBackend', create: InMemoryBackend.new);
  runVerifyingBattery(
    'ChunkedBackend over InMemory',
    create: () =>
        ChunkedBackend(backing: InMemoryBackend(), chunkSize: 64 * 1024),
  );
  runVerifyingBattery(
    'EncryptedBackend over ChunkedBackend over InMemory',
    create: () => EncryptedBackend(
      inner: ChunkedBackend(backing: InMemoryBackend(), chunkSize: 64),
      encryptor: FakeEncryptor(),
      keyResolver: const FixedKeyResolver('verify-key'),
    ),
  );
  runStackBattery();
}
