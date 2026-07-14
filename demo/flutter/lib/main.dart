import 'dart:io';

import 'package:flutter/material.dart';

void main() => runApp(KeywayDemoApp(environment: Platform.environment));

class KeywayDemoApp extends StatelessWidget {
  KeywayDemoApp({required Map<String, String> environment, super.key})
      : apiBaseUrl = environment['API_BASE_URL'] ?? '',
        apiTokenAvailable =
            environment['FLUTTER_DEMO_API_TOKEN']?.isNotEmpty ?? false;

  final String apiBaseUrl;
  final bool apiTokenAvailable;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Keyway Flutter demo')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('API: $apiBaseUrl'),
              Text('API token: ${apiTokenAvailable ? 'available' : 'missing'}'),
            ],
          ),
        ),
      ),
    );
  }
}
