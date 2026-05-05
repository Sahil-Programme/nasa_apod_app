import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/apod_entry.dart';
import '../services/api_key_service.dart';
import '../services/cache_service.dart';
import '../services/nasa_api_service.dart';
import '../services/wallpaper_service.dart';

/// Service providers (dependency injection boundary).
/// API key secure-storage service.
final apiKeyServiceProvider = Provider((_) => ApiKeyService());

/// NASA APOD network service.
final nasaApiServiceProvider = Provider((_) => NasaApiService());

/// Metadata/media cache service.
final cacheServiceProvider = Provider((_) => CacheService());

/// Platform wallpaper integration service.
final wallpaperServiceProvider = Provider((_) => WallpaperService());

/// App state providers.
/// Persisted API key currently active in memory.
final apiKeyProvider = StateProvider<String?>((_) => null);

/// Slide dwell time in seconds.
final slideshowIntervalProvider = StateProvider<int>((_) => 8);

/// When enabled, UI and cache paths avoid APOD HD image URLs.
final lowInternetUsageModeProvider = StateProvider<bool>((_) => false);

/// Screen state providers.
/// Current APOD entry visible on the home screen.
final currentEntryProvider = StateProvider<AsyncValue<ApodEntry?>>(
  (_) => const AsyncData(null),
);

/// Ordered slideshow item list prepared by the home screen launcher.
final slideshowEntriesProvider = StateProvider<List<ApodEntry>>((_) => []);
