import 'dart:io';

import 'package:flutter/material.dart';

void main() => runApp(KeybayExampleApp(environment: Platform.environment));

class KeybayExampleApp extends StatelessWidget {
  KeybayExampleApp({required Map<String, String> environment, super.key})
    : apiBaseUrl = environment['API_BASE_URL'] ?? '',
      apiToken = environment['FLUTTER_EXAMPLE_API_TOKEN'] ?? '';

  final String apiBaseUrl;
  final String apiToken;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff5d5fef),
      brightness: Brightness.dark,
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: colorScheme, useMaterial3: true),
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Keybay Flutter example',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'This disposable value reached the running app through '
                      'its process environment.',
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 28),
                    _ConfigurationValue(
                      label: 'API base URL',
                      value: apiBaseUrl,
                    ),
                    const SizedBox(height: 16),
                    _ConfigurationValue(
                      label: 'Flutter example API token',
                      value: apiToken.isEmpty ? 'missing' : apiToken,
                      valueKey: const ValueKey('api-token-value'),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Demo only — this app intentionally renders the full '
                      'value. Never use a production credential here.',
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: colorScheme.error),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ConfigurationValue extends StatelessWidget {
  const _ConfigurationValue({
    required this.label,
    required this.value,
    this.valueKey,
  });

  final String label;
  final String value;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            SelectableText(
              value,
              key: valueKey,
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(fontFamily: 'monospace'),
            ),
          ],
        ),
      ),
    );
  }
}
