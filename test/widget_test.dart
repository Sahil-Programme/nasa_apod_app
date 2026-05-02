import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nasa_apod_app/main.dart';
import 'package:nasa_apod_app/models/apod_entry.dart';
import 'package:nasa_apod_app/models/slideshow_config.dart';
import 'package:nasa_apod_app/providers/app_providers.dart';
import 'package:nasa_apod_app/screens/detail_screen.dart';
import 'package:nasa_apod_app/screens/home_screen.dart';
import 'package:nasa_apod_app/screens/onboarding_api_key_screen.dart';
import 'package:nasa_apod_app/screens/slideshow_screen.dart';
import 'package:nasa_apod_app/services/cache_service.dart';
import 'package:nasa_apod_app/services/nasa_api_service.dart';
import 'package:nasa_apod_app/services/wallpaper_service.dart';

class _RecordingCacheService extends CacheService {
  Set<String>? lastDesiredUrls;
  final List<ApodEntry> warmed = <ApodEntry>[];
  int syncCallCount = 0;

  @override
  Future<void> syncSlideshowWindowUrls(
    Set<String> desiredUrls, {
    String reason = 'slideshow_window',
  }) {
    syncCallCount++;
    lastDesiredUrls = desiredUrls;
    return Future.value();
  }

  @override
  Future<void> warmEntry(ApodEntry entry, {String reason = 'entry'}) {
    warmed.add(entry);
    return Future.value();
  }
}

class _GateCacheService extends _RecordingCacheService {
  final Completer<void> syncCompleter = Completer<void>();

  @override
  Future<void> syncSlideshowWindowUrls(
    Set<String> desiredUrls, {
    String reason = 'slideshow_window',
  }) {
    syncCallCount++;
    lastDesiredUrls = desiredUrls;
    return syncCompleter.future;
  }
}

class _FakeNasaApiService extends NasaApiService {
  _FakeNasaApiService({required this.today, Map<String, ApodEntry>? byDate})
    : byDate = byDate ?? <String, ApodEntry>{};

  final ApodEntry today;
  final Map<String, ApodEntry> byDate;

  @override
  Future<ApodEntry> fetchToday(String key) async {
    return today;
  }

  @override
  Future<ApodEntry> fetchByDate(String key, DateTime date) async {
    final id = date.toIso8601String().split('T').first;
    final found = byDate[id];
    if (found == null) {
      throw NasaApiException('missing $id');
    }
    return found;
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

  testWidgets('home startup loads today image when displayable', (
    tester,
  ) async {
    final cache = _RecordingCacheService();
    final today = ApodEntry(
      date: DateTime(2026, 4, 30),
      title: 'Today image',
      explanation: 'ok',
      mediaType: 'image',
      url: 'https://example.com/today.jpg',
    );
    final api = _FakeNasaApiService(today: today);

    final container = ProviderContainer(
      overrides: [
        apiKeyProvider.overrideWith((_) => 'k'),
        cacheServiceProvider.overrideWithValue(cache),
        nasaApiServiceProvider.overrideWithValue(api),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      container.read(currentEntryProvider).valueOrNull?.title,
      'Today image',
    );
    expect(cache.warmed.length, 1);
  });

  testWidgets('home startup rolls back to yesterday image', (tester) async {
    final cache = _RecordingCacheService();
    final today = ApodEntry(
      date: DateTime(2026, 4, 30),
      title: 'Today video',
      explanation: 'video',
      mediaType: 'video',
      url: 'https://youtube.com/watch?v=abc123',
    );
    final yesterday = ApodEntry(
      date: DateTime(2026, 4, 29),
      title: 'Yesterday image',
      explanation: 'image',
      mediaType: 'image',
      url: 'https://example.com/yesterday.jpg',
    );
    final api = _FakeNasaApiService(
      today: today,
      byDate: {'2026-04-29': yesterday},
    );

    final container = ProviderContainer(
      overrides: [
        apiKeyProvider.overrideWith((_) => 'k'),
        cacheServiceProvider.overrideWithValue(cache),
        nasaApiServiceProvider.overrideWithValue(api),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    final loaded = container.read(currentEntryProvider).valueOrNull;
    expect(loaded?.title, 'Yesterday image');
    expect(loaded?.date, DateTime(2026, 4, 29));
  });

  testWidgets('home startup shows explicit error when no image in 7 days', (
    tester,
  ) async {
    final today = ApodEntry(
      date: DateTime(2026, 4, 30),
      title: 'Today video',
      explanation: 'video',
      mediaType: 'video',
      url: 'https://youtube.com/watch?v=abc123',
    );
    final byDate = <String, ApodEntry>{};
    for (var d = 1; d <= 6; d++) {
      final date = today.date.subtract(Duration(days: d));
      final key = date.toIso8601String().split('T').first;
      byDate[key] = ApodEntry(
        date: date,
        title: 'Video $d',
        explanation: 'video',
        mediaType: 'video',
        url: 'https://youtube.com/watch?v=v$d',
      );
    }
    final api = _FakeNasaApiService(today: today, byDate: byDate);

    final container = ProviderContainer(
      overrides: [
        apiKeyProvider.overrideWith((_) => 'k'),
        nasaApiServiceProvider.overrideWithValue(api),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(
      find.textContaining(
        'No displayable APOD image found in the last 7 day(s).',
      ),
      findsOneWidget,
    );
    expect(container.read(currentEntryProvider).hasError, isTrue);
  });

  testWidgets('slideshow stays responsive while cache sync is pending', (
    tester,
  ) async {
    final cache = _GateCacheService();
    final items = [
      ApodEntry(
        date: DateTime(2024, 1, 1),
        title: 'A',
        explanation: 'A',
        mediaType: 'audio',
        url: 'https://example.com/a.mp3',
      ),
      ApodEntry(
        date: DateTime(2024, 1, 2),
        title: 'B',
        explanation: 'B',
        mediaType: 'audio',
        url: 'https://example.com/b.mp3',
      ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          cacheServiceProvider.overrideWithValue(cache),
          precacheWindowProvider.overrideWith((_) => 5),
          slideshowIntervalProvider.overrideWith((_) => 1),
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
    expect(cache.syncCallCount, 1);

    await tester.pump(const Duration(seconds: 2));
    expect(cache.syncCallCount, 1);

    cache.syncCompleter.complete();
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(cache.syncCallCount, greaterThan(1));
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
