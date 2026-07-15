import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'key.dart';

const int manifestMaxBytes = 1024 * 1024;
const int manifestLineMaxBytes = 64 * 1024;

sealed class ManifestValue {
  const ManifestValue();
}

final class LiteralManifestValue extends ManifestValue {
  const LiteralManifestValue(this.value);

  final String value;
}

final class SecretManifestValue extends ManifestValue {
  const SecretManifestValue(this.key);

  final String key;
}

final class Manifest {
  Manifest(Map<String, ManifestValue> values)
    : values = Map<String, ManifestValue>.unmodifiable(values);

  final Map<String, ManifestValue> values;
}

/// A safe manifest diagnostic.
///
/// It intentionally stores no offending bytes or source line: mixed
/// manifests may contain plaintext secrets even when malformed.
final class ManifestParseException implements Exception {
  const ManifestParseException(this.message, {this.line});

  final String message;
  final int? line;

  @override
  String toString() {
    final line = this.line;
    return line == null ? message : 'line $line: $message';
  }
}

final RegExp _environmentNamePattern = RegExp(r'[A-Za-z_][A-Za-z0-9_]*');

/// Reads [file] once, bounded to one byte beyond the accepted manifest size.
Future<Manifest> readManifest(File file) async {
  final handle = await file.open();
  try {
    final bytes = BytesBuilder(copy: false);
    var remaining = manifestMaxBytes + 1;
    while (remaining > 0) {
      final chunk = await handle.read(
        remaining < manifestLineMaxBytes ? remaining : manifestLineMaxBytes,
      );
      if (chunk.isEmpty) break;
      bytes.add(chunk);
      remaining -= chunk.length;
    }
    return parseManifestBytes(bytes.takeBytes());
  } finally {
    await handle.close();
  }
}

/// Parses arbitrary bytes as a Keybay manifest or throws a typed, non-echoing
/// [ManifestParseException].
Manifest parseManifestBytes(List<int> source) {
  if (source.length > manifestMaxBytes) {
    throw const ManifestParseException('manifest exceeds the 1 MiB limit');
  }
  if (source.contains(0)) {
    throw const ManifestParseException('manifest contains a NUL byte');
  }

  final bytes = _withoutLeadingBom(source);
  _checkLineLengths(bytes);
  late final String text;
  try {
    text = utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    throw const ManifestParseException('manifest is not valid UTF-8');
  }

  final values = <String, ManifestValue>{};
  final lines = text.split('\n');
  for (var index = 0; index < lines.length; index++) {
    final lineNumber = index + 1;
    var line = lines[index];
    final endedByLf = index < lines.length - 1;
    if (endedByLf && line.endsWith('\r')) {
      line = line.substring(0, line.length - 1);
    }
    if (line.contains('\r')) {
      throw ManifestParseException(
        'manifest lines must use LF or CRLF endings',
        line: lineNumber,
      );
    }

    final contentStart = _skipAsciiSpaceAndTab(line, 0);
    if (contentStart == line.length || line.codeUnitAt(contentStart) == 0x23) {
      continue;
    }

    final equals = line.indexOf('=');
    if (equals <= 0) {
      throw ManifestParseException('expected NAME=VALUE', line: lineNumber);
    }

    final name = line.substring(0, equals);
    final nameMatch = _environmentNamePattern.matchAsPrefix(name);
    if (nameMatch == null || nameMatch.end != name.length) {
      throw ManifestParseException(
        'environment name must match [A-Za-z_][A-Za-z0-9_]*',
        line: lineNumber,
      );
    }
    if (values.containsKey(name)) {
      throw ManifestParseException(
        'duplicate environment name',
        line: lineNumber,
      );
    }

    final rawValue = line.substring(equals + 1);
    final value = _trimAsciiSpaceAndTab(rawValue);
    if (value.startsWith('kb://')) {
      final key = value.substring('kb://'.length);
      if (!isValidCliKey(key)) {
        throw ManifestParseException(
          'reference must look like '
          'kb://acme-payments/openai-api-key and be at most '
          '$cliKeyMaxLength key characters',
          line: lineNumber,
        );
      }
      values[name] = SecretManifestValue(key);
    } else {
      values[name] = LiteralManifestValue(value);
    }
  }

  return Manifest(values);
}

void _checkLineLengths(List<int> source) {
  var lineStart = 0;
  var lineNumber = 1;
  for (var index = 0; index < source.length; index++) {
    if (source[index] != 0x0a) continue;
    final lineEnd = index > lineStart && source[index - 1] == 0x0d
        ? index - 1
        : index;
    _requireLineWithinLimit(lineEnd - lineStart, lineNumber);
    lineStart = index + 1;
    lineNumber++;
  }
  _requireLineWithinLimit(source.length - lineStart, lineNumber);
}

void _requireLineWithinLimit(int length, int lineNumber) {
  if (length > manifestLineMaxBytes) {
    throw ManifestParseException(
      'line exceeds the 64 KiB limit',
      line: lineNumber,
    );
  }
}

Uint8List _withoutLeadingBom(List<int> source) {
  const bom = <int>[0xef, 0xbb, 0xbf];
  final hasBom =
      source.length >= bom.length &&
      source[0] == bom[0] &&
      source[1] == bom[1] &&
      source[2] == bom[2];
  final hasSecondBom =
      hasBom &&
      source.length >= bom.length * 2 &&
      source[3] == bom[0] &&
      source[4] == bom[1] &&
      source[5] == bom[2];
  if (hasSecondBom) {
    throw const ManifestParseException(
      'manifest has more than one leading UTF-8 BOM',
    );
  }
  return Uint8List.fromList(hasBom ? source.sublist(bom.length) : source);
}

int _skipAsciiSpaceAndTab(String value, int start) {
  var index = start;
  while (index < value.length) {
    final unit = value.codeUnitAt(index);
    if (unit != 0x20 && unit != 0x09) break;
    index++;
  }
  return index;
}

String _trimAsciiSpaceAndTab(String value) {
  final start = _skipAsciiSpaceAndTab(value, 0);
  var end = value.length;
  while (end > start) {
    final unit = value.codeUnitAt(end - 1);
    if (unit != 0x20 && unit != 0x09) break;
    end--;
  }
  return value.substring(start, end);
}
