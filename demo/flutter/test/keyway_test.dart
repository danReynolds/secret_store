import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keyway_flutter_demo/main.dart';

void main() {
  testWidgets('receives configuration without rendering the credential', (
    tester,
  ) async {
    final fromKeyway = Platform.environment['KEYWAY_DEMO_INTEGRATION'] == '1';
    final environment = fromKeyway
        ? Platform.environment
        : const {
            'API_BASE_URL': 'https://staging.example.com',
            'FLUTTER_DEMO_API_TOKEN': 'disposable-test-token',
          };
    final token = environment['FLUTTER_DEMO_API_TOKEN'];

    expect(environment['API_BASE_URL'], 'https://staging.example.com');
    expect(
      token,
      isNotEmpty,
      reason: 'run this test through keyway from the demo directory',
    );

    await tester.pumpWidget(KeywayDemoApp(environment: environment));

    expect(find.text('API: https://staging.example.com'), findsOneWidget);
    expect(find.text('API token: available'), findsOneWidget);
    final credentialWasRendered = tester
        .widgetList<Text>(find.byType(Text))
        .any((widget) => widget.data?.contains(token!) ?? false);
    expect(
      credentialWasRendered,
      isFalse,
      reason: 'the credential must never be rendered or printed',
    );
  });
}
