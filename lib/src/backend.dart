/// The backend seam (see doc/design.md).
///
/// A [SecretBackend] is bound to a single service at construction; its methods
/// take only a key. Adding a platform is one implementation + one line of
/// default resolution. Capabilities are reported honestly, so a future backend
/// that cannot enumerate stays honest at the seam instead of throwing after
/// the fact.
library;

import 'dart:typed_data';

/// How strongly the resolved scheme protects the store against **offline**
/// attack (a stolen disk or backup). Reported by [BackendInfo.level] so a
/// consumer can verify — not guess — what protection is in effect.
enum SecurityLevel {
  /// The key (or the data itself) is sealed in **verified** secure hardware —
  /// Apple's Secure Enclave, or an Android Keystore key whose
  /// `KeyInfo.getSecurityLevel()` reports `TRUSTED_ENVIRONMENT`/`STRONGBOX`. A
  /// stolen disk or backup is useless offline: reading the store requires that
  /// specific device.
  hardwareBacked,

  /// The key is held by the platform keystore, but secure-hardware residency
  /// was **not** established — e.g. an Android device whose Keystore falls back
  /// to a software implementation, or an emulator. The key is still
  /// OS-protected, but a stolen disk may be attackable offline; do not assume
  /// hardware isolation.
  softwareBacked,

  /// The key is protected by the OS login (login Keychain, Secret Service,
  /// DPAPI): safe from other local users; against a stolen disk, as strong as
  /// the login password.
  loginBound,
}

/// What a backend can and cannot do. Guard optional operations on these rather
/// than catching an [UnsupportedCapability] after the fact.
final class BackendCapabilities {
  const BackendCapabilities({
    required this.enumeration,
    required this.persistent,
  });

  /// Whether [SecretBackend.readAll] is supported.
  final bool enumeration;

  /// Whether secrets survive process exit (false only for in-memory backends).
  final bool persistent;
}

/// A point-in-time health snapshot for diagnostics UIs.
final class BackendInfo {
  const BackendInfo({
    required this.name,
    required this.available,
    required this.locked,
    required this.capabilities,
    this.level,
    this.detail,
  });

  /// Backing mechanism, e.g. `keychain`, `secret-service`, `encrypted-file`.
  final String name;

  /// Whether the backend can be reached at all.
  final bool available;

  /// Whether it is locked / needs interaction that can't be satisfied.
  final bool locked;

  final BackendCapabilities capabilities;

  /// The offline-attack protection level of the resolved scheme. Always set by
  /// the library's own backends; null only for custom/test backends that
  /// don't declare one.
  final SecurityLevel? level;

  /// Free-form extra detail (e.g. a path or provider name). Never a secret.
  final String? detail;
}

/// Storage of named byte secrets for one service.
abstract interface class SecretBackend {
  /// Static description of what this backend supports.
  BackendCapabilities get capabilities;

  /// The value for [key], or null if absent.
  Future<Uint8List?> read(String key);

  /// Whether [key] exists. (Backends may implement this as a read; an
  /// attributes-only existence query is a recorded follow-up.)
  Future<bool> contains(String key);

  /// Stores [value] under [key], replacing any existing value. [label] is
  /// optional non-secret metadata for keystore UIs.
  Future<void> write(String key, Uint8List value, {String? label});

  /// Removes [key]. Idempotent.
  Future<void> delete(String key);

  /// All entries. Throws [UnsupportedCapability] when
  /// [BackendCapabilities.enumeration] is false.
  Future<Map<String, Uint8List>> readAll();

  /// Health snapshot for diagnostics.
  Future<BackendInfo> describe();
}
