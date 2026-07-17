import 'dart:io';

import 'package:test/test.dart';

/// Guards the invariant that `tool/release.dart` maintains: the two Keybay
/// packages version in lockstep, so the four version references must agree.
///
/// Deliberately self-contained (no `tool/` import) and workspace-guarded so it
/// stays valid inside the published, standalone core package — where the
/// `packages/keybay_cli` sibling is absent, there is nothing to cross-check.
/// The regexes mirror `versionPatterns` in `tool/release.dart`.
final RegExp _version = RegExp(r'^version:[ \t]*(\S+)', multiLine: true);
final RegExp _keybayPin =
    RegExp(r'^[ \t]+keybay:[ \t]*(\d+\.\d+\.\d+\S*)', multiLine: true);
final RegExp _cliConst = RegExp("cliVersion[ \\t]*=[ \\t]*'([^']+)'");

String? _match(RegExp pattern, String path) =>
    pattern.firstMatch(File(path).readAsStringSync())?.group(1);

void main() {
  // Present in the workspace checkout (CI); absent in the published core
  // package, where this whole guard is moot.
  final inWorkspace = File('packages/keybay_cli/pubspec.yaml').existsSync();

  test('the two packages carry one lockstep version across all references', () {
    if (!inWorkspace) {
      markTestSkipped('standalone package: no keybay_cli sibling to check');
      return;
    }
    final references = <String, String?>{
      'core pubspec version': _match(_version, 'pubspec.yaml'),
      'cli pubspec version':
          _match(_version, 'packages/keybay_cli/pubspec.yaml'),
      'cli keybay pin': _match(_keybayPin, 'packages/keybay_cli/pubspec.yaml'),
      'cliVersion constant':
          _match(_cliConst, 'packages/keybay_cli/lib/src/command.dart'),
    };

    for (final entry in references.entries) {
      expect(entry.value, isNotNull, reason: 'could not read ${entry.key}');
    }
    expect(
      references.values.toSet(),
      hasLength(1),
      reason: 'version references drifted: $references — run '
          '`dart run tool/release.dart set <x.y.z>` to synchronize',
    );
  });

  test('both changelogs carry the current version', () {
    if (!inWorkspace) {
      markTestSkipped('standalone package: no keybay_cli sibling to check');
      return;
    }
    final version = _match(_version, 'pubspec.yaml')!;
    final heading =
        RegExp('^##[ \\t]+${RegExp.escape(version)}\\b', multiLine: true);
    expect(
      heading.hasMatch(File('CHANGELOG.md').readAsStringSync()),
      isTrue,
      reason: 'core CHANGELOG.md has no "## $version" section',
    );
    expect(
      heading.hasMatch(
          File('packages/keybay_cli/CHANGELOG.md').readAsStringSync()),
      isTrue,
      reason: 'packages/keybay_cli/CHANGELOG.md has no "## $version" section',
    );
  });
}
