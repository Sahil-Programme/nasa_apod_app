import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/app_providers.dart';
import 'screens/home_screen.dart';
import 'screens/onboarding_api_key_screen.dart';
import 'ui/app_theme.dart';

/// Application entrypoint.
///
/// We keep bootstrap intentionally thin and delegate all state orchestration to
/// Riverpod providers so startup logic stays testable and deterministic.
void main() {
  final originalOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    final message = details.exceptionAsString();
    // Filters a known debug-only keyboard assertion seen on desktop startup.
    if (kDebugMode &&
        message.contains('A KeyDownEvent is dispatched') &&
        message.contains('physical key is already pressed')) {
      return;
    }
    if (originalOnError != null) {
      originalOnError(details);
    } else {
      FlutterError.presentError(details);
    }
  };
  runApp(const ProviderScope(child: NasaApodExplorerApp()));
}

/// Root widget that decides whether to show onboarding or main explorer UI.
class NasaApodExplorerApp extends ConsumerStatefulWidget {
  const NasaApodExplorerApp({super.key});

  @override
  ConsumerState<NasaApodExplorerApp> createState() =>
      _NasaApodExplorerAppState();
}

class _NasaApodExplorerAppState extends ConsumerState<NasaApodExplorerApp> {
  bool _ready = false;
  static const _devApiKey = String.fromEnvironment('NASA_API_KEY');

  @override
  void initState() {
    super.initState();
    // Read persisted key once during boot and publish it to app state.
    Future.microtask(() async {
      final storedKey = await ref.read(apiKeyServiceProvider).read();
      // Dev-only override to speed up local debug sessions.
      final key = storedKey ?? (_devApiKey.isEmpty ? null : _devApiKey);
      ref.read(apiKeyProvider.notifier).state = key;
      setState(() => _ready = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NASA APOD Explorer',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: !_ready
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : ref.watch(apiKeyProvider) == null
          ? const OnboardingApiKeyScreen()
          : const HomeScreen(),
    );
  }
}
