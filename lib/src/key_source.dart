/// Store-key providers for the wrapped-key composition (RFC 0005 §6, model B).
///
/// A [KeySource] holds the single 32-byte key that seals the encrypted
/// container. In dune's default it is the OS keystore ([KeychainKeySource],
/// added in P2); the [FileKeySource] here is the explicit `--insecure` fallback
/// (key on disk beside the ciphertext); [InMemoryKeySource] is for tests and
/// callers that manage the key themselves.
library;

import 'dart:math';
import 'dart:typed_data';

import 'errors.dart';
import 'ffi/keychain.dart';
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

/// Holds the key in process memory only. Not persistent — for tests, and for
/// callers that source the key themselves.
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

/// Persists the raw key to a `0600` file beside the container. This is the
/// **insecure** fallback (the key sits next to the data it protects); callers
/// must gate it behind an explicit opt-in (dune: `--insecure-file-secrets`).
final class FileKeySource implements KeySource {
  FileKeySource(this.path, {SecureFileSystem fs = const SecureFileSystem()})
      : _fs = fs;

  final String path;
  final SecureFileSystem _fs;

  @override
  Future<Uint8List?> read() async {
    final bytes = _fs.readCappedSync(path, maxBytes: 4096);
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
        present: _fs.readCappedSync(path, maxBytes: 4096) != null,
        available: true,
        detail: path,
      );
}

/// Wraps the store key in the OS keystore — dune's default (model B). The key
/// itself never touches disk; only the AEAD-encrypted container does.
final class KeychainKeySource implements KeySource {
  /// [api] defaults to the real [MacKeychainApi] (macOS only). [account] is the
  /// item name under [service] that holds the key.
  KeychainKeySource({
    required this.service,
    this.account = 'store-key',
    this.label,
    KeychainApi? api,
  }) : _api = api ?? MacKeychainApi();

  final String service;
  final String account;
  final String? label;
  final KeychainApi _api;

  @override
  Future<Uint8List?> read() async {
    final key = _api.get(service, account);
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
    _api.set(service, account, key, label: label ?? 'secret_store key');
    return key;
  }

  @override
  Future<void> delete() async => _api.delete(service, account);

  @override
  Future<KeySourceStatus> describe() async {
    final p = _api.probe(service);
    return KeySourceStatus(
      name: 'keychain',
      present:
          p.available && !p.locked ? _api.get(service, account) != null : false,
      available: p.available,
      locked: p.locked,
      detail: p.detail,
    );
  }
}
