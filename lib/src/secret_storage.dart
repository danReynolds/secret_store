/// The front API (see doc/design.md): a bytes-first async key-value store.
///
/// The production front door has one input: `SecretStorage(appId:)`. It
/// resolves the fixed policy for the current platform (documented in
/// doc/sdk.md); callers using that constructor never pick a mechanism, file
/// path, or key home. Those are derived; every ambiguous state fails closed
/// and loud. [SecretStorage.withBackend] remains the explicit test/custom hatch.
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
  /// `com.example.myapp` — using Keybay's fixed policy for this platform,
  /// resolved automatically and **fail-closed**:
  ///
  /// - **macOS, entitled app** (Keychain Sharing entitlement): each secret is
  ///   a native item in the Data Protection Keychain with a fixed device-bound,
  ///   non-synchronizing policy. Detected by probing the DP keychain once per
  ///   process; `errSecMissingEntitlement` (−34018) is the *normal* result for a
  ///   plain CLI or `dart run` and quietly selects the file scheme below. Any
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
  ///   files dir, its key wrapped by an AES-256-GCM key created in
  ///   **Android Keystore**. StrongBox is requested and the actual provider
  ///   level is inspected; pure `dart:ffi`, no plugin. Older Android throws
  ///   [KeystoreUnreachable].
  /// - **Unsupported operating systems** throw [KeystoreUnreachable] with
  ///   guidance rather than degrading. Headless operation has no separate
  ///   resolver branch; when a supported desktop credential service is absent
  ///   or locked, backend use surfaces its typed availability error.
  ///
  /// `await backend.describe()` reports the resolved scheme and any protection
  /// level the selected backend can actually inspect. Apple native-item paths
  /// deliberately report no [SecurityLevel].
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

/// Resolves the per-platform scheme (doc/implementation-plan.md §2).
SecretBackend _resolveBackend(String appId) {
  if (Platform.isIOS) {
    // iOS: the DP keychain is the *only* keychain and every app can use it
    // (the implicit default access group every signed app carries) — no
    // probe, no fork: unconditional native Data Protection Keychain items.
    final api = AppleKeychainApi.dataProtection();
    return KeystoreBackend(service: appId, api: api);
  }
  if (Platform.isMacOS) {
    final dp = AppleKeychainApi.dataProtection();
    final availability = _dpAvailabilityCache ??= dp.probeDataProtection();
    switch (availability) {
      case DataProtectionAvailability.available:
        // Entitled app: native items in the Data Protection Keychain.
        // Refuse to silently switch stores if the entitlement was gained
        // between versions while an encrypted-file store already holds data
        // (which would otherwise look empty).
        _guardMacOSFileToNative(appId);
        return KeystoreBackend(service: appId, api: dp);
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
    // Android Keystore key (API 31+ — Jni.instance() fails closed below that).
    // The provider level is measured; no Context is needed on this path.
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
      'macOS, Linux desktop, iOS, Android 12+. Windows is unsupported and '
      'headless operation is out of scope (design record: '
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

/// macOS migration guard for a **gained** Keychain Sharing entitlement.
///
/// The encrypted-file scheme leaves a natural on-disk trace — the container
/// file — so no separate marker is needed: if the entitled app now resolves to
/// native items while a file-scheme container already holds data, switching
/// silently would hide those secrets behind an empty-looking store. Throw
/// [MigrationRequired] so the transition is deliberate. A store that was only
/// *opened* under the file scheme but never written has no container, so this
/// never false-fires. (The reverse — a lost entitlement — is not detectable
/// from an unentitled process, which cannot read the abandoned DP items; the
/// data is OS-walled rather than resurfaced. See doc/platforms/macos.md.)
void _guardMacOSFileToNative(String appId) {
  const fs = SecureFileSystem();
  if (fs.existsSync(containerPathFor(appId))) {
    throw MigrationRequired(
      appId: appId,
      from: StorageScheme.encryptedFile,
      to: StorageScheme.nativeItems,
    );
  }
}
