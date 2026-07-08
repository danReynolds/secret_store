/// Platform-keystore secret storage for Dart without Flutter.
///
/// See the README for the threat model and doc/design.md for the
/// full design. The public surface is deliberately small: every symbol here is
/// attack surface and compatibility surface.
library;

// The concrete backends (`KeystoreBackend`, `EncryptedFileBackend`) are
// deliberately NOT exported: which one to use is the library's per-platform
// decision, not the caller's. Compose intent through `SecretStorage`'s
// constructors instead. `SecretBackend` (the interface) is exported for the
// test/custom escape hatch and as the `describe()` surface.
export 'src/backend.dart' show BackendCapabilities, BackendInfo, SecretBackend;
export 'src/errors.dart'
    show
        AuthenticationFailed,
        ContainerCorrupt,
        ContainerMissing,
        KeystoreLocked,
        KeystoreOperationFailed,
        KeystoreUnreachable,
        SecretStoreException,
        StoreKeyMissing,
        UnsupportedCapability,
        WrongStoreKey;
export 'src/ffi/keychain.dart' show MacKeychainApi;
export 'src/ffi/keystore_api.dart' show KeystoreApi, KeystoreProbe;
export 'src/ffi/posix_file.dart' show SecureFileError, SecureFileSystem;
export 'src/ffi/process_runner.dart'
    show ProcessRunResult, ProcessRunner, SystemProcessRunner;
export 'src/ffi/secret_service.dart' show SecretToolApi;
// Only the secure, persistent sources are exported. `InMemoryKeySource`
// (non-persistent) and `FileKeySource` (plaintext key on disk) are internal:
// a caller who needs bring-your-own-key or an on-disk key implements the
// `KeySource` interface directly (with `SecureFileSystem` for file hygiene),
// making the security tradeoff a deliberate choice, not an accidental pick.
export 'src/key_source.dart'
    show
        KeySource,
        KeySourceStatus,
        SystemKeySource,
        generateStoreKey,
        storeKeyLength;
export 'src/tpm_key_source.dart' show TpmKeyBinding, TpmKeySource;
export 'src/secret_storage.dart' show SecretStorage, platformKeystore;
