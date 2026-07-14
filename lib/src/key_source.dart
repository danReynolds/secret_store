/// Store-key providers for the wrapped-key composition (see doc/design.md).
///
/// A [KeySource] holds the single 32-byte key that seals the encrypted
/// container. The secure sources the resolver composes are the OS keystore
/// ([SystemKeySource]) and, on Android, the hardware-wrapped
/// `AndroidKeystoreKeySource` (in its own file).
///
/// [InMemoryKeySource] and [FileKeySource] are **not exported**: the first is
/// non-persistent (tests only), the second is an insecure plaintext-key-on-disk
/// fallback whose benign name is a footgun. They remain here as internal test
/// helpers and reference implementations — a caller who genuinely needs a
/// bring-your-own-key or on-disk source implements [KeySource] directly (using
/// [SecureFileSystem] for 0600-from-birth hygiene), which makes the security
/// tradeoff a deliberate, owned choice rather than an accidental pick.
library;

import 'dart:math';
import 'dart:typed_data';

import 'backend.dart';
import 'errors.dart';
import 'ffi/keystore_api.dart';
import 'ffi/posix_file.dart';

/// The store key length in bytes.
const int storeKeyLength = 32;

/// Generates a fresh store key from the OS CSPRNG. `Random.secure()` only —
/// never `Random()`.
Uint8List generateStoreKey() {
  final rng = Random.secure();
  final key = Uint8List(storeKeyLength);
  for (var i = 0; i < storeKeyLength; i++) {
    key[i] = rng.nextInt(256);
  }
  return key;
}

/// Availability of a key source, for diagnostics.
final class KeySourceStatus {
  const KeySourceStatus({
    required this.name,
    required this.present,
    required this.available,
    this.locked = false,
    this.securityLevel,
    this.detail,
  });

  /// Backing mechanism, e.g. `keychain` or `file`.
  final String name;

  /// Whether a key currently exists.
  final bool present;

  /// Whether the mechanism can be reached at all.
  final bool available;

  /// Whether the mechanism is locked (keystore needs unlocking).
  final bool locked;

  /// Offline-attack protection of where the key lives, as the key source
  /// itself reports it — measured, not assumed (e.g. Android inspects
  /// `KeyInfo`). Null when it can't be determined (e.g. no key exists yet).
  final SecurityLevel? securityLevel;

  final String? detail;
}

/// Provides the container's 32-byte store key.
abstract interface class KeySource {
  /// The existing key, or null if none has been created.
  Future<Uint8List?> read();

  /// Generates, persists, and returns a fresh key. Overwrites any existing one,
  /// so call only when [read] returned null (the backend enforces this order).
  Future<Uint8List> create();

  /// Removes the persisted key. Idempotent.
  Future<void> delete();

  /// Diagnostics.
  Future<KeySourceStatus> describe();
}

/// Holds the key in process memory only. Not persistent. **Internal / not
/// exported** — used by the test suite; bring-your-own-key callers implement
/// [KeySource] directly.
final class InMemoryKeySource implements KeySource {
  InMemoryKeySource([Uint8List? initial]) : _key = initial;

  Uint8List? _key;

  @override
  Future<Uint8List?> read() async => _key;

  @override
  Future<Uint8List> create() async => _key = generateStoreKey();

  @override
  Future<void> delete() async => _key = null;

  @override
  Future<KeySourceStatus> describe() async => KeySourceStatus(
        name: 'memory',
        present: _key != null,
        available: true,
      );
}

/// Persists the raw key to a `0600` file beside the container — **insecure**
/// (the key sits in plaintext next to the data it protects, so a full-disk
/// theft recovers both). **Internal / not exported**: it stays here as the
/// reference implementation of a file-backed [KeySource] and for the test
/// suite. A caller who consciously accepts an on-disk key implements [KeySource]
/// themselves (this class is a fine template) — the friction makes the choice
/// deliberate rather than an accidental autocomplete pick.
final class FileKeySource implements KeySource {
  FileKeySource(this.path, {SecureFileSystem fs = const SecureFileSystem()})
      : _fs = fs;

  final String path;
  final SecureFileSystem _fs;

  @override
  Future<Uint8List?> read() async {
    // requirePrivate: a group/world-readable key file is refused outright
    // (the OpenSSH stance) — we only ever create it 0600, so loose modes mean
    // someone else touched it.
    final bytes =
        _fs.readCappedSync(path, maxBytes: 4096, requirePrivate: true);
    if (bytes == null) return null;
    if (bytes.length != storeKeyLength) {
      throw KeystoreOperationFailed(
          'key file has wrong length (${bytes.length}, expected $storeKeyLength)');
    }
    return bytes;
  }

  @override
  Future<Uint8List> create() async {
    final key = generateStoreKey();
    _fs.writeAtomicSync(path, key);
    return key;
  }

  @override
  Future<void> delete() async => _fs.deleteSync(path);

  @override
  Future<KeySourceStatus> describe() async => KeySourceStatus(
        name: 'file',
        present: _fs.existsSync(path),
        available: true,
        detail: path,
      );
}

/// Wraps the store key in the OS keystore — the default secure Model-B source.
/// The key itself never touches disk; only the AEAD-encrypted container does.
/// [api] is the platform keystore (`AppleKeychainApi` / `SecretToolApi`), wired by
/// the resolver or passed explicitly. [account] is the item name under
/// [service].
final class SystemKeySource implements KeySource {
  SystemKeySource({
    required this.service,
    required KeystoreApi api,
    this.account = 'store-key',
    this.label,
  }) : _api = api;

  final String service;
  final String account;
  final String? label;
  final KeystoreApi _api;

  @override
  Future<Uint8List?> read() async {
    final key = await _api.get(service, account);
    if (key == null) return null;
    if (key.length != storeKeyLength) {
      throw KeystoreOperationFailed(
          'store key has wrong length (${key.length}, expected $storeKeyLength)');
    }
    return key;
  }

  @override
  Future<Uint8List> create() async {
    final key = generateStoreKey();
    await _api.set(service, account, key, label: label ?? 'keyway key');
    return key;
  }

  @override
  Future<void> delete() => _api.delete(service, account);

  @override
  Future<KeySourceStatus> describe() async {
    final p = await _api.probe(service);
    var present = false;
    var detail = p.detail;
    if (p.available && !p.locked) {
      try {
        // Diagnostics need only existence. Keep the key out of process memory
        // and avoid prompting hardware-gated keychains to decrypt it.
        present = await _api.exists(service, account);
      } on SecretStoreException catch (e) {
        // Diagnostics never throw: the keystore can lock between the probe and
        // this attributes-only check, so report the failure in `detail`.
        detail = detail == null ? e.message : '$detail; ${e.message}';
      }
    }
    return KeySourceStatus(
      name: 'keystore',
      present: present,
      available: p.available,
      locked: p.locked,
      // The OS keystore holds the key under a login-derived key.
      securityLevel: SecurityLevel.loginBound,
      detail: detail,
    );
  }
}
