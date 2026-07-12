// The mobile/desktop integration tier: exercises SecretStorage(appId:) against
// the REAL platform keystore from inside a real Flutter app bundle.
//
// Run via tool/test_e2e.sh, which passes the per-environment EXPECT_SCHEME /
// EXPECT_LEVEL dart-defines. The expectations by leg (see
// doc/implementation-plan.md Phase 2):
//   macOS, ad-hoc signing (no entitlement): file + loginBound (−34018 branch
//     inside a real .app — the same branch every CLI takes).
//   macOS, Keychain Sharing + development signing: native items + hardware
//     (SE-probed on this Apple-silicon Mac) — the DP SUCCESS branch.
//   iOS simulator: native items + hardware (Xcode 15+ simulators emulate the
//     Secure Enclave, so the SE probe succeeds — same as a real device).
//   Android emulator (API 31+): encrypted file + AndroidKeyStore-wrapped key
//     via the pure-FFI JNI shim; level measured from the KEK (software on the
//     emulator) in the dedicated test after a write.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:keyway/keyway.dart';

/// What this leg expects — set per environment, not detected (detection is
/// what the test is *checking*). `EXPECT_SCHEME` is `native` | `file` (the
/// deterministic storage shape); `EXPECT_LEVEL` is `hardware` | `software` |
/// `login` and may be empty when the level can't be asserted up front (Android
/// measures from a KEK that doesn't exist until the first write — see the
/// dedicated test below). The level is environment-dependent: a modern iOS
/// *simulator* (Xcode 15+) emulates the Secure Enclave and reports `hardware`,
/// as does a real device; an environment with no SE reports `software`.
const String expectScheme = String.fromEnvironment('EXPECT_SCHEME');
const String expectLevel = String.fromEnvironment('EXPECT_LEVEL');

/// The macOS entitled and unentitled legs run on the *same machine* and would
/// otherwise share one app-support dir — where the entitled leg would trip
/// the scheme-migration guard on the unentitled leg's container file. Each
/// macOS leg passes a distinct APP_ID so they stay isolated; mobile legs use
/// the default.
const appId =
    String.fromEnvironment('APP_ID', defaultValue: 'com.example.keywayHarness');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late SecretStorage store;

  setUpAll(() {
    store = SecretStorage(appId: appId);
  });

  tearDown(() async {
    // Leave no test entries behind (the store itself — container/key or
    // keychain items — persists like a real app's would).
    await store.deleteAll();
  });

  test('resolver picked the scheme + level this environment must get',
      () async {
    final info = await store.backend.describe();

    final wantScheme = switch (expectScheme) {
      'native' => StorageScheme.nativeItems,
      'file' => StorageScheme.encryptedFile,
      // Defaults for legs that don't pass EXPECT_SCHEME: iOS is always native,
      // everything else here is the file scheme.
      _ => Platform.isIOS
          ? StorageScheme.nativeItems
          : StorageScheme.encryptedFile,
    };
    expect(info.scheme, wantScheme, reason: 'wrong storage shape');

    final wantLevel = switch (expectLevel) {
      'hardware' => SecurityLevel.hardwareBacked,
      'software' => SecurityLevel.softwareBacked,
      'login' => SecurityLevel.loginBound,
      _ => null,
    };
    if (wantLevel != null) {
      // Measured, not assumed: iOS probes for a Secure Enclave (emulated on
      // Xcode 15+ simulators → hardware), Android reads KeyInfo, macOS login.
      expect(info.level, wantLevel, reason: 'wrong measured level');
    }

    expect(info.available, isTrue);
    expect(info.locked, isFalse);
  });

  test('Android: security level is measured from the KEK, not asserted',
      () async {
    if (!Platform.isAndroid) {
      markTestSkipped('Android-only');
      return;
    }
    // Provision the KEK, then read the level the hardware actually claims.
    await store.writeString('__lvl', 'x');
    final info = await store.backend.describe();
    // An emulator's Keystore is software-emulated, so the honest measured
    // level is `softwareBacked` — proving we report what KeyInfo says, not a
    // blanket "hardwareBacked". A real device with TEE/StrongBox reports
    // hardwareBacked.
    expect(info.level, SecurityLevel.softwareBacked,
        reason: 'emulator Keystore is software; measurement must say so');
  });

  test('macOS entitled: a pre-existing file store blocks native (migration)',
      () async {
    if (!(Platform.isMacOS && expectScheme == 'native')) {
      markTestSkipped('entitled-macOS-only');
      return;
    }
    const migAppId = 'com.example.keywayHarness.migration';
    final dir = Directory(
        '${Platform.environment['HOME']}/Library/Application Support/$migAppId');
    final container = File('${dir.path}/secrets.enc');
    try {
      dir.createSync(recursive: true);
      // A leftover encrypted-file container from before the app gained the
      // Keychain Sharing entitlement. Resolving to native items now must refuse
      // rather than silently present an empty store and strand these secrets.
      container.writeAsBytesSync(Uint8List.fromList([1, 2, 3, 4]));
      expect(
        () => SecretStorage(appId: migAppId),
        throwsA(isA<MigrationRequired>()
            .having((e) => e.from, 'from', StorageScheme.encryptedFile)
            .having((e) => e.to, 'to', StorageScheme.nativeItems)),
      );
    } finally {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  test('full round-trip: bytes, strings, labels, enumeration, delete',
      () async {
    expect(await store.read('token'), isNull);
    expect(await store.containsKey('token'), isFalse);

    final binary = Uint8List.fromList(List.generate(64, (i) => (i * 7) % 256));
    await store.write('binary', binary, label: 'harness binary');
    expect(await store.read('binary'), binary);

    await store.writeString('token', 's3cr3t-value', label: 'harness token');
    expect(await store.readString('token'), 's3cr3t-value');
    expect(await store.containsKey('token'), isTrue);

    // Overwrite replaces.
    await store.writeString('token', 'rotated');
    expect(await store.readString('token'), 'rotated');

    expect((await store.readAll()).keys.toSet(),
        containsAll(<String>{'binary', 'token'}));

    await store.delete('token');
    expect(await store.readString('token'), isNull);
    await store.delete('token'); // idempotent
  });

  test('a second store instance reads the same data (shared backing)',
      () async {
    await store.writeString('shared', 'visible');
    final second = SecretStorage(appId: appId);
    expect(await second.readString('shared'), 'visible');
  });

  test('unicode values survive the round-trip', () async {
    await store.writeString('unicode', 'café ☕ 名前 — ключ');
    expect(await store.readString('unicode'), 'café ☕ 名前 — ключ');
  });

  test('Android: ciphertext + wrapped-key blob at the derived path', () async {
    if (!Platform.isAndroid) {
      markTestSkipped('Android-only');
      return;
    }
    await store.writeString('android-proof', 'pl4in-t3xt-pr00f');
    // Cross-check of the resolver's Context-free derivation: the engine sets
    // TMPDIR (Directory.systemTemp) to the app cache dir; files/ is its
    // sibling under dataDir.
    final dataDir = Directory.systemTemp.parent.path;
    final dir = '$dataDir/files/$appId';
    final container = File('$dir/secrets.enc');
    final blob = File('$dir/store-key.wrapped');
    expect(container.existsSync(), isTrue,
        reason: 'container missing at derived path $dir');
    expect(blob.existsSync(), isTrue,
        reason: 'wrapped-key blob missing at derived path $dir');
    expect(String.fromCharCodes(container.readAsBytesSync()),
        isNot(contains('pl4in-t3xt-pr00f')),
        reason: 'container must be ciphertext');
    // The blob is our versioned format ('SKW1'), and small (wrapped 32-byte
    // key + GCM overhead — the raw store key never touches disk).
    final blobBytes = blob.readAsBytesSync();
    expect(blobBytes.sublist(0, 4), [0x53, 0x4B, 0x57, 0x31]);
    expect(blobBytes.length, lessThan(128));
    expect(String.fromCharCodes(blobBytes), isNot(contains('pl4in')));
  });
}
