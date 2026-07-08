// A tiny CLI demonstrating the front API.
//
//   dart run example/secret_store_example.dart
//
// You express intent; the library picks the strongest backing per platform.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:secret_store/secret_store.dart';

Future<void> main() async {
  // --- The default: the platform's OS keystore, chosen for you --------------
  final store = SecretStorage(service: 'com.example.secret_store_demo');

  await store.writeString('api_token', 's3cr3t-value', label: 'Demo API token');
  stdout.writeln('read back: ${await store.readString('api_token')}');
  stdout.writeln('present?   ${await store.containsKey('api_token')}');
  await store.delete('api_token');
  stdout.writeln('after delete: ${await store.readString('api_token')}');

  // --- Encrypted file: one wrapped key + a container ------------------------
  // For headless deployments, one backup unit, or many secrets. In production
  // the key comes from `SystemKeySource` (OS keystore) or `TpmKeySource`
  // (hardware-bound, headless). Any custom source is a KeySource you implement
  // — shown here with a throwaway in-memory one so the demo stays
  // self-contained and idempotent (nothing persists, nothing hits a keystore).
  final dir = Directory.systemTemp.createTempSync('secret_store_demo_');
  try {
    final fileStore = SecretStorage.encryptedFile(
      path: '${dir.path}/secrets.enc',
      keySource: _EphemeralKeySource(),
      contextSalt: utf8.encode('demo-profile-uuid'),
    );
    await fileStore.writeString('db_key', 'the spice must flow');
    stdout.writeln('container read: ${await fileStore.readString('db_key')}');
    stdout.writeln('container file is ciphertext on disk at ${dir.path}');
  } finally {
    dir.deleteSync(recursive: true);
  }
}

/// A minimal in-memory [KeySource] — the whole extension point is these four
/// methods. A real one would fetch the key from a KMS, a password prompt, an
/// orchestrator-injected env var, etc.
final class _EphemeralKeySource implements KeySource {
  Uint8List? _key;
  @override
  Future<Uint8List?> read() async => _key;
  @override
  Future<Uint8List> create() async => _key = generateStoreKey();
  @override
  Future<void> delete() async => _key = null;
  @override
  Future<KeySourceStatus> describe() async => KeySourceStatus(
      name: 'ephemeral', present: _key != null, available: true);
}
