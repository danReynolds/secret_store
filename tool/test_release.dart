import 'dart:io';

import 'release.dart' as release_tool;

void main() {
  if (release_tool.changelogHasEntry(
      '# Changelog\n\n## 1.2.3-beta\n', '1.2.3')) {
    _fail('a prerelease changelog heading satisfied a stable release');
  }
  if (!release_tool.changelogHasEntry('# Changelog\n\n## 1.2.3\n', '1.2.3')) {
    _fail('an exact stable changelog heading was rejected');
  }

  final root = Directory.systemTemp.createTempSync('keybay-release-policy.');
  try {
    final remote = Directory('${root.path}/origin.git')..createSync();
    final checkout = Directory('${root.path}/checkout')..createSync();
    final other = Directory('${root.path}/other');

    _git(root.path, <String>['init', '--bare', remote.path]);
    _git(checkout.path, const <String>['init', '-b', 'main']);
    _git(checkout.path, const <String>['config', 'user.name', 'Release Test']);
    _git(checkout.path,
        const <String>['config', 'user.email', 'release-test@example.invalid']);
    _git(checkout.path, const <String>['config', 'commit.gpgSign', 'false']);
    _git(checkout.path, const <String>['config', 'tag.gpgSign', 'false']);
    _git(checkout.path, <String>['remote', 'add', 'origin', remote.path]);
    _writeFixture(checkout.path);
    _git(checkout.path, const <String>['add', '.']);
    _git(checkout.path, const <String>['commit', '-m', 'release candidate']);
    _git(checkout.path, const <String>['push', '-u', 'origin', 'main']);
    _git(
        remote.path, const <String>['symbolic-ref', 'HEAD', 'refs/heads/main']);

    _expectFailure(
      checkout.path,
      const <String>['publish', 'both', '--dry-run'],
      'publish target must be core or cli',
    );
    _expectSuccess(
      checkout.path,
      const <String>['publish', 'core', '--dry-run'],
      'tag v1.2.3',
    );
    _expectFailure(
      checkout.path,
      const <String>['publish', 'core', '--yes'],
      'release tags require git SSH signing',
    );
    final wrongSigner = '${root.path}/wrong-release-signer';
    _command(root.path, 'ssh-keygen', <String>[
      '-q',
      '-t',
      'ed25519',
      '-N',
      '',
      '-f',
      wrongSigner,
    ]);
    _git(checkout.path, const <String>['config', 'gpg.format', 'ssh']);
    _git(checkout.path,
        <String>['config', 'user.signingKey', '$wrongSigner.pub']);
    _expectFailure(
      checkout.path,
      const <String>['publish', 'core', '--yes'],
      'configured release signer was',
    );
    _expectFailure(
      checkout.path,
      const <String>['publish', 'cli', '--dry-run'],
      'remote core tag v1.2.3 does not exist',
    );

    _git(checkout.path,
        const <String>['tag', '-a', 'v1.2.3', '-m', 'keybay 1.2.3']);
    _git(checkout.path, const <String>['push', 'origin', 'v1.2.3']);

    _git(root.path,
        <String>['clone', '--branch', 'main', remote.path, other.path]);
    _git(other.path, const <String>['config', 'user.name', 'Release Test']);
    _git(other.path,
        const <String>['config', 'user.email', 'release-test@example.invalid']);
    _git(other.path, const <String>['config', 'commit.gpgSign', 'false']);
    _git(other.path, const <String>['config', 'tag.gpgSign', 'false']);
    File('${other.path}/README.md').writeAsStringSync('main advanced\n');
    _git(other.path, const <String>['add', 'README.md']);
    _git(other.path, const <String>['commit', '-m', 'advance main']);
    _git(other.path, const <String>['push', 'origin', 'main']);

    _expectFailure(
      checkout.path,
      const <String>['publish', 'core', '--dry-run'],
      'is not the current origin/main tip',
    );
    _expectSuccess(
      checkout.path,
      const <String>['publish', 'cli', '--dry-run'],
      'tag keybay_cli-v1.2.3',
    );

    File('${checkout.path}/LOCAL.md').writeAsStringSync('different commit\n');
    _git(checkout.path, const <String>['add', 'LOCAL.md']);
    _git(checkout.path, const <String>['commit', '-m', 'different commit']);
    _expectFailure(
      checkout.path,
      const <String>['publish', 'cli', '--dry-run'],
      'is not the v1.2.3 commit',
    );

    stdout.writeln('release policy passed');
  } finally {
    root.deleteSync(recursive: true);
  }
}

void _writeFixture(String root) {
  File('$root/pubspec.yaml').writeAsStringSync('''
name: keybay_release_fixture
publish_to: none
environment:
  sdk: ^3.10.0
''');
  Directory('$root/tool').createSync(recursive: true);
  File('tool/release.dart').copySync('$root/tool/release.dart');
  Directory('$root/packages/keybay').createSync(recursive: true);
  Directory('$root/packages/keybay_cli/lib/src').createSync(recursive: true);
  File('$root/packages/keybay/pubspec.yaml').writeAsStringSync('''
name: keybay
version: 1.2.3
''');
  File('$root/packages/keybay_cli/pubspec.yaml').writeAsStringSync('''
name: keybay_cli
version: 1.2.3
dependencies:
  keybay: 1.2.3
''');
  File('$root/packages/keybay_cli/lib/src/command.dart')
      .writeAsStringSync("const cliVersion = '1.2.3';\n");
  File('$root/packages/keybay/CHANGELOG.md')
      .writeAsStringSync('# Changelog\n\n## 1.2.3\n\n- Test.\n');
  File('$root/packages/keybay_cli/CHANGELOG.md')
      .writeAsStringSync('# Changelog\n\n## 1.2.3\n\n- Test.\n');
}

ProcessResult _release(String root, List<String> arguments) => Process.runSync(
      Platform.resolvedExecutable,
      <String>['$root/tool/release.dart', ...arguments],
      workingDirectory: root,
      environment: <String, String>{
        ...Platform.environment,
        'GIT_CONFIG_GLOBAL': Platform.isWindows ? 'NUL' : '/dev/null',
        'GIT_CONFIG_NOSYSTEM': '1',
      },
    );

void _expectSuccess(String root, List<String> arguments, String expected) {
  final result = _release(root, arguments);
  final output = '${result.stdout}\n${result.stderr}';
  if (result.exitCode != 0 || !output.contains(expected)) {
    _fail(
        '`${arguments.join(' ')}` did not succeed with "$expected":\n$output');
  }
}

void _expectFailure(String root, List<String> arguments, String expected) {
  final result = _release(root, arguments);
  final output = '${result.stdout}\n${result.stderr}';
  if (result.exitCode == 0 || !output.contains(expected)) {
    _fail('`${arguments.join(' ')}` did not fail with "$expected":\n$output');
  }
}

void _git(String root, List<String> arguments) {
  _command(root, 'git', arguments);
}

void _command(String root, String executable, List<String> arguments) {
  final result = Process.runSync(executable, arguments, workingDirectory: root);
  if (result.exitCode != 0) {
    _fail('$executable ${arguments.join(' ')} failed:\n'
        '${result.stdout}\n${result.stderr}');
  }
}

Never _fail(String message) {
  throw StateError(message);
}
