import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:keybay_flutter_example/main.dart';

void main() {
  testWidgets('renders the disposable credential received from the host', (
    tester,
  ) async {
    final fromKeybay =
        Platform.environment['KEYBAY_EXAMPLE_INTEGRATION'] == '1';
    final environment = fromKeybay
        ? Platform.environment
        : const {
            'API_BASE_URL': 'https://staging.example.com',
            'FLUTTER_EXAMPLE_API_TOKEN': 'disposable-test-token',
          };
    final token = environment['FLUTTER_EXAMPLE_API_TOKEN'];

    expect(environment['API_BASE_URL'], 'https://staging.example.com');
    expect(
      token,
      isNotEmpty,
      reason: 'run this test through keybay from the example directory',
    );

    await tester.pumpWidget(KeybayExampleApp(environment: environment));

    expect(find.text('https://staging.example.com'), findsOneWidget);
    expect(find.text(token!), findsOneWidget);
    expect(find.byKey(const ValueKey('api-token-value')), findsOneWidget);
    expect(
      find.textContaining('Never use a production credential'),
      findsOneWidget,
    );
  });
}
