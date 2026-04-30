import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nasa_apod_app/main.dart';
import 'package:nasa_apod_app/models/apod_entry.dart';
import 'package:nasa_apod_app/models/slideshow_config.dart';
import 'package:nasa_apod_app/providers/app_providers.dart';
import 'package:nasa_apod_app/screens/detail_screen.dart';
import 'package:nasa_apod_app/screens/onboarding_api_key_screen.dart';
import 'package:nasa_apod_app/screens/slideshow_screen.dart';
import 'package:nasa_apod_app/services/cache_service.dart';
import 'package:nasa_apod_app/services/wallpaper_service.dart';

class _RecordingCacheService extends CacheService {
  Set<String>? lastDesiredUrls;

  @override
  Future<void> syncSlideshowWindowUrls(
    Set<String> desiredUrls, {
    String reason = 'slideshow_window',
  }) {
    lastDesiredUrls = desiredUrls;
    return Future.value();
  }
}

/// Basic smoke test to ensure app root renders with provider scope.
void main() {
  testWidgets('app boots', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: NasaApodExplorerApp()));
    expect(find.byType(NasaApodExplorerApp), findsOneWidget);
  });

  testWidgets('detail screen shows fallback when image URL is missing', (
    tester,
  ) async {
    final entry = ApodEntry(
      date: DateTime(2024, 1, 1),
      title: 'Missing image',
      explanation: 'No URL',
      mediaType: 'image',
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: DetailScreen(entry: entry)),
      ),
    );

    expect(find.text('This APOD image is unavailable.'), findsOneWidget);
  });

  testWidgets('onboarding screen disposes cleanly on unmount', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: OnboardingApiKeyScreen())),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('slideshow boots without blocking', (tester) async {
    final cache = _RecordingCacheService();
    final items = [
      ApodEntry(
        date: DateTime(2024, 1, 1),
        title: 'A',
        explanation: 'A',
        mediaType: 'image',
        url: 'https://example.com/a.jpg',
      ),
      ApodEntry(
        date: DateTime(2024, 1, 2),
        title: 'B',
        explanation: 'B',
        mediaType: 'image',
        url: 'https://example.com/b.jpg',
      ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          cacheServiceProvider.overrideWithValue(cache),
          precacheWindowProvider.overrideWith((_) => 5),
          slideshowIntervalProvider.overrideWith((_) => 60),
          slideshowEntriesProvider.overrideWith((_) => items),
        ],
        child: MaterialApp(
          home: SlideshowScreen(
            runDuration: Duration(minutes: 2),
            direction: SlideshowDirection.forward,
            startDate: DateTime(2024, 1, 1),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });

  test('windows wallpaper payload includes selected style', () async {
    const channel = MethodChannel('nasa_apod_app/wallpaper');
    MethodCall? captured;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          captured = call;
          return true;
        });

    final service = WallpaperService();
    final ok = await service.setWindowsWallpaper(
      r'C:\tmp\apod.jpg',
      style: WallpaperFit.stretch,
    );

    expect(ok, isTrue);
    expect(captured?.method, 'setWallpaper');
    expect((captured!.arguments as Map)['path'], r'C:\tmp\apod.jpg');
    expect((captured!.arguments as Map)['style'], 'stretch');

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
}
