const int cliKeyMaxLength = 120;

final RegExp _cliKeyPattern = RegExp(
  r'[A-Za-z0-9][A-Za-z0-9._-]*/'
  r'[A-Za-z0-9][A-Za-z0-9._-]*'
  r'(?:/[A-Za-z0-9][A-Za-z0-9._-]*)*',
);

/// Whether [key] is a qualified key accepted by the Keybay CLI.
///
/// The grammar is deliberately narrower than the core library's key grammar:
/// at least two slash-separated segments, each beginning with an ASCII
/// alphanumeric character, and at most [cliKeyMaxLength] characters total.
bool isValidCliKey(String key) {
  if (key.isEmpty || key.length > cliKeyMaxLength) return false;

  final match = _cliKeyPattern.matchAsPrefix(key);
  return match != null && match.end == key.length;
}
