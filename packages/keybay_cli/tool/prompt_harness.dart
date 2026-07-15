import 'dart:ffi';
import 'dart:io';

import 'package:keybay_cli/src/secret_input.dart';

typedef _NativeSignal = Pointer<Void> Function(Int32, Pointer<Void>);
typedef _DartSignal = Pointer<Void> Function(int, Pointer<Void>);

Future<void> main(List<String> arguments) async {
  final verifyDispositions = switch (arguments) {
    <String>[] => false,
    <String>['--verify-dispositions'] => true,
    _ => throw ArgumentError('usage: prompt_harness [--verify-dispositions]'),
  };
  final dispositionProbe = verifyDispositions
      ? (_SignalDispositionProbe()..installDistinctBaselines())
      : null;
  final reader = SecretInputReader.system(stdin: stdin, stderr: stderr);
  try {
    final value = await reader.read(key: 'test/prompt', fromStdin: false);
    stdout.writeln('read:${value.length}');
    if (dispositionProbe != null) {
      dispositionProbe.verifyAndRestore();
      stdout.writeln('signals:restored');
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  } on SecretInputException catch (error) {
    stderr.writeln('error: $error');
    exitCode = 2;
  } finally {
    dispositionProbe?.restoreOriginal();
  }
}

/// Gives SIGQUIT and SIGTSTP different pre-prompt dispositions, then proves
/// the prompt guard restored each exact value rather than merely making the
/// process safe enough to exit. This is test-harness-only native inspection.
final class _SignalDispositionProbe {
  static final Pointer<Void> _defaultDisposition = Pointer<Void>.fromAddress(0);
  static final Pointer<Void> _ignoredDisposition = Pointer<Void>.fromAddress(1);

  final _DartSignal _signal = DynamicLibrary.process()
      .lookupFunction<_NativeSignal, _DartSignal>('signal');
  final Map<int, Pointer<Void>> _original = <int, Pointer<Void>>{};
  var _restored = false;

  void installDistinctBaselines() {
    _original[ProcessSignal.sigquit.signalNumber] = _signal(
      ProcessSignal.sigquit.signalNumber,
      _ignoredDisposition,
    );
    _original[ProcessSignal.sigtstp.signalNumber] = _signal(
      ProcessSignal.sigtstp.signalNumber,
      _defaultDisposition,
    );
  }

  void verifyAndRestore() {
    final currentQuit = _signal(
      ProcessSignal.sigquit.signalNumber,
      _ignoredDisposition,
    );
    final currentSuspend = _signal(
      ProcessSignal.sigtstp.signalNumber,
      _ignoredDisposition,
    );
    restoreOriginal();
    if (currentQuit.address != _ignoredDisposition.address ||
        currentSuspend.address != _defaultDisposition.address) {
      throw StateError(
        'prompt signal dispositions were not restored exactly '
        '(SIGQUIT=${currentQuit.address}, SIGTSTP=${currentSuspend.address})',
      );
    }
  }

  void restoreOriginal() {
    if (_restored) return;
    for (final entry in _original.entries) {
      _signal(entry.key, entry.value);
    }
    _restored = true;
  }
}
