/// Platform-keystore secret storage for Dart without Flutter.
///
/// See the README for the threat model and `dune_cli/doc/rfcs/0005` for the
/// full design. Public surface is deliberately small (RFC §4a): every symbol
/// here is attack surface and compatibility surface.
library;

export 'src/backend.dart' show BackendCapabilities, BackendInfo, SecretBackend;
export 'src/backends/encrypted_file_backend.dart'
    show EncryptedFileBackend, maxContainerBytes;
export 'src/backends/keychain_backend.dart' show KeychainBackend;
export 'src/ffi/keychain.dart' show KeychainApi, KeychainProbe, MacKeychainApi;
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
        UnsupportedCapability;
export 'src/ffi/posix_file.dart' show SecureFileError, SecureFileSystem;
export 'src/key_source.dart'
    show
        FileKeySource,
        InMemoryKeySource,
        KeychainKeySource,
        KeySource,
        KeySourceStatus,
        generateStoreKey,
        storeKeyLength;
export 'src/secret_storage.dart' show SecretStorage;
