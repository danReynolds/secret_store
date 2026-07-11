/// The front API (see doc/design.md): a bytes-first async key-value store.
///
/// One constructor, one input: `SecretStorage(appId:)`. The library resolves
/// the strongest scheme the platform offers (the README's per-platform table);
/// the caller never picks a mechanism, a file path, or a key home — those are
/// derived, and every ambiguous state fails closed and loud.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'android_keystore_key_source.dart';
import 'app_paths.dart';
import 'backend.dart';
import 'backends/encrypted_file_backend.dart';
import 'backends/keystore_backend.dart';
import 'errors.dart';
import 'ffi/jni.dart';
import 'ffi/keychain.dart';
import 'ffi/keystore_api.dart';
import 'ffi/posix_file.dart';
import 'ffi/secret_service.dart';
import 'identifiers.dart';
import 'key_source.dart';

/// Stores named byte secrets.
final class SecretStorage {
  /// Injects a [SecretBackend] directly — the test hatch (pass a fake in your
  /// own suite). Not a configuration surface; production callers use
  /// [SecretStorage.new].
  SecretStorage.withBackend(this.backend);

  /// Opens (or creates) the secret store for [appId] — e.g.
  /// `com.example.myapp` — using the strongest scheme this platform offers,
  /// resolved automatically and **fail-closed**:
  ///
  /// - **macOS, entitled app** (Keychain Sharing entitlement): each secret is
  ///   a native item in the Data Protection keychain — Secure Enclave,
  ///   hardware-backed. Detected by probing the DP keychain once per process;
  ///   `errSecMissingEntitlement` (−34018) is the *normal* result for a plain
  ///   CLI or `dart run` and quietly selects the file scheme below. Any
  ///   **other** DP failure throws: an entitled app with a misconfigured
  ///   keychain setup must hear about it, never be silently downgraded.
  /// - **macOS, CLI / unentitled**: all secrets in one authenticated encrypted
  ///   file (XChaCha20-Poly1305 + key commitment) under
  ///   `~/Library/Application Support/<appId>/`, its key held in the login
  ///   Keychain.
  /// - **Linux (desktop)**: the same encrypted file under
  ///   `${XDG_DATA_HOME:-~/.local/share}/<appId>/`, its key in the Secret
  ///   Service (GNOME Keyring / KWallet).
  /// - **Android (12 / API 31+)**: the same encrypted file in the app-private
  ///   files dir, its key wrapped by an AES-256-GCM key sealed inside
  ///   **AndroidKeyStore** (TEE / StrongBox) — hardware-backed, pure
  ///   `dart:ffi`, no plugin. Older Android throws [KeystoreUnreachable].
  /// - **Anywhere else** — including headless boxes with no unlocked keyring —
  ///   throws [KeystoreUnreachable] with guidance rather than degrading.
  ///
  /// `await backend.describe()` reports the resolved scheme and its
  /// [SecurityLevel].
  factory SecretStorage({required String appId}) {
    validateAppId(appId);
    return SecretStorage.withBackend(_resolveBackend(appId));
  }

  /// The underlying backend. Read [SecretBackend.capabilities] to branch on
  /// optional operations, or `await backend.describe()` for a health snapshot
  /// (which scheme was resolved, its [SecurityLevel], reachable, locked).
  final SecretBackend backend;

  /// Reads the raw bytes for [key], or null if absent.
  Future<Uint8List?> read(String key) {
    validateIdentifier(key, 'key');
    return backend.read(key);
  }

  /// Reads [key] as a UTF-8 string, or null if absent.
  Future<String?> readString(String key) async {
    final bytes = await read(key);
    return bytes == null ? null : utf8.decode(bytes);
  }

  /// Whether [key] exists.
  Future<bool> containsKey(String key) {
    validateIdentifier(key, 'key');
    return backend.contains(key);
  }

  /// Stores [value] under [key], replacing any existing value. [label] is
  /// optional non-secret metadata shown in keystore UIs.
  Future<void> write(String key, Uint8List value, {String? label}) {
    validateIdentifier(key, 'key');
    validateLabel(label);
    return backend.write(key, value, label: label);
  }

  /// Stores [value] (encoded UTF-8) under [key].
  Future<void> writeString(String key, String value, {String? label}) =>
      write(key, Uint8List.fromList(utf8.encode(value)), label: label);

  /// Removes [key]. Idempotent.
  Future<void> delete(String key) {
    validateIdentifier(key, 'key');
    return backend.delete(key);
  }

  /// All entries. Throws [UnsupportedCapability] when the backend cannot
  /// enumerate (guard with `backend.capabilities.enumeration`). `async` so the
  /// capability failure surfaces as a rejected future, not a synchronous throw.
  Future<Map<String, Uint8List>> readAll() async {
    if (!backend.capabilities.enumeration) {
      throw const UnsupportedCapability('enumeration');
    }
    return backend.readAll();
  }

  /// Removes every entry. Requires enumeration.
  Future<void> deleteAll() async {
    final all = await readAll();
    for (final key in all.keys) {
      await backend.delete(key);
    }
  }
}

/// Cached per-process result of the macOS Data Protection probe. Entitlements
/// are baked into the code signature, so the answer cannot change within a
/// process lifetime — caching makes the resolved scheme deterministic and
/// avoids re-probing per store.
DataProtectionAvailability? _dpAvailabilityCache;

/// The level to report for Apple native (Data Protection keychain) items.
/// Their protection is Secure-Enclave-gated on all shipping SE hardware —
/// every current iOS device, and Apple-silicon/T2 Macs — so [hardwareBacked]
/// is the accurate platform-mechanism claim. Unlike Android's Keystore
/// (`KeyInfo`), the DP keychain exposes no per-item hardware-residency query,
/// and the two non-SE contexts (the iOS Simulator; an entitled app on a
/// pre-T2 Intel Mac) are not reliably detectable from pure Dart FFI — the
/// `SIMULATOR_*` vars are absent in the app process. So this reports the
/// mechanism claim, and the non-measurable exceptions are documented
/// (doc/platforms/ios.md, macos.md) with the on-device hardware check called
/// out as pending.
SecurityLevel _appleNativeLevel() => SecurityLevel.hardwareBacked;

/// Resolves the per-platform scheme (doc/implementation-plan.md §2).
SecretBackend _resolveBackend(String appId) {
  if (Platform.isIOS) {
    // iOS: the DP keychain is the *only* keychain and every app can use it
    // (the implicit default access group every signed app carries) — no
    // probe, no fork: unconditional native Secure-Enclave items.
    return KeystoreBackend(
      service: appId,
      api: AppleKeychainApi.dataProtection(),
      level: _appleNativeLevel(),
    );
  }
  if (Platform.isMacOS) {
    final dp = AppleKeychainApi.dataProtection();
    final availability = _dpAvailabilityCache ??= dp.probeDataProtection();
    final native = availability == DataProtectionAvailability.available;
    // Refuse to silently switch physical stores if the entitlement changed
    // between versions (empty-looking store, or stale-value rollback).
    _guardMacOSScheme(appId, native ? 'native' : 'file');
    switch (availability) {
      case DataProtectionAvailability.available:
        // Entitled app: native items in the DP keychain (Secure Enclave).
        return KeystoreBackend(
          service: appId,
          api: dp,
          level: _appleNativeLevel(),
        );
      case DataProtectionAvailability.missingEntitlement:
        // The normal CLI / `dart run` path: encrypted file, key in the login
        // Keychain.
        return _encryptedFileScheme(appId, AppleKeychainApi());
    }
  }
  if (Platform.isLinux) {
    return _encryptedFileScheme(appId, SecretToolApi());
  }
  if (Platform.isAndroid) {
    // Encrypted file in the app-private files dir; its key wrapped by an
    // AndroidKeyStore hardware key (API 31+ — Jni.instance() fails closed
    // with guidance below that). No Context needed anywhere on this path.
    final jni = Jni.instance();
    final containerPath = androidContainerPathFor(appId,
        tmpdir: jni.systemProperty('java.io.tmpdir'));
    final dir = containerPath.substring(0, containerPath.lastIndexOf('/'));
    return EncryptedFileBackend(
      path: containerPath,
      keySource: AndroidKeystoreKeySource(
        alias: '$appId.store-key',
        blobPath: '$dir/$wrappedKeyFileName',
      ),
    );
  }
  throw KeystoreUnreachable(
      'no secret storage scheme for ${Platform.operatingSystem} — supported: '
      'macOS, Linux desktop, iOS, Android 12+. Windows and headless servers '
      'are not supported yet (headless design: '
      'doc/headless-implementation-plan.md)');
}

/// The shared file scheme: one authenticated container, key in the OS keystore
/// ([SystemKeySource] reports [SecurityLevel.loginBound]).
SecretBackend _encryptedFileScheme(String appId, KeystoreApi api) {
  return EncryptedFileBackend(
    path: containerPathFor(appId),
    keySource: SystemKeySource(service: appId, api: api),
  );
}

/// macOS-only migration guard. A marker file records which scheme
/// (`native` | `file`) provisioned this appId's store. If the entitlement
/// changed between versions the resolved scheme differs from the marker, and
/// silently using the new store would hide the old secrets (empty-looking
/// store) or resurface stale values — so throw [MigrationRequired] instead.
/// First provision writes the marker (creating the app-support dir `0700`;
/// for the native scheme this is its only on-disk footprint).
void _guardMacOSScheme(String appId, String intended) {
  const fs = SecureFileSystem();
  final container = containerPathFor(appId);
  final dir = container.substring(0, container.lastIndexOf('/'));
  final markerPath = '$dir/.scheme';
  final existingBytes =
      fs.readCappedSync(markerPath, maxBytes: 32, requirePrivate: true);
  if (existingBytes != null) {
    final existing = utf8.decode(existingBytes).trim();
    if (existing != intended) {
      throw MigrationRequired(appId: appId, from: existing, to: intended);
    }
    return;
  }
  fs.ensurePrivateDirSync(dir);
  fs.writeAtomicSync(markerPath, Uint8List.fromList(utf8.encode(intended)));
}
