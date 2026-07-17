import 'dart:io';
import 'dart:typed_data';

import 'package:keybay/keybay.dart';

import 'command.dart';
import 'environment.dart';
import 'failure.dart';
import 'manifest.dart';

const int exitSuccess = 0;
const int exitUsage = 2;
const int exitUnavailable = 69;
const int exitSoftware = 70;
const int exitTempFail = 75;
const int exitConfig = 78;

typedef ManifestLoader = Future<Manifest> Function(String path);
typedef StorageFactory = SecretStorage Function();
typedef SecretValueReader =
    Future<String> Function({required String key, required bool fromStdin});

abstract interface class CommandExecutor {
  /// Replaces this process with [executable]. [environment] is the resolved
  /// string-level view (parent + manifest) used for the CLI's own lookups
  /// (PATH search); [overlay] is exactly the manifest-named subset the
  /// executor must materialize — every other parent variable passes through
  /// byte-exact from the raw process `environ` (see
  /// [EnvironmentResolution.overlay]).
  Future<int> execute({
    required String executable,
    required List<String> arguments,
    required Map<String, String> environment,
    required Map<String, String> overlay,
  });
}

final class CliApplication {
  CliApplication({
    required this.loadManifest,
    required this.createStorage,
    required this.readSecretValue,
    required this.commandExecutor,
    required Map<String, String> parentEnvironment,
    required this.stdout,
    required this.stderr,
    this.isCompiled = false,
  }) : parentEnvironment = Map<String, String>.unmodifiable(parentEnvironment);

  final ManifestLoader loadManifest;
  final StorageFactory createStorage;
  final SecretValueReader readSecretValue;
  final CommandExecutor commandExecutor;
  final Map<String, String> parentEnvironment;
  final StringSink stdout;
  final StringSink stderr;
  final bool isCompiled;

  SecretStorage? _storage;

  SecretStorage get _requiredStorage => _storage ??= createStorage();

  Future<int> execute(CliCommand command) async {
    try {
      switch (command) {
        case HelpCommand():
          stdout.write(cliHelp);
          return exitSuccess;
        case VersionCommand():
          stdout.writeln(cliVersion);
          return exitSuccess;
        case RunCommand():
          return await _run(command);
        case SetCommand():
          return await _set(command);
        case RemoveCommand():
          return await _remove(command);
        case ListCommand():
          return await _list();
        case DoctorCommand():
          return await _doctor();
      }
    } on ManifestParseException catch (error) {
      stderr.writeln('error: invalid manifest: $error');
      stderr.writeln('Nothing was launched.');
      return exitConfig;
    } on FileSystemException {
      stderr.writeln('error: the manifest could not be read.');
      stderr.writeln('Check that the selected file exists and is readable.');
      stderr.writeln('Nothing was launched.');
      return exitConfig;
    } on StoredValueException catch (error) {
      stderr.writeln('error: $error.');
      stderr.writeln(
        'Store environment values as UTF-8 without NUL, or use the bytes-first '
        'Keybay library API outside the CLI.',
      );
      stderr.writeln('Nothing was launched.');
      return exitConfig;
    } on SecretStoreException catch (error) {
      final failure = failureForSecretStore(error);
      failure.writeTo(stderr);
      return failure.exitCode;
    }
  }

  Future<int> _run(RunCommand command) async {
    final manifest = await loadManifest(command.manifestPath);
    final storedValues = manifestHasReferences(manifest)
        ? await _requiredStorage.readAll()
        : const <String, Uint8List>{};
    final resolution = resolveEnvironment(
      manifest: manifest,
      parentEnvironment: parentEnvironment,
      storedValues: storedValues,
    );
    if (!resolution.isComplete) {
      _writeMissingReferences(command.manifestPath, resolution);
      return exitConfig;
    }

    return commandExecutor.execute(
      executable: command.executable,
      arguments: command.arguments,
      environment: resolution.environment,
      overlay: resolution.overlay,
    );
  }

  Future<int> _set(SetCommand command) async {
    final value = await readSecretValue(
      key: command.key,
      fromStdin: command.readFromStdin,
    );
    await _requiredStorage.writeString(command.key, value);
    if (!command.readFromStdin) stderr.writeln('Stored.');
    return exitSuccess;
  }

  Future<int> _remove(RemoveCommand command) async {
    await _requiredStorage.delete(command.key);
    return exitSuccess;
  }

  Future<int> _list() async {
    final entries = await _requiredStorage.readAll();
    final keys = entries.keys.toList()..sort();
    for (final key in keys) {
      stdout.writeln(key);
    }
    return exitSuccess;
  }

  Future<int> _doctor() async {
    final info = await _requiredStorage.backend.describe();
    stdout.writeln('scheme:   ${_schemeName(info.scheme)}');
    stdout.writeln('level:    ${info.level?.name ?? 'unknown'}');
    stdout.writeln(
      'keystore: ${info.available ? 'reachable' : 'unreachable'}, '
      '${info.locked ? 'locked' : 'unlocked'}',
    );
    final detail = info.detail;
    if (detail != null && detail.isNotEmpty) {
      stdout.writeln('detail:   $detail');
    }
    stdout.writeln(
      isCompiled
          ? 'runtime:  compiled executable (signature not inspected)'
          : 'runtime:  Dart VM (shared VM is the keychain trust unit)',
    );
    stdout.writeln('keybay:   $cliVersion');
    return info.available && !info.locked ? exitSuccess : exitUnavailable;
  }

  void _writeMissingReferences(
    String manifestPath,
    EnvironmentResolution resolution,
  ) {
    final missing = resolution.missingReferenceCount;
    final total = resolution.referenceCount;
    final noun = missing == 1 ? 'reference' : 'references';
    stderr.writeln(
      'error: $missing of $total $noun in $manifestPath '
      '${missing == 1 ? 'is' : 'are'} not set on this machine:',
    );
    stderr.writeln();
    for (final key in resolution.missingKeys) {
      stderr.writeln('  keybay set $key');
    }
    stderr.writeln();
    stderr.writeln('Nothing was launched.');
  }
}

String _schemeName(StorageScheme scheme) => switch (scheme) {
  StorageScheme.nativeItems => 'native items',
  StorageScheme.encryptedFile => 'encrypted file',
};
