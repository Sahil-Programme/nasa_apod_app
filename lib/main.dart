import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/app_providers.dart';
import 'screens/home_screen.dart';
import 'screens/onboarding_api_key_screen.dart';
import 'ui/app_theme.dart';
import 'widgets/space_loading.dart';

/// Application entrypoint.
///
/// We keep bootstrap intentionally thin and delegate all state orchestration to
/// Riverpod providers so startup logic stays testable and deterministic.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
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

class _NasaApodExplorerAppState extends ConsumerState<NasaApodExplorerApp>
    with WidgetsBindingObserver {
  bool _ready = false;
  static const _devApiKey = String.fromEnvironment('NASA_API_KEY');
  bool? _landscapeOnly;

  bool get _isMobilePlatform =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_syncOrientationPolicy());
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
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    unawaited(_syncOrientationPolicy());
  }

  Future<void> _syncOrientationPolicy() async {
    if (!_isMobilePlatform) return;
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return;
    final display = views.first.display;
    final shortestSide =
        min(display.size.width, display.size.height) / display.devicePixelRatio;
    final wantsLandscapeOnly = shortestSide >= 600;
    if (_landscapeOnly == wantsLandscapeOnly) return;
    _landscapeOnly = wantsLandscapeOnly;

    if (wantsLandscapeOnly) {
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      return;
    }
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NASA APOD Explorer',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: !_ready
          ? const Scaffold(
              body: SpaceLoadingSurface(
                message: 'Preparing mission control...',
                size: SpaceIndicatorSize.small,
              ),
            )
          : ref.watch(apiKeyProvider) == null
          ? const OnboardingApiKeyScreen()
          : const HomeScreen(),
    );
  }
}
