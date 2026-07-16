/// Secret storage for Dart without Flutter.
///
/// See doc/sdk.md for the per-platform protection table and doc/design.md for
/// the full design. The public surface is deliberately minimal — every symbol
/// here is attack surface and compatibility surface:
///
/// - [SecretStorage] — the store. One constructor, one input (`appId`); the
///   library resolves its fixed policy for the current platform. No mechanism,
///   path, or key-home knobs exist.
/// - The typed error taxonomy.
/// - [SecretBackend] / [BackendInfo] / [BackendCapabilities] /
///   [SecurityLevel] — the `describe()` surface, and the interface consumers
///   fake in their own tests via `SecretStorage.withBackend`.
///
/// Everything else (backends, keystore bindings, key sources, the POSIX shim,
/// the subprocess runner) is internal: mechanism is the library's decision.
library;

export 'src/backend.dart'
    show
        BackendCapabilities,
        BackendInfo,
        SecretBackend,
        SecurityLevel,
        StorageScheme;
export 'src/errors.dart'
    show
        AuthenticationFailed,
        ContainerCorrupt,
        ContainerMissing,
        KeyInvalidated,
        KeystoreLocked,
        KeystoreOperationFailed,
        KeystoreUnreachable,
        MigrationRequired,
        SecretStoreException,
        SecureFileError,
        StoreBusy,
        StoreKeyMissing,
        StoreTooLarge,
        UnsupportedCapability,
        WrongStoreKey;
export 'src/secret_storage.dart' show SecretStorage;
