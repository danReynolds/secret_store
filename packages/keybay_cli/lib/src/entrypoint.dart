import 'dart:io';

import 'package:keybay/keybay.dart';

import 'application.dart';
import 'command.dart';
import 'manifest.dart';
import 'process_executor.dart';
import 'secret_input.dart';

Future<int> runKeybay(
  List<String> arguments, {
  String appId = 'keybay-cli',
}) async {
  try {
    final command = parseCommand(arguments);
    final input = SecretInputReader.system(stdin: stdin, stderr: stderr);
    final application = CliApplication(
      loadManifest: (path) => readManifest(File(path)),
      createStorage: () => SecretStorage(appId: appId),
      readSecretValue: input.read,
      commandExecutor: SystemCommandExecutor(stderr: stderr),
      parentEnvironment: Platform.environment,
      stdout: stdout,
      stderr: stderr,
      isCompiled: isCompiledExecutable(),
    );
    return await application.execute(command);
  } on CliUsageException catch (error) {
    stderr.writeln('keybay: $error');
    stderr.writeln('Try keybay --help.');
    return exitUsage;
  } on SecretInputException catch (error) {
    stderr.writeln('error: $error.');
    return exitUsage;
  } on UnsupportedError {
    stderr.writeln('error: keybay supports macOS and Linux desktop only.');
    stderr.writeln('In CI, use the CI platform secret store.');
    return exitUnavailable;
  } on Object {
    stderr.writeln('error: an internal Keybay CLI invariant failed.');
    stderr.writeln('Report this bug upstream.');
    return exitSoftware;
  }
}

bool isCompiledExecutable() {
  final executable = Platform.resolvedExecutable
      .replaceAll('\\', '/')
      .split('/')
      .last
      .toLowerCase();
  return executable != 'dart' &&
      executable != 'dart.exe' &&
      executable != 'dartaotruntime' &&
      executable != 'dartaotruntime.exe';
}
