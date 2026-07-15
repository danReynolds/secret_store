@Tags(<String>['unit'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  final packageDirectory = _packageDirectory();

  test('runtime dependency closure is the vetted set', () {
    final result = Process.runSync('dart', <String>[
      'pub',
      'deps',
      '--json',
    ], workingDirectory: packageDirectory.path);
    if (result.exitCode != 0) {
      fail('`dart pub deps --json` failed: ${result.stderr}');
    }

    final data = jsonDecode(result.stdout as String) as Map<String, dynamic>;
    final packages = (data['packages'] as List).cast<Map<String, dynamic>>();
    final byName = <String, Map<String, dynamic>>{
      for (final package in packages) package['name'] as String: package,
    };
    final root = packages.firstWhere(
      (package) => package['name'] == 'keybay_cli',
    );
    final seeds = (root['directDependencies'] as List).cast<String>();
    expect(seeds, unorderedEquals(<String>['ffi', 'keybay']));

    final closure = <String>{};
    final queue = <String>[...seeds];
    while (queue.isNotEmpty) {
      final name = queue.removeLast();
      if (!closure.add(name)) continue;
      final package = byName[name];
      if (package == null) continue;
      queue.addAll((package['directDependencies'] as List).cast<String>());
    }

    expect(
      closure,
      unorderedEquals(<String>{
        'keybay',
        'cryptography',
        'ffi',
        'collection',
        'crypto',
        'meta',
        'typed_data',
      }),
      reason:
          'runtime dependency closure changed; review the supply chain '
          'before updating this expectation',
    );

    for (final name in closure) {
      final source = byName[name]?['source'];
      if (name == 'keybay') {
        expect(
          source,
          'root',
          reason: 'keybay must resolve from the workspace',
        );
      } else {
        expect(
          source,
          'hosted',
          reason: 'package "$name" must resolve from the hosted registry',
        );
      }
    }
  });

  test('runtime dependencies are exact-pinned without overrides', () {
    final pubspec = File(
      '${packageDirectory.path}/pubspec.yaml',
    ).readAsStringSync();
    expect(
      pubspec,
      contains(RegExp(r'^\s*keybay:\s*0\.1\.0\s*$', multiLine: true)),
    );
    expect(
      pubspec,
      contains(RegExp(r'^\s*ffi:\s*2\.2\.0\s*$', multiLine: true)),
    );
    expect(pubspec, isNot(contains('dependency_overrides')));
    expect(
      File('${packageDirectory.path}/pubspec_overrides.yaml').existsSync(),
      isFalse,
    );
    expect(
      File(
        '${packageDirectory.path}/../../pubspec_overrides.yaml',
      ).existsSync(),
      isFalse,
    );
  });

  test(
    'CLI source contains no network client, file writer, or spawn fallback',
    () {
      final roots = <Directory>[
        Directory('${packageDirectory.path}/lib'),
        Directory('${packageDirectory.path}/bin'),
      ];
      final forbidden = RegExp(
        r'(?:\b(?:Socket|RawSocket|HttpClient|WebSocket|InternetAddress|NetworkInterface|Directory|RandomAccessFile|IOSink|Link)\b|Process\.(?:run|runSync|start)\b|FileMode\.(?:write|append|writeOnly|writeOnlyAppend)\b|\.(?:writeAsBytes|writeAsString|openWrite)(?:Sync)?\s*\()',
      );
      final fileConstructor = RegExp(
        r'\bFile(?:\.(?:fromRawPath|fromUri))?\s*\(',
      );
      var fileConstructorCount = 0;
      var manifestReaderFound = false;
      for (final root in roots) {
        for (final entity in root.listSync(recursive: true)) {
          if (entity is! File || !entity.path.endsWith('.dart')) continue;
          final source = entity.readAsStringSync();
          fileConstructorCount += fileConstructor.allMatches(source).length;
          manifestReaderFound |= source.contains(
            'loadManifest: (path) => readManifest(File(path))',
          );
          expect(
            source,
            isNot(matches(forbidden)),
            reason:
                '${entity.path} introduces a network, plaintext file-write, or '
                'spawn API; SR-2, SR-3, SR-8, and SR-13 require review before '
                'adding that surface',
          );
        }
      }
      expect(
        fileConstructorCount,
        1,
        reason:
            'the only CLI File construction must remain the selected manifest '
            'opened by the bounded readManifest path',
      );
      expect(manifestReaderFound, isTrue);
    },
  );
}

Directory _packageDirectory() {
  final nested = Directory('${Directory.current.path}/packages/keybay_cli');
  return nested.existsSync() ? nested : Directory.current;
}
