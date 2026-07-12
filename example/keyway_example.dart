// A tiny CLI demonstrating the whole public API.
//
//   dart run example/keyway_example.dart
//
// One constructor, one input: your app id. The library resolves the strongest
// scheme this platform offers (see the README table) — on a plain CLI like
// this, an encrypted file whose key lives in the OS keystore. `describe()`
// reports what was resolved.
import 'dart:io';

import 'package:keyway/keyway.dart';

Future<void> main() async {
  final store = SecretStorage(appId: 'com.example.keyway_demo');

  final info = await store.backend.describe();
  stdout.writeln('resolved scheme: ${info.scheme.name} '
      '(level: ${info.level?.name}, detail: ${info.detail})');

  await store.writeString('api_token', 's3cr3t-value', label: 'Demo API token');
  stdout.writeln('read back:    ${await store.readString('api_token')}');
  stdout.writeln('present?      ${await store.containsKey('api_token')}');

  await store.writeString('refresh_token', 'r3fr3sh');
  stdout.writeln('all keys:     ${(await store.readAll()).keys.toList()}');

  // Clean up the demo's entries (the empty store and its key remain — a real
  // app keeps them for its lifetime).
  await store.deleteAll();
  stdout.writeln('after delete: ${await store.readString('api_token')}');
}
