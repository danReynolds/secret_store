// The mobile/desktop integration tier: exercises SecretStorage(appId:) against
// the REAL platform keystore from inside a real Flutter app bundle.
//
// Legs (see doc/implementation-plan.md Phase 2):
//   macOS, default signing (ad-hoc, no keychain entitlement):
//     flutter test integration_test -d macos
//       → resolver must pick encrypted-file + loginBound (−34018 branch inside
//         a real .app — the same branch every CLI takes).
//   macOS, Keychain Sharing entitlement + development signing:
//     flutter test integration_test -d macos --dart-define=EXPECT_HARDWARE=true
//       → resolver must pick native DP-keychain items + hardwareBacked — the
//         DP SUCCESS branch, unreachable from CI.
//   iOS simulator:
//     flutter test integration_test -d <iphone-sim> --dart-define=EXPECT_HARDWARE=true
//       → unconditional native items + hardwareBacked (no probe on iOS).
//   Android emulator (API 31+; no dart-define — Android has no config fork):
//     flutter test integration_test -d emulator-5554
//       → encrypted file + AndroidKeyStore-wrapped key, hardwareBacked,
//         via the pure-FFI JNI shim (no plugin, no package:jni).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:secret_store/secret_store.dart';

/// Which resolver outcome this leg expects (set per build config, not
/// detected — detection is what the test is *checking*).
const bool expectHardware = bool.fromEnvironment('EXPECT_HARDWARE');

/// The macOS entitled and unentitled legs run on the *same machine* and would
/// otherwise share one app-support dir — where the entitled leg would trip the
/// scheme-migration guard on the unentitled leg's marker. Each macOS leg passes
/// a distinct APP_ID so they stay isolated; mobile legs use the default.
const appId = String.fromEnvironment('APP_ID',
    defaultValue: 'com.example.secretStoreHarness');

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

  test('resolver picked the scheme this platform/config must get', () async {
    final info = await store.backend.describe();
    if (Platform.isAndroid) {
      // No config fork on Android: always the encrypted file with its key
      // wrapped by an AndroidKeyStore key. The *level* is measured from the
      // KEK, which doesn't exist until first write — asserted in the dedicated
      // test below, not here.
      expect(info.name, 'encrypted-file',
          reason: 'Android must resolve to the file scheme');
    } else if (Platform.isIOS || expectHardware) {
      // iOS, and entitled macOS: native DP items. The level is Apple's
      // platform-mechanism claim (hardwareBacked on SE hardware); the
      // simulator/pre-T2-Intel exceptions aren't runtime-detectable from pure
      // Dart FFI (SIMULATOR_* is absent in the app process), so the silicon
      // check stays a pending on-device step — see doc/platforms/ios.md.
      expect(info.name, 'keystore', reason: 'must resolve to native DP items');
      expect(info.level, SecurityLevel.hardwareBacked);
    } else {
      expect(info.name, 'encrypted-file',
          reason: 'unentitled build must resolve to the file scheme');
      expect(info.level, SecurityLevel.loginBound);
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
