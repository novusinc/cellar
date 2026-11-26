/// Runs the IDENTICAL batteries as native_runner_test.dart, in a real
/// Chrome — plus the two suites only a browser can host: conformance
/// over real IndexedDB and Blob-URL materialization.
///
/// Run with `dart test -p chrome test/runners/web_runner_test.dart`
/// (never `flutter test --platform chrome` — see dart_test.yaml).
@TestOn('browser')
library;

import 'package:test/test.dart';

import '../batteries/cellar_battery.dart';
import '../batteries/budget_battery.dart';
import '../batteries/chunked_battery.dart';
import '../batteries/conformance_battery.dart';
import '../batteries/core_battery.dart';
import '../batteries/encrypted_battery.dart';
import '../batteries/eviction_battery.dart';
import '../batteries/forwarding_battery.dart';
import '../batteries/metadata_keys_battery.dart';
import '../batteries/scope_battery.dart';
import '../batteries/stack_battery.dart';
import '../batteries/verifying_battery.dart';
import '../harness/fake_encryptor.dart';
import '../platform/web/indexed_db_blob_battery.dart';
import '../platform/web/indexed_db_list_battery.dart';
import '../platform/web/indexed_db_patch_battery.dart';
import '../platform/web/indexed_db_quota_battery.dart';

import 'package:cellar/cellar_lowlevel.dart';

void main() {
  // ── The same contract runs, byte-identical to the VM ──
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

  // ── The same feature batteries ──
  runCoreBattery();
  runScopeBattery();
  runChunkedBattery();
  runEncryptedBattery();
  runForwardingBattery();
  runCellarBattery();
  runEvictionBattery();
  runBudgetBattery();
  runMetadataKeysBattery();

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

  // ── Browser-only: the substrate a VM cannot host ──
  var dbCounter = 0;
  runStorageBackendConformance(
    'IndexedDbBackend',
    create: () => IndexedDbBackend(dbName: 'cellar_conformance_${dbCounter++}'),
    supportsMaterialize: true,
  );
  runIndexedDbBlobBattery();
  runVerifyingBattery(
    'IndexedDbBackend',
    create: () => IndexedDbBackend(dbName: 'cellar_verifying_${dbCounter++}'),
  );
  runIndexedDbListBattery();
  runIndexedDbPatchBattery();
  runIndexedDbQuotaBattery();
}
