/// Typed error taxonomy (see doc/design.md).
///
/// Every error carries a stable [code] and, where relevant, the *name* of the
/// secret involved — **never a secret value**, and never raw subprocess output.
/// Names are non-secret (they appear in keystore UIs); values never leave the
/// container, the OS keystore, or process memory.
library;

/// Base type for every error this library throws deliberately.
///
/// Sealed so a consumer can exhaustively `switch` on the failure kinds that
/// feed a diagnostics UI (e.g. dune's `doctor`).
sealed class SecretStoreException implements Exception {
  const SecretStoreException(this.code, this.message);

  /// Stable, machine-branchable identifier. Never localized.
  final String code;

  /// Human-readable detail. Contains no secret values.
  final String message;

  @override
  String toString() => '$runtimeType($code): $message';
}

/// The store key exists but the container file is gone (e.g. deleted, or the
/// store dir was partially restored). Recoverable if the file is restored.
final class ContainerMissing extends SecretStoreException {
  const ContainerMissing(this.path)
      : super('container_missing', 'Container file is absent: $path');
  final String path;
}

/// The container file exists but its store key is gone from the keystore
/// (keychain item deleted, keyring reset). **Unrecoverable without a backup of
/// the key** — the ciphertext can no longer be opened.
final class StoreKeyMissing extends SecretStoreException {
  const StoreKeyMissing()
      : super(
            'store_key_missing',
            'Container exists but its store key is absent from the keystore; '
                'the data cannot be decrypted without a backup of the key.');
}

/// The store key (or context salt) does not match this container: the
/// header's key-commitment value disagrees with the one derived from the
/// supplied key. Wrong key, wrong `contextSalt`, or a container sealed under a
/// different key. Detected in constant time *before* decryption, so it is
/// reliably distinguishable from tampering ([AuthenticationFailed]).
final class WrongStoreKey extends SecretStoreException {
  const WrongStoreKey()
      : super(
            'wrong_store_key',
            'The store key or context does not match this container (key '
                'commitment check failed).');
}

/// Decryption failed authentication under a key that passed the commitment
/// check: the ciphertext or authenticated header was modified after sealing —
/// tamper or corruption. (A wrong key or context surfaces as [WrongStoreKey]
/// before decryption is attempted.) The data is not returned — a failed tag
/// never yields partial or empty plaintext.
final class AuthenticationFailed extends SecretStoreException {
  const AuthenticationFailed()
      : super(
            'authentication_failed',
            'Container failed AEAD authentication under a matching key: the '
                'ciphertext or header was modified after sealing.');
}

/// The container bytes are structurally malformed (bad magic/version, or a
/// length field that overruns the buffer). Distinct from
/// [AuthenticationFailed]: this is caught *before* or independent of the AEAD
/// tag, on obviously-not-our-format input.
final class ContainerCorrupt extends SecretStoreException {
  const ContainerCorrupt(String detail)
      : super('container_corrupt', 'Container is malformed: $detail');
}

/// The OS keystore is present but locked / requires user interaction that
/// cannot be satisfied (e.g. a headless SSH session). Retryable once unlocked.
final class KeystoreLocked extends SecretStoreException {
  const KeystoreLocked([String? detail])
      : super('keystore_locked',
            detail ?? 'The OS keystore is locked or requires interaction.');
}

/// No usable keystore provider (no Secret Service, tool missing, or a call
/// timed out). Distinct from [KeystoreLocked]: the store isn't reachable at all.
final class KeystoreUnreachable extends SecretStoreException {
  const KeystoreUnreachable([String? detail])
      : super('keystore_unreachable',
            detail ?? 'No usable OS keystore provider is available.');
}

/// A low-level keystore operation failed in a way that isn't one of the
/// modeled states. Carries a backend-specific [status] (e.g. an `OSStatus`)
/// for diagnostics — never any secret material.
final class KeystoreOperationFailed extends SecretStoreException {
  const KeystoreOperationFailed(String detail, {this.status})
      : super('keystore_operation_failed', detail);
  final int? status;
}

/// The hardware-held key that wraps the store key exists on record but can no
/// longer be used: the wrapped-key blob is present while the keystore key is
/// gone or fails to unwrap it (Android Keystore key evicted by the OS/OEM,
/// data restored onto a different device — hardware keys never leave the
/// original — or a corrupted blob). The store cannot be decrypted; this is
/// surfaced loudly rather than silently starting an empty store. Recovery is
/// re-provisioning: delete the store's data directory and write the secrets
/// again.
final class KeyInvalidated extends SecretStoreException {
  const KeyInvalidated([String? detail])
      : super(
            'key_invalidated',
            detail ??
                'The hardware key wrapping this store\'s key is no longer '
                    'usable; the store cannot be decrypted.');
}

/// The backend does not support the requested capability (e.g. enumeration on
/// a backend that cannot list its items). Guard with `backend.capabilities`
/// first.
final class UnsupportedCapability extends SecretStoreException {
  const UnsupportedCapability(String capability)
      : super('unsupported_capability',
            'This backend does not support: $capability');
}

/// The store for this `appId` was provisioned under a **different scheme** than
/// the one that now resolves, so silently using the current scheme would hide
/// the existing secrets (an empty-looking store) or, worse, resurface stale
/// values from an abandoned store. On macOS this happens when an app gains or
/// loses the Keychain Sharing entitlement between versions (Data Protection
/// keychain ⇄ encrypted file). Rather than switch stores silently, the library
/// throws this so the transition is a deliberate decision. Resolve it by
/// migrating the secrets and then clearing the marker
/// (`~/Library/Application Support/<appId>/.scheme`), or by removing that
/// directory to start fresh under the new scheme.
final class MigrationRequired extends SecretStoreException {
  MigrationRequired({required this.appId, required this.from, required this.to})
      : super(
            'migration_required',
            'store for "$appId" was provisioned as "$from" but "$to" now '
                'resolves; refusing to switch stores silently');

  /// The app id whose store scheme changed.
  final String appId;

  /// The scheme the store was last provisioned under (`native` | `file`).
  final String from;

  /// The scheme that resolves now.
  final String to;
}

/// A write was rejected because the whole sealed store would exceed the
/// container size cap. Raised **before** the existing container is touched, so
/// the prior contents remain intact and readable — an oversized value can
/// never brick the store. Split large blobs, or store a reference instead of
/// the payload.
final class StoreTooLarge extends SecretStoreException {
  StoreTooLarge(this.sealedBytes, this.maxBytes)
      : super('store_too_large',
            'sealed store is $sealedBytes bytes, over the $maxBytes-byte cap');
  final int sealedBytes;
  final int maxBytes;
}
