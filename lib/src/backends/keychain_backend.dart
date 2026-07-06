/// macOS Keychain backend (RFC 0005 §5/§6 model A): each secret is its own
/// generic-password item. Thin over the [KeychainApi] seam.
library;

import 'dart:typed_data';

import '../backend.dart';
import '../ffi/keychain.dart';

final class KeychainBackend implements SecretBackend {
  /// [api] defaults to the real [MacKeychainApi] (macOS only — constructing it
  /// off macOS throws). Pass a fake in tests.
  KeychainBackend({required this.service, KeychainApi? api})
      : _api = api ?? MacKeychainApi();

  /// The `kSecAttrService` all this backend's items share.
  final String service;
  final KeychainApi _api;

  @override
  BackendCapabilities get capabilities =>
      const BackendCapabilities(enumeration: true, persistent: true);

  @override
  Future<Uint8List?> read(String key) async => _api.get(service, key);

  @override
  Future<bool> contains(String key) async => _api.get(service, key) != null;

  @override
  Future<void> write(String key, Uint8List value, {String? label}) async =>
      _api.set(service, key, value, label: label);

  @override
  Future<void> delete(String key) async => _api.delete(service, key);

  @override
  Future<Map<String, Uint8List>> readAll() async => _api.getAll(service);

  @override
  Future<BackendInfo> describe() async {
    final p = _api.probe(service);
    return BackendInfo(
      name: 'keychain',
      available: p.available,
      locked: p.locked,
      capabilities: capabilities,
      detail: p.detail,
    );
  }
}
