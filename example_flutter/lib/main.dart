// Minimal host app: shows which storage scheme the resolver picked on this
// platform/build. The real coverage lives in integration_test/.
import 'package:flutter/material.dart';
import 'package:keybay/keybay.dart';

void main() => runApp(const _HarnessApp());

class _HarnessApp extends StatelessWidget {
  const _HarnessApp();

  Future<String> _describe() async {
    final store = SecretStorage(appId: 'com.example.keybayHarness');
    final info = await store.backend.describe();
    return '${info.scheme.name}\nlevel: ${info.level?.name}\n${info.detail ?? ''}';
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('keybay harness')),
        body: Center(
          child: FutureBuilder<String>(
            future: _describe(),
            builder: (context, snap) => Text(
              snap.hasError
                  ? 'resolver error:\n${snap.error}'
                  : (snap.data ?? 'resolving…'),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
