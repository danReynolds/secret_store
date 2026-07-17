// Release orchestration for the Keybay workspace.
//
// Keybay ships two packages that version in lockstep — the `keybay` core
// library and the `keybay_cli` executable — and publishes them through
// tag-triggered GitHub Actions. Four references must agree on the release
// version:
//
//   pubspec.yaml                              version:     (core)
//   packages/keybay_cli/pubspec.yaml          version:     (cli)
//   packages/keybay_cli/pubspec.yaml          keybay:      (cli's exact core pin)
//   packages/keybay_cli/lib/src/command.dart  cliVersion            (`--version`)
//
// This tool keeps those four in sync and turns "release" into one intentional
// command per target:
//
//   dart run tool/release.dart status                 show every reference
//   dart run tool/release.dart check                  assert they all agree (CI-friendly)
//   dart run tool/release.dart set 0.2.0              write one version to all four
//   dart run tool/release.dart bump patch|minor|major increment the agreed version
//   dart run tool/release.dart publish core|cli|both  sign a tag on HEAD and push it
//
// Options: --dry-run (change and tag nothing), --yes (skip the publish prompt).
//
// `publish` is the only outward-facing verb. It creates a *signed* git tag on
// HEAD and pushes it, which triggers `publish.yml` (core, tag `vX.Y.Z`) or
// `release_cli.yml` (cli, tag `keybay_cli-vX.Y.Z`). It refuses unless every
// reference agrees, the tree is clean, HEAD is contained in `origin/main`, the
// matching CHANGELOG carries the version, and the tag does not already exist.
// `both` tags core first: the CLI pins — and pub.dev requires — an
// already-published core version, so the core release must lead.
library;

import 'dart:io';

// ---------------------------------------------------------------------------
// Pure version logic (no IO; mirrored by test/version_consistency_test.dart).
// ---------------------------------------------------------------------------

/// A semantic-version core, `major.minor.patch` (no pre-release/build suffix —
/// this project's tags are plain triples).
final class Version implements Comparable<Version> {
  const Version(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  static final RegExp _pattern = RegExp(r'^(\d+)\.(\d+)\.(\d+)$');

  factory Version.parse(String value) {
    final match = _pattern.firstMatch(value.trim());
    if (match == null) {
      throw FormatException('expected a major.minor.patch version', value);
    }
    return Version(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }

  /// Returns the version with [part] (`major`/`minor`/`patch`) incremented and
  /// the lesser parts reset.
  Version bump(String part) => switch (part) {
        'major' => Version(major + 1, 0, 0),
        'minor' => Version(major, minor + 1, 0),
        'patch' => Version(major, minor, patch + 1),
        _ => throw FormatException(
            'version part must be major, minor, or patch', part),
      };

  @override
  String toString() => '$major.$minor.$patch';

  @override
  int compareTo(Version other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  @override
  bool operator ==(Object other) =>
      other is Version &&
      other.major == major &&
      other.minor == minor &&
      other.patch == patch;

  @override
  int get hashCode => Object.hash(major, minor, patch);
}

/// The four references that must carry the same release version.
enum VersionField {
  corePubspecVersion,
  cliPubspecVersion,
  cliKeybayPin,
  cliVersionConst,
}

/// Each pattern captures (1) everything up to the value and (2) the value, so a
/// replacement can swap the value while preserving surrounding text. The CLI
/// pin pattern requires a version-shaped value, so it never matches the
/// `keybay: keybay` executable mapping in the same pubspec.
final Map<VersionField, RegExp> versionPatterns = <VersionField, RegExp>{
  VersionField.corePubspecVersion:
      RegExp(r'(^version:[ \t]*)(\S+)', multiLine: true),
  VersionField.cliPubspecVersion:
      RegExp(r'(^version:[ \t]*)(\S+)', multiLine: true),
  VersionField.cliKeybayPin:
      RegExp(r'(^[ \t]+keybay:[ \t]*)(\d+\.\d+\.\d+\S*)', multiLine: true),
  VersionField.cliVersionConst: RegExp("(cliVersion[ \\t]*=[ \\t]*')([^']+)"),
};

const Map<VersionField, String> versionFieldLabels = <VersionField, String>{
  VersionField.corePubspecVersion: 'core pubspec version',
  VersionField.cliPubspecVersion: 'cli pubspec version',
  VersionField.cliKeybayPin: 'cli keybay dependency pin',
  VersionField.cliVersionConst: 'cli cliVersion constant',
};

/// Reads [field] from file [content], or null when the pattern is absent.
String? readVersionField(String content, VersionField field) =>
    versionPatterns[field]!.firstMatch(content)?.group(2);

/// Returns [content] with [field] set to [version], throwing if the field is
/// absent (a signal the file format drifted from what this tool understands).
String setVersionField(String content, VersionField field, String version) {
  final pattern = versionPatterns[field]!;
  if (!pattern.hasMatch(content)) {
    throw FormatException(
        'could not find the ${versionFieldLabels[field]} to update');
  }
  return content.replaceFirstMapped(
      pattern, (match) => '${match.group(1)}$version');
}

/// Whether a Markdown changelog [content] has a `## <version>` section heading.
bool changelogHasEntry(String content, String version) =>
    RegExp('^##[ \\t]+${RegExp.escape(version)}\\b', multiLine: true)
        .hasMatch(content);

/// Inserts a `## <version>` stub before the first existing `## ` heading (or
/// after a leading `# ` title), so a fresh release PR carries a slot to fill.
/// Returns [content] unchanged when the version already has an entry.
String insertChangelogStub(String content, String version) {
  if (changelogHasEntry(content, version)) return content;
  final stub = '## $version\n\n- _Summarize the changes in $version._\n\n';
  final firstEntry = RegExp(r'^## ', multiLine: true).firstMatch(content);
  if (firstEntry != null) {
    return content.replaceRange(firstEntry.start, firstEntry.start, stub);
  }
  final title = RegExp(r'^# .*\n', multiLine: true).firstMatch(content);
  if (title != null) {
    return content.replaceRange(title.end, title.end, '\n$stub');
  }
  return '$stub$content';
}

// ---------------------------------------------------------------------------
// Workspace layout.
// ---------------------------------------------------------------------------

const Map<VersionField, String> _fieldFiles = <VersionField, String>{
  VersionField.corePubspecVersion: 'pubspec.yaml',
  VersionField.cliPubspecVersion: 'packages/keybay_cli/pubspec.yaml',
  VersionField.cliKeybayPin: 'packages/keybay_cli/pubspec.yaml',
  VersionField.cliVersionConst: 'packages/keybay_cli/lib/src/command.dart',
};

const String _coreChangelog = 'CHANGELOG.md';
const String _cliChangelog = 'packages/keybay_cli/CHANGELOG.md';

String _repoRoot() {
  final fromScript =
      File(Platform.script.toFilePath()).parent.parent.path; // tool/ -> root
  if (File('$fromScript/pubspec.yaml').existsSync()) return fromScript;
  if (File('pubspec.yaml').existsSync()) return Directory.current.path;
  _fail('cannot locate the workspace root; run from the repository');
}

Map<VersionField, String> _readAll(String root) {
  final values = <VersionField, String>{};
  for (final field in VersionField.values) {
    final relative = _fieldFiles[field]!;
    final value =
        readVersionField(File('$root/$relative').readAsStringSync(), field);
    if (value == null) {
      _fail('could not read the ${versionFieldLabels[field]} from $relative');
    }
    values[field] = value;
  }
  return values;
}

/// The single agreed version across all references, or a failure listing the
/// drift.
Version _agreedVersion(Map<VersionField, String> values) {
  if (values.values.toSet().length != 1) {
    stderr.writeln('release: version references disagree:');
    for (final entry in values.entries) {
      stderr.writeln(
          '  ${versionFieldLabels[entry.key]!.padRight(26)} ${entry.value}');
    }
    _fail('synchronize them with `set <x.y.z>` or `bump <part>` first');
  }
  return Version.parse(values.values.first);
}

String _changelogState(String root, String relative, String version) =>
    changelogHasEntry(File('$root/$relative').readAsStringSync(), version)
        ? 'present'
        : 'MISSING';

// ---------------------------------------------------------------------------
// Commands.
// ---------------------------------------------------------------------------

void _status(String root) {
  final values = _readAll(root);
  stdout.writeln('Keybay version references:');
  for (final entry in values.entries) {
    stdout.writeln(
        '  ${versionFieldLabels[entry.key]!.padRight(26)} ${entry.value}');
  }
  final distinct = values.values.toSet();
  if (distinct.length == 1) {
    final version = distinct.first;
    stdout.writeln('\nall four agree at $version');
    stdout.writeln(
        '  CHANGELOG.md ## $version:                    ${_changelogState(root, _coreChangelog, version)}');
    stdout.writeln(
        '  packages/keybay_cli/CHANGELOG.md ## $version: ${_changelogState(root, _cliChangelog, version)}');
  } else {
    stdout.writeln('\nreferences DISAGREE (${distinct.length} distinct values) '
        '— run `set` or `bump` to synchronize');
  }
}

void _check(String root) {
  final version = _agreedVersion(_readAll(root));
  stdout.writeln('ok: all four version references agree at $version');
}

void _set(String root, String versionArg, {required bool dryRun}) {
  final version = Version.parse(versionArg).toString(); // validate + normalize
  final changed = <String>[];
  for (final field in VersionField.values) {
    final relative = _fieldFiles[field]!;
    final path = '$root/$relative';
    final before = File(path).readAsStringSync();
    final after = setVersionField(before, field, version);
    if (before != after) {
      if (!dryRun) File(path).writeAsStringSync(after);
      changed.add('$relative (${versionFieldLabels[field]})');
    }
  }
  stdout.writeln(
      '${dryRun ? '(dry-run) would set' : 'set'} all references to $version:');
  if (changed.isEmpty) {
    stdout.writeln('  (already at $version — nothing to change)');
  }
  for (final entry in changed) {
    stdout.writeln('  $entry');
  }
  for (final relative in <String>[_coreChangelog, _cliChangelog]) {
    if (_changelogState(root, relative, version) == 'MISSING') {
      stdout.writeln(
          'note: $relative has no "## $version" section — add release notes '
          'before publishing');
    }
  }
}

void _bump(String root, String part, {required bool dryRun}) {
  final current = _agreedVersion(_readAll(root)); // require agreement first
  final next = current.bump(part);
  stdout.writeln('bump $part: $current -> $next');
  _set(root, next.toString(), dryRun: dryRun);
}

void _publish(String root, String target,
    {required bool dryRun, required bool yes}) {
  if (!const <String>{'core', 'cli', 'both'}.contains(target)) {
    _fail('publish target must be core, cli, or both');
  }
  final version = _agreedVersion(_readAll(root)); // fails closed on drift

  _requireCleanTree(root);
  final head = _gitOut(root, <String>['rev-parse', 'HEAD']);
  _requireOnMain(root, head);

  final plans = <_TagPlan>[
    if (target == 'core' || target == 'both')
      const _TagPlan('keybay', _coreChangelog, 'publish.yml (pub.dev)'),
    if (target == 'cli' || target == 'both')
      const _TagPlan('keybay_cli', _cliChangelog,
          'release_cli.yml (GitHub release + Homebrew + pub.dev)'),
  ];

  for (final plan in plans) {
    final tag = plan.tagFor(version);
    if (_changelogState(root, plan.changelog, '$version') == 'MISSING') {
      _fail('${plan.changelog} has no "## $version" section; write release '
          'notes before releasing');
    }
    if (_tagExists(root, tag)) {
      _fail('tag $tag already exists (locally or on origin)');
    }
  }

  stdout.writeln('release plan for $version at $head:');
  for (final plan in plans) {
    stdout.writeln(
        '  ${plan.package.padRight(11)} tag ${plan.tagFor(version).padRight(22)} -> ${plan.workflow}');
  }
  if (plans.length == 2) {
    stdout.writeln('note: core is tagged first; the CLI publishes to pub.dev '
        'only after the core\n      version it pins is live there.');
  }

  if (dryRun) {
    stdout.writeln('(dry-run) no tags created or pushed');
    return;
  }
  if (!yes &&
      !_confirm('create and push ${plans.length} signed tag(s) to origin?')) {
    _fail('aborted');
  }

  for (final plan in plans) {
    final tag = plan.tagFor(version);
    final tagged = _git(root,
        <String>['tag', '-s', tag, head, '-m', '${plan.package} $version']);
    if (tagged.exitCode != 0) {
      _fail('git tag $tag failed (is commit signing configured?):\n'
          '${_text(tagged.stderr)}');
    }
    final pushed = _git(root, <String>['push', 'origin', tag]);
    if (pushed.exitCode != 0) {
      _fail('git push $tag failed:\n${_text(pushed.stderr)}');
    }
    stdout.writeln('pushed $tag');
  }
  stdout.writeln('\nreleases triggered. Approve the gated environment(s) in '
      'GitHub Actions.\nA brand-new package name needs a one-time manual first '
      'publish — see doc/cli-release.md.');
}

void _releaseCommand(String root, String arg, {required bool dryRun}) {
  final current = _agreedVersion(_readAll(root)); // fails closed on drift
  final next = RegExp(r'^\d+\.\d+\.\d+$').hasMatch(arg)
      ? Version.parse(arg)
      : current.bump(arg);
  final version = next.toString();
  final branch = 'release/v$version';

  if (!dryRun) {
    _requireCleanTree(root);
    final onBranch =
        _gitOut(root, <String>['rev-parse', '--abbrev-ref', 'HEAD']);
    if (onBranch != 'main') {
      _fail('run `release` from an up-to-date main (currently on "$onBranch")');
    }
    if (_git(root, <String>['rev-parse', '--verify', 'refs/heads/$branch'])
            .exitCode ==
        0) {
      _fail('branch $branch already exists');
    }
  }

  stdout.writeln('${dryRun ? '(dry-run) ' : ''}release $current -> $version');
  for (final field in VersionField.values) {
    final path = '$root/${_fieldFiles[field]}';
    final after =
        setVersionField(File(path).readAsStringSync(), field, version);
    if (!dryRun) File(path).writeAsStringSync(after);
  }
  stdout.writeln('  synchronized all four version references to $version');
  for (final relative in <String>[_coreChangelog, _cliChangelog]) {
    final path = '$root/$relative';
    final before = File(path).readAsStringSync();
    final after = insertChangelogStub(before, version);
    if (before != after) {
      if (!dryRun) File(path).writeAsStringSync(after);
      stdout.writeln('  added a "## $version" changelog stub to $relative');
    }
  }

  if (dryRun) {
    stdout.writeln('  would branch $branch, commit, push, and open a PR to '
        'main titled "Release $version"');
    stdout.writeln('(dry-run) nothing written, no branch, no PR');
    return;
  }

  _gitCheck(root, <String>['checkout', '-b', branch], 'create branch');
  _gitCheck(root, <String>['add', '-A'], 'stage changes');
  _gitCheck(root, <String>['commit', '-m', 'Release $version'], 'commit');
  _gitCheck(root, <String>['push', '-u', 'origin', branch], 'push branch');
  final pr = Process.runSync(
      'gh',
      <String>[
        'pr',
        'create',
        '--base',
        'main',
        '--head',
        branch,
        '--title',
        'Release $version',
        '--body',
        _releasePrBody(version),
      ],
      workingDirectory: root);
  if (pr.exitCode != 0) {
    _fail('gh pr create failed (is the GitHub CLI installed and authed?):\n'
        '${_text(pr.stderr)}');
  }
  stdout.writeln(_text(pr.stdout));
  stdout.writeln('\nOpened the release PR. Fill in the "## $version" changelog '
      'notes, then merge — the release-on-merge workflow tags $version and CI '
      'publishes to pub.dev + Homebrew (after you approve the gated '
      'environments).');
}

String _releasePrBody(String version) => '''
Release $version. Version synchronized across both packages by `tool/release.dart`.

Before merging, replace the `## $version` changelog placeholders in
`CHANGELOG.md` and `packages/keybay_cli/CHANGELOG.md` with real notes.

Merging this tags `v$version` and `keybay_cli-v$version` via the
release-on-merge workflow, which triggers `publish.yml` and `release_cli.yml`.
Approve the gated `release` and `pub.dev` environments to publish to pub.dev and
Homebrew.
''';

// ---------------------------------------------------------------------------
// git + terminal helpers.
// ---------------------------------------------------------------------------

final class _TagPlan {
  const _TagPlan(this.package, this.changelog, this.workflow);

  final String package;
  final String changelog;
  final String workflow;

  String tagFor(Version version) =>
      package == 'keybay' ? 'v$version' : '$package-v$version';
}

ProcessResult _git(String root, List<String> args) =>
    Process.runSync('git', args, workingDirectory: root);

String _text(Object? stdio) => stdio is String ? stdio.trim() : '';

String _gitOut(String root, List<String> args) {
  final result = _git(root, args);
  if (result.exitCode != 0) {
    _fail('git ${args.join(' ')} failed: ${_text(result.stderr)}');
  }
  return _text(result.stdout);
}

void _gitCheck(String root, List<String> args, String what) {
  final result = _git(root, args);
  if (result.exitCode != 0) {
    _fail('$what failed (git ${args.first}): ${_text(result.stderr)}');
  }
}

void _requireCleanTree(String root) {
  if (_gitOut(root, <String>['status', '--porcelain']).isNotEmpty) {
    _fail('working tree is not clean; commit or stash before releasing');
  }
}

void _requireOnMain(String root, String head) {
  // The publish workflows require the tag to be an ancestor of origin/main.
  _git(root, <String>['fetch', 'origin', 'main']); // best-effort refresh
  final ancestor =
      _git(root, <String>['merge-base', '--is-ancestor', head, 'origin/main']);
  if (ancestor.exitCode != 0) {
    _fail('HEAD ($head) is not contained in origin/main; release only '
        'reviewed, merged commits');
  }
}

bool _tagExists(String root, String tag) {
  final local =
      _git(root, <String>['rev-parse', '-q', '--verify', 'refs/tags/$tag'])
              .exitCode ==
          0;
  final remote =
      _gitOut(root, <String>['ls-remote', '--tags', 'origin', 'refs/tags/$tag'])
          .isNotEmpty;
  return local || remote;
}

bool _confirm(String prompt) {
  if (!stdin.hasTerminal) {
    _fail('cannot prompt on a non-terminal stdin; re-run with --yes');
  }
  stdout.write('$prompt [y/N] ');
  final line = stdin.readLineSync()?.trim().toLowerCase() ?? '';
  return line == 'y' || line == 'yes';
}

Never _fail(String message) {
  stderr.writeln('release: $message');
  exit(1);
}

// ---------------------------------------------------------------------------
// Entry point.
// ---------------------------------------------------------------------------

const String _usage = '''
Keybay release tool — one version across both packages, tag-triggered publishing.

Usage: dart run tool/release.dart <command> [options]

  status                       Show every version reference and whether they agree.
  check                        Assert all four references agree (exit 1 on drift).
  set <x.y.z>                  Write one version to all four references.
  bump <major|minor|patch>     Increment the agreed version across all references.
  release <part|x.y.z>         bump + changelog stubs + commit + push + open a PR.
                               Merging the PR triggers the release (needs the
                               release-on-merge workflow + RELEASE_TAG_TOKEN).
  publish <core|cli|both>      Sign a tag on HEAD and push it directly (the manual
                               path, e.g. the one-time first-publish bootstrap).

Options:
  --dry-run                    Show what would happen; write nothing, tag nothing.
  --yes, -y                    Skip the publish confirmation prompt.
  --help, -h                   Show this help.

The two packages version in lockstep. `release` is the everyday flow (one command
to a PR, then merge); `publish both` tags core first — the CLI pins, and pub.dev
requires, an already-published core version.
''';

void main(List<String> args) {
  final positional = <String>[];
  var dryRun = false;
  var yes = false;
  for (final arg in args) {
    switch (arg) {
      case '--dry-run':
        dryRun = true;
      case '--yes' || '-y':
        yes = true;
      case '--help' || '-h':
        stdout.write(_usage);
        return;
      default:
        if (arg.startsWith('-')) _fail('unknown option: $arg (try --help)');
        positional.add(arg);
    }
  }
  if (positional.isEmpty) {
    stdout.write(_usage);
    return;
  }

  final root = _repoRoot();
  final rest = positional.sublist(1);
  // A FormatException from the pure version logic (a malformed version, an
  // unknown bump part, a drifted file format) is a user-facing input error, not
  // a crash — surface it as a clean `release:` message rather than a stack trace.
  try {
    switch (positional.first) {
      case 'status':
        _status(root);
      case 'check':
        _check(root);
      case 'set':
        if (rest.length != 1) _fail('usage: set <x.y.z>');
        _set(root, rest.first, dryRun: dryRun);
      case 'bump':
        if (rest.length != 1) _fail('usage: bump <major|minor|patch>');
        _bump(root, rest.first, dryRun: dryRun);
      case 'release':
        if (rest.length != 1) _fail('usage: release <major|minor|patch|x.y.z>');
        _releaseCommand(root, rest.first, dryRun: dryRun);
      case 'publish':
        if (rest.length != 1) _fail('usage: publish <core|cli|both>');
        _publish(root, rest.first, dryRun: dryRun, yes: yes);
      default:
        _fail('unknown command: ${positional.first} (try --help)');
    }
  } on FormatException catch (error) {
    final source = error.source;
    _fail(source == null ? error.message : '${error.message}: $source');
  }
}
