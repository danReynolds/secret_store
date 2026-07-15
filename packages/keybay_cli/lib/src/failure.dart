import 'package:keybay/keybay.dart';

const String recoveryUrl =
    'https://github.com/danReynolds/keybay/blob/main/doc/cli-recovery.md';

final class CliFailure implements Exception {
  CliFailure({required this.exitCode, required List<String> lines})
    : lines = List<String>.unmodifiable(lines);

  final int exitCode;
  final List<String> lines;

  void writeTo(StringSink sink) {
    for (final line in lines) {
      sink.writeln(line);
    }
  }
}

CliFailure failureForSecretStore(SecretStoreException error) {
  return switch (error) {
    KeystoreLocked() => CliFailure(
      exitCode: 69,
      lines: <String>[
        'error: the OS keystore is locked or needs interactive access.',
        'Unlock the login keychain or Secret Service and retry.',
        'Over SSH this is expected: keybay is a dev-machine tool.',
      ],
    ),
    KeystoreUnreachable() => CliFailure(
      exitCode: 69,
      lines: <String>[
        'error: no usable OS keystore is available.',
        'Keybay is a dev-machine tool; in CI, use the CI platform secret store.',
      ],
    ),
    StoreKeyMissing() => CliFailure(
      exitCode: 69,
      lines: <String>[
        'error: the encrypted container exists, but its store key was not returned.',
        'Unlock or reconnect the OS keystore and retry first; some locked Linux '
            'providers report this state as a missing key.',
        'If the key is truly lost, restore the matching key and container pair '
            'or follow the platform recovery procedure before re-provisioning.',
        'Plain keybay set cannot heal an unreadable existing container.',
        'Recovery procedure: $recoveryUrl',
      ],
    ),
    ContainerMissing() => CliFailure(
      exitCode: 69,
      lines: <String>[
        'error: the store key exists, but the encrypted container is missing.',
        'Restore the container, or deliberately re-provision with keybay set.',
      ],
    ),
    WrongStoreKey() => CliFailure(
      exitCode: 69,
      lines: <String>[
        'error: the encrypted container does not match this machine store key.',
        'Restore the matching pair. To abandon it, follow the platform recovery '
            'procedure and preserve or move the old container first.',
        'Recovery procedure: $recoveryUrl',
      ],
    ),
    AuthenticationFailed() || ContainerCorrupt() => CliFailure(
      exitCode: 69,
      lines: <String>[
        'error: the encrypted container is corrupt or failed authentication.',
        'Restore it from backup. To abandon it, follow the platform recovery '
            'procedure before setting replacement values.',
        'Recovery procedure: $recoveryUrl',
      ],
    ),
    MigrationRequired(:final from, :final to) => CliFailure(
      exitCode: 69,
      lines: <String>[
        'error: a store migration from ${from.name} to ${to.name} is required.',
        'Keybay will not migrate implicitly; follow the deliberate platform '
            'migration procedure.',
        'Recovery procedure: $recoveryUrl',
      ],
    ),
    StoreTooLarge() => CliFailure(
      exitCode: 69,
      lines: <String>[
        'error: the value or sealed store exceeds Keybay\'s size limit.',
        'Keybay stores credentials, not large blobs; store a reference instead.',
      ],
    ),
    SecureFileError(:final operation, :final path)
        when operation.startsWith('read(insecure-mode:') =>
      CliFailure(
        exitCode: 69,
        lines: <String>[
          'error: a Keybay store file has unsafe permissions.',
          'Restrict it and retry: chmod 600 -- ${_shellQuote(path)}',
        ],
      ),
    SecureFileError(:final operation, :final path)
        when operation.startsWith('insecure-dir-mode(') =>
      CliFailure(
        exitCode: 69,
        lines: <String>[
          'error: the Keybay store directory has unsafe permissions.',
          'Restrict it and retry: chmod 700 -- ${_shellQuote(path)}',
        ],
      ),
    SecureFileError(:final operation, :final errno) => CliFailure(
      exitCode: 69,
      lines: <String>[
        'error: secure store filesystem operation $operation failed '
            '(errno $errno).',
        'Keep the store on local application-data storage and consult the '
            'platform recovery procedure; Keybay will not weaken locking or '
            'permissions.',
      ],
    ),
    StoreBusy() => CliFailure(
      exitCode: 75,
      lines: <String>[
        'error: another live Keybay writer still holds the store lock.',
        'Retry. If it persists, find the wedged Keybay or library process; '
            'this is not a stale lock file.',
      ],
    ),
    KeyInvalidated() => CliFailure(
      exitCode: 69,
      lines: <String>[
        'error: the hardware-held key for this store is no longer usable.',
        'The store cannot be decrypted; follow the platform recovery procedure '
            'before re-provisioning.',
        'Recovery procedure: $recoveryUrl',
      ],
    ),
    UnsupportedCapability() => CliFailure(
      exitCode: 70,
      lines: <String>[
        'error: the resolved backend lacks a capability required by the CLI.',
        'This is a Keybay bug; report it upstream.',
      ],
    ),
    KeystoreOperationFailed(:final message) => CliFailure(
      exitCode: 69,
      lines: <String>[
        'error: OS keystore operation failed: $message',
        'Run keybay doctor for backend health details.',
      ],
    ),
  };
}

String _shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";
