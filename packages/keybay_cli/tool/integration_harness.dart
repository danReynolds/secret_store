import 'dart:io';

import 'package:keybay_cli/src/entrypoint.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) {
    stderr.writeln('usage: integration_harness APP_ID KEYBAY_ARGS...');
    exitCode = 2;
    return;
  }
  exitCode = await runKeybay(arguments.sublist(1), appId: arguments.first);
}
