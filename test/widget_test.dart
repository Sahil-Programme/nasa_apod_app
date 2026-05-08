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
import 'package:nasa_apod_app/screens/settings_screen.dart';
import 'package:nasa_apod_app/screens/slideshow_screen.dart';
import 'package:nasa_apod_app/services/cache_service.dart';
import 'package:nasa_apod_app/services/nasa_api_service.dart';
import 'package:nasa_apod_app/services/wallpaper_service.dart';

DateTime _dayOnly(DateTime date) => DateTime(date.year, date.month, date.day);

String _dayKey(DateTime date) =>
    _dayOnly(date).toIso8601String().split('T').first;

class _RecordingCacheService extends CacheService {
  Set<String>? lastDesiredUrls;
  final List<ApodEntry> warmed = <ApodEntry>[];
  ApodEntry? lastHomeEntry;
  int readLastHomeEntryCount = 0;
  int saveLastHomeEntryCount = 0;
  int syncCallCount = 0;

  @override
  Future<void> syncSlideshowWindowUrls(
    Set<String> desiredUrls, {
    String reason = 'slideshow_window',
    Set<String>? pinnedUrls,
  }) {
    syncCallCount++;
    lastDesiredUrls = desiredUrls;
    return Future.value();
  }

  @override
  Future<void> warmEntry(
    ApodEntry entry, {
    String reason = 'entry',
    bool lowInternetUsage = false,
  }) {
    warmed.add(entry);
    return Future.value();
  }

  @override
  Future<ApodEntry?> readLastHomeEntry() {
    readLastHomeEntryCount++;
    return Future.value(lastHomeEntry);
  }

  @override
  Future<void> saveLastHomeEntry(ApodEntry entry) {
    saveLastHomeEntryCount++;
    lastHomeEntry = entry;
    return Future.value();
  }
}

class _GateCacheService extends _RecordingCacheService {
  final Completer<void> syncCompleter = Completer<void>();

  @override
  Future<void> syncSlideshowWindowUrls(
    Set<String> desiredUrls, {
    String reason = 'slideshow_window',
    Set<String>? pinnedUrls,
  }) {
    syncCallCount++;
    lastDesiredUrls = desiredUrls;
    return syncCompleter.future;
  }
}

class _FakeNasaApiService extends NasaApiService {
  _FakeNasaApiService({
    this.today,
    this.todayFuture,
    Map<String, ApodEntry>? byDate,
    Map<String, Future<ApodEntry>>? byDateFutures,
  }) : assert(
         today != null ||
             todayFuture != null ||
             (byDate?.isNotEmpty ?? false) ||
             (byDateFutures?.isNotEmpty ?? false),
       ),
       byDate = byDate ?? <String, ApodEntry>{},
       byDateFutures = byDateFutures ?? <String, Future<ApodEntry>>{};

  final ApodEntry? today;
  final Future<ApodEntry>? todayFuture;
  final Map<String, ApodEntry> byDate;
  final Map<String, Future<ApodEntry>> byDateFutures;
  int rangeFailuresRemaining = 0;
  int todayCallCount = 0;
  int byDateCallCount = 0;
  int rangeCallCount = 0;
  final List<({DateTime start, DateTime end})> rangeRequests = [];

  @override
  Future<ApodEntry> fetchToday(String key) async {
    todayCallCount++;
    final future = todayFuture;
    if (future != null) return future;
    return today!;
  }

  @override
  Future<ApodEntry> fetchByDate(String key, DateTime date) async {
    byDateCallCount++;
    final id = date.toIso8601String().split('T').first;
    final pending = byDateFutures[id];
    if (pending != null) {
      return pending;
    }
    final found = byDate[id];
    if (found == null) {
      throw NasaApiException('No data for date $id');
    }
    return found;
  }

  @override
  Future<List<ApodEntry>> fetchRange(
    String key,
    DateTime start,
    DateTime end,
  ) async {
    rangeCallCount++;
    rangeRequests.add((start: start, end: end));
    if (rangeFailuresRemaining > 0) {
      rangeFailuresRemaining--;
      throw const NasaApiException(
        'Request failed (500).',
        kind: NasaApiFailureKind.server,
      );
    }

    final startDay = DateTime(start.year, start.month, start.day);
    final endDay = DateTime(end.year, end.month, end.day);
    final found = byDate.values.where((entry) {
      final day = DateTime(entry.date.year, entry.date.month, entry.date.day);
      return !day.isBefore(startDay) && !day.isAfter(endDay);
    }).toList()..sort((a, b) => a.date.compareTo(b.date));
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

  testWidgets('detail screen renders inline surface for direct video URLs', (
    tester,
  ) async {
    final entry = ApodEntry(
      date: DateTime(2024, 1, 2),
      title: 'Direct video',
      explanation: 'video',
      mediaType: 'video',
      url: 'https://example.com/demo.mp4',
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: DetailScreen(entry: entry)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byKey(const ValueKey('inline_media_surface')), findsOneWidget);
    expect(find.byKey(const ValueKey('inline_media_controls')), findsOneWidget);
    expect(find.text('Open Media'), findsNothing);
  });

  testWidgets('detail screen keeps fallback for unsupported video provider', (
    tester,
  ) async {
    final entry = ApodEntry(
      date: DateTime(2024, 1, 2),
      title: 'Hosted page',
      explanation: 'video',
      mediaType: 'video',
      url: 'https://example.com/watch?id=123',
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: DetailScreen(entry: entry)),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('inline_media_fallback')), findsOneWidget);
    expect(find.text('Open Media'), findsOneWidget);
  });

  testWidgets('detail screen audio entries show open audio fallback', (
    tester,
  ) async {
    final entry = ApodEntry(
      date: DateTime(2024, 1, 2),
      title: 'Audio',
      explanation: 'audio',
      mediaType: 'audio',
      url: 'https://example.com/audio.mp3',
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: DetailScreen(entry: entry)),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('inline_media_fallback')), findsOneWidget);
    expect(find.text('Open Audio'), findsOneWidget);
  });

  testWidgets('home media panel uses inline surface for direct videos', (
    tester,
  ) async {
    final cache = _RecordingCacheService();
    final entry = ApodEntry(
      date: DateTime(2026, 4, 30),
      title: 'Direct video',
      explanation: 'video',
      mediaType: 'video',
      url: 'https://example.com/preview.mp4',
    );
    final api = _FakeNasaApiService(
      today: entry,
      byDate: {'2026-04-30': entry},
    );

    final container = ProviderContainer(
      overrides: [
        apiKeyProvider.overrideWith((_) => 'k'),
        currentEntryProvider.overrideWith((_) => AsyncData(entry)),
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
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.byKey(const ValueKey('inline_media_surface')), findsOneWidget);
  });

  testWidgets('home inline video preview tap still opens detail screen', (
    tester,
  ) async {
    final cache = _RecordingCacheService();
    final entry = ApodEntry(
      date: DateTime(2026, 4, 30),
      title: 'Tap video',
      explanation: 'video',
      mediaType: 'video',
      url: 'https://example.com/tap.mp4',
    );
    final api = _FakeNasaApiService(
      today: entry,
      byDate: {'2026-04-30': entry},
    );

    final container = ProviderContainer(
      overrides: [
        apiKeyProvider.overrideWith((_) => 'k'),
        currentEntryProvider.overrideWith((_) => AsyncData(entry)),
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
    await tester.pump(const Duration(milliseconds: 120));

    await tester.tap(find.byKey(const ValueKey('inline_media_surface')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    expect(find.byType(DetailScreen), findsOneWidget);
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
          slideshowIntervalProvider.overrideWith((_) => 60),
        ],
        child: MaterialApp(
          home: SlideshowScreen(
            runDuration: Duration(minutes: 2),
            direction: SlideshowDirection.forward,
            startDate: DateTime(2024, 1, 1),
            latestAvailableDate: DateTime(2024, 1, 2),
            initialEntry: items.first,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });

  testWidgets('home startup renders workspace while network is pending', (
    tester,
  ) async {
    final cache = _RecordingCacheService();
    final today = _dayOnly(DateTime.now());
    final todayCompleter = Completer<ApodEntry>();
    final api = _FakeNasaApiService(
      byDateFutures: <String, Future<ApodEntry>>{
        _dayKey(today): todayCompleter.future,
      },
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

    expect(find.byKey(const ValueKey('home_workspace')), findsOneWidget);
    expect(find.text('NASA APOD Explorer'), findsNothing);

    await tester.pump();

    expect(find.byKey(const ValueKey('home_workspace')), findsOneWidget);
    expect(container.read(currentEntryProvider).isLoading, isTrue);
    expect(api.byDateCallCount, 1);
    expect(api.todayCallCount, 0);

    todayCompleter.complete(
      ApodEntry(
        date: today,
        title: 'Today image',
        explanation: 'ok',
        mediaType: 'image',
        url: 'https://example.com/today.jpg',
      ),
    );
    await tester.pump();
  });

  testWidgets('slideshow dialog opens before latest date request completes', (
    tester,
  ) async {
    final cache = _RecordingCacheService();
    final current = ApodEntry(
      date: DateTime(2026, 4, 29),
      title: 'Current image',
      explanation: 'ok',
      mediaType: 'image',
      url: 'https://example.com/current.jpg',
    );
    final todayCompleter = Completer<ApodEntry>();
    final today = _dayOnly(DateTime.now());
    final api = _FakeNasaApiService(
      todayFuture: todayCompleter.future,
      byDate: <String, ApodEntry>{_dayKey(today): current},
    );

    final container = ProviderContainer(
      overrides: [
        apiKeyProvider.overrideWith((_) => 'k'),
        currentEntryProvider.overrideWith((_) => AsyncData(current)),
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

    await tester.tap(find.byIcon(Icons.slideshow_outlined).first);
    await tester.pump();

    expect(find.text('Start Slideshow'), findsOneWidget);
    expect(api.todayCallCount, 0);

    await tester.tap(find.text('Start'));
    await tester.pump();
    expect(api.todayCallCount, 1);

    todayCompleter.complete(current);
    await tester.pump();
  });

  testWidgets('slideshow start navigates from a single resolved entry', (
    tester,
  ) async {
    final cache = _RecordingCacheService();
    final latest = DateTime(2026, 4, 30);
    final entries = <String, ApodEntry>{};
    for (var offset = 0; offset < 80; offset++) {
      final date = latest.subtract(Duration(days: offset));
      final id = date.toIso8601String().split('T').first;
      entries[id] = ApodEntry(
        date: date,
        title: 'Image $offset',
        explanation: 'ok',
        mediaType: 'image',
        url: 'https://example.com/$id.jpg',
      );
    }
    final api = _FakeNasaApiService(
      today: entries['2026-04-30'],
      byDate: entries,
    );

    final container = ProviderContainer(
      overrides: [
        apiKeyProvider.overrideWith((_) => 'k'),
        currentEntryProvider.overrideWith(
          (_) => AsyncData(entries['2026-04-30']),
        ),
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

    await tester.tap(find.byIcon(Icons.slideshow_outlined).first);
    await tester.pump();
    await tester.tap(find.text('Backward'));
    await tester.pump();
    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(SlideshowScreen), findsOneWidget);
    expect(api.rangeCallCount, 0);
    expect(api.byDateCallCount, greaterThan(0));
    expect(container.read(slideshowEntriesProvider).length, 1);
  });

  testWidgets('slideshow skips unavailable dates for first playable slide', (
    tester,
  ) async {
    final cache = _RecordingCacheService();
    final latest = DateTime(2026, 1, 13);
    final entries = <String, ApodEntry>{};
    for (var offset = 0; offset < 6; offset++) {
      final date = latest.subtract(Duration(days: offset));
      final id = date.toIso8601String().split('T').first;
      entries[id] = ApodEntry(
        date: date,
        title: offset == 0 ? 'Selected video' : 'Image $offset',
        explanation: 'ok',
        mediaType: offset == 0 ? 'video' : 'image',
        url: offset == 0
            ? 'https://example.com/video.mp4'
            : 'https://example.com/$id.jpg',
      );
    }
    // Remove one intermediate day entirely so the launcher must skip it.
    entries.remove('2026-01-12');
    final api = _FakeNasaApiService(
      today: entries['2026-01-13'],
      byDate: entries,
    );

    final container = ProviderContainer(
      overrides: [
        apiKeyProvider.overrideWith((_) => 'k'),
        currentEntryProvider.overrideWith(
          (_) => AsyncData(entries['2026-01-13']),
        ),
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

    await tester.tap(find.byIcon(Icons.slideshow_outlined).first);
    await tester.pump();
    await tester.tap(find.text('Backward'));
    await tester.pump();
    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(SlideshowScreen), findsOneWidget);
    expect(api.byDateCallCount, greaterThan(1));
    expect(container.read(slideshowEntriesProvider).first.title, 'Image 2');
  });

  testWidgets('home startup shows cached entry before refresh completes', (
    tester,
  ) async {
    final cache = _RecordingCacheService()
      ..lastHomeEntry = ApodEntry(
        date: DateTime(2026, 4, 29),
        title: 'Cached image',
        explanation: 'cached',
        mediaType: 'image',
        url: 'https://example.com/cached.jpg',
      );
    final fresh = ApodEntry(
      date: DateTime(2026, 4, 30),
      title: 'Fresh image',
      explanation: 'fresh',
      mediaType: 'image',
      url: 'https://example.com/fresh.jpg',
    );
    final today = _dayOnly(DateTime.now());
    final todayCompleter = Completer<ApodEntry>();
    final api = _FakeNasaApiService(
      byDateFutures: <String, Future<ApodEntry>>{
        _dayKey(today): todayCompleter.future,
      },
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

    expect(cache.readLastHomeEntryCount, 1);
    expect(find.text('Cached image'), findsOneWidget);
    expect(api.byDateCallCount, 1);

    todayCompleter.complete(fresh);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Fresh image'), findsOneWidget);
    expect(cache.saveLastHomeEntryCount, 1);
    expect(cache.lastHomeEntry?.title, 'Fresh image');
  });

  testWidgets('home startup loads today image when displayable', (
    tester,
  ) async {
    final cache = _RecordingCacheService();
    final todayDate = _dayOnly(DateTime.now());
    final today = ApodEntry(
      date: todayDate,
      title: 'Today image',
      explanation: 'ok',
      mediaType: 'image',
      url: 'https://example.com/today.jpg',
    );
    final api = _FakeNasaApiService(
      byDate: <String, ApodEntry>{_dayKey(todayDate): today},
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
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      container.read(currentEntryProvider).valueOrNull?.title,
      'Today image',
    );
    expect(api.byDateCallCount, 1);
    expect(api.todayCallCount, 0);
    expect(api.rangeCallCount, 0);
    expect(cache.warmed.length, 1);
    expect(cache.saveLastHomeEntryCount, 1);
  });

  testWidgets('home startup rolls back to yesterday image', (tester) async {
    final cache = _RecordingCacheService();
    final todayDate = _dayOnly(DateTime.now());
    final yesterdayDate = todayDate.subtract(const Duration(days: 1));
    final yesterday = ApodEntry(
      date: yesterdayDate,
      title: 'Yesterday image',
      explanation: 'image',
      mediaType: 'image',
      url: 'https://example.com/yesterday.jpg',
    );
    final api = _FakeNasaApiService(
      byDate: <String, ApodEntry>{_dayKey(yesterdayDate): yesterday},
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
    expect(loaded?.date, yesterdayDate);
    expect(api.todayCallCount, 0);
    expect(api.rangeCallCount, 0);
    expect(api.byDateCallCount, 2);
  });

  testWidgets(
    'home startup shows explicit error when today and yesterday fail',
    (tester) async {
      final cache = _RecordingCacheService();
      final api = _FakeNasaApiService(
        byDate: <String, ApodEntry>{
          '1995-06-16': ApodEntry(
            date: DateTime(1995, 6, 16),
            title: 'Seed',
            explanation: 'seed',
            mediaType: 'image',
            url: 'https://example.com/seed.jpg',
          ),
        },
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
      await tester.pump(const Duration(milliseconds: 120));

      expect(find.textContaining('No data for date'), findsOneWidget);
      expect(container.read(currentEntryProvider).hasError, isTrue);
    },
  );

  testWidgets('wallpaper action is available for image entries', (
    tester,
  ) async {
    final cache = _RecordingCacheService();
    final entry = ApodEntry(
      date: DateTime(2026, 4, 30),
      title: 'Wallpaper image',
      explanation: 'ok',
      mediaType: 'image',
      url: 'https://example.com/wallpaper.jpg',
    );
    final today = _dayOnly(DateTime.now());
    final api = _FakeNasaApiService(
      byDate: <String, ApodEntry>{_dayKey(today): entry},
    );

    final container = ProviderContainer(
      overrides: [
        apiKeyProvider.overrideWith((_) => 'k'),
        currentEntryProvider.overrideWith((_) => AsyncData(entry)),
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
    expect(find.byIcon(Icons.wallpaper_outlined), findsOneWidget);
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
          apiKeyProvider.overrideWith((_) => 'k'),
          nasaApiServiceProvider.overrideWithValue(
            _FakeNasaApiService(
              today: items.last,
              byDate: {'2024-01-01': items.first, '2024-01-02': items.last},
            ),
          ),
          cacheServiceProvider.overrideWithValue(cache),
          slideshowIntervalProvider.overrideWith((_) => 1),
        ],
        child: MaterialApp(
          home: SlideshowScreen(
            runDuration: Duration(minutes: 2),
            direction: SlideshowDirection.backward,
            startDate: DateTime(2024, 1, 2),
            latestAvailableDate: DateTime(2024, 1, 2),
            initialEntry: items.last,
          ),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 300));
    final initialSyncCount = cache.syncCallCount;
    expect(initialSyncCount, greaterThan(0));

    await tester.pump(const Duration(seconds: 2));
    expect(cache.syncCallCount, initialSyncCount);

    cache.syncCompleter.complete();
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(cache.syncCallCount, greaterThan(initialSyncCount));
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

  test('setImageWallpaper on Windows forwards selected style', () async {
    const channel = MethodChannel('nasa_apod_app/wallpaper');
    MethodCall? captured;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          captured = call;
          return true;
        });

    final service = WallpaperService(
      isAndroid: false,
      isWindows: true,
      isIOS: false,
      isMacOS: false,
    );
    final msg = await service.setImageWallpaper(
      r'C:\tmp\framed.png',
      style: WallpaperFit.stretch,
    );

    expect(msg, 'Wallpaper set on Windows (Stretch).');
    expect(captured?.method, 'setWallpaper');
    expect((captured!.arguments as Map)['path'], r'C:\tmp\framed.png');
    expect((captured!.arguments as Map)['style'], 'stretch');

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('setImageWallpaper on Android opens system wallpaper picker', () async {
    const channel = MethodChannel('nasa_apod_app/wallpaper_android');
    MethodCall? captured;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          captured = call;
          if (call.method == 'openSystemWallpaperPicker') return true;
          return null;
        });

    final service = WallpaperService(
      isAndroid: true,
      isWindows: false,
      isIOS: false,
      isMacOS: false,
    );
    final msg = await service.setImageWallpaper(r'C:\tmp\prepared.png');

    expect(msg, 'Opened Android wallpaper picker.');
    expect(captured?.method, 'openSystemWallpaperPicker');
    expect((captured!.arguments as Map)['path'], r'C:\tmp\prepared.png');

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('settings hides pre-cache window control', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: SettingsScreen())),
    );
    expect(find.textContaining('Pre-cache Window'), findsNothing);
  });

  test('cache trim planner evicts oldest keys first', () {
    final keys = CacheService.planTrimKeys(
      entries: [
        (
          key: 'old_a',
          bytes: 220,
          touched: DateTime.fromMillisecondsSinceEpoch(1),
        ),
        (
          key: 'old_b',
          bytes: 220,
          touched: DateTime.fromMillisecondsSinceEpoch(2),
        ),
        (
          key: 'new_c',
          bytes: 100,
          touched: DateTime.fromMillisecondsSinceEpoch(3),
        ),
      ],
      pinnedKeys: const {},
      maxBytes: 500,
      targetBytes: 300,
    );
    expect(keys, {'old_a', 'old_b'});
  });

  test('cache trim planner does nothing under budget', () {
    final keys = CacheService.planTrimKeys(
      entries: [
        (key: 'a', bytes: 100, touched: DateTime.fromMillisecondsSinceEpoch(1)),
        (key: 'b', bytes: 120, touched: DateTime.fromMillisecondsSinceEpoch(2)),
      ],
      pinnedKeys: const {},
      maxBytes: 500,
      targetBytes: 300,
    );
    expect(keys, isEmpty);
  });

  test('cache trim planner keeps pinned keys while enough others exist', () {
    final keys = CacheService.planTrimKeys(
      entries: [
        (
          key: 'old_unpinned',
          bytes: 250,
          touched: DateTime.fromMillisecondsSinceEpoch(1),
        ),
        (
          key: 'new_unpinned',
          bytes: 250,
          touched: DateTime.fromMillisecondsSinceEpoch(2),
        ),
        (
          key: 'pinned',
          bytes: 100,
          touched: DateTime.fromMillisecondsSinceEpoch(3),
        ),
      ],
      pinnedKeys: const {'pinned'},
      maxBytes: 500,
      targetBytes: 300,
    );
    expect(keys.contains('pinned'), isFalse);
    expect(keys, {'old_unpinned', 'new_unpinned'});
  });
}
