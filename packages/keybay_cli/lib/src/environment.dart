import 'dart:convert';
import 'dart:typed_data';

import 'manifest.dart';

final class StoredValueException implements Exception {
  const StoredValueException(this.key, this.reason);

  final String key;
  final String reason;

  @override
  String toString() => 'stored value for $key $reason';
}

final class EnvironmentResolution {
  EnvironmentResolution({
    required Map<String, String> environment,
    required List<String> missingKeys,
    required this.referenceCount,
    required this.missingReferenceCount,
  }) : environment = Map<String, String>.unmodifiable(environment),
       missingKeys = List<String>.unmodifiable(missingKeys);

  final Map<String, String> environment;
  final List<String> missingKeys;
  final int referenceCount;
  final int missingReferenceCount;

  bool get isComplete => missingKeys.isEmpty;
}

bool manifestHasReferences(Manifest manifest) =>
    manifest.values.values.any((value) => value is SecretManifestValue);

/// Overlays the manifest onto [parentEnvironment] without mutating it.
///
/// Only referenced stored values are decoded. Unreferenced entries may be
/// binary because the underlying library is bytes-first; they are outside the
/// environment-shaped CLI contract.
EnvironmentResolution resolveEnvironment({
  required Manifest manifest,
  required Map<String, String> parentEnvironment,
  required Map<String, Uint8List> storedValues,
}) {
  final environment = <String, String>{...parentEnvironment};
  final missingKeys = <String>[];
  final seenMissingKeys = <String>{};
  var referenceCount = 0;
  var missingReferenceCount = 0;

  for (final entry in manifest.values.entries) {
    switch (entry.value) {
      case LiteralManifestValue(:final value):
        environment[entry.key] = value;
      case SecretManifestValue(:final key):
        referenceCount++;
        final bytes = storedValues[key];
        if (bytes == null) {
          missingReferenceCount++;
          if (seenMissingKeys.add(key)) missingKeys.add(key);
          continue;
        }
        environment[entry.key] = _decodeStoredValue(key, bytes);
    }
  }

  return EnvironmentResolution(
    environment: environment,
    missingKeys: missingKeys,
    referenceCount: referenceCount,
    missingReferenceCount: missingReferenceCount,
  );
}

String _decodeStoredValue(String key, Uint8List bytes) {
  late final String value;
  try {
    value = utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    throw StoredValueException(key, 'is not valid UTF-8');
  }
  if (value.contains('\u0000')) {
    throw StoredValueException(key, 'contains a NUL character');
  }
  return value;
}
