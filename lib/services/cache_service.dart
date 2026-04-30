import 'dart:convert';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/apod_entry.dart';

/// Hybrid cache layer:
/// - metadata via SharedPreferences (keyed by APOD date)
/// - image/thumbnail files via disk cache manager
class CacheService {
  static const _metaPrefix = 'apod_meta_';
  static const _tsPrefix = 'apod_ts_';
  static const metadataTtlHours = 24;

  final CacheManager imageCache = DefaultCacheManager();

  /// Reads cached metadata for a given APOD date key if still within TTL.
  Future<ApodEntry?> getByDate(String dateKey) async {
    final prefs = await SharedPreferences.getInstance();
    final ts = prefs.getInt('$_tsPrefix$dateKey');
    if (ts == null) return null;

    final age = DateTime.now().millisecondsSinceEpoch - ts;
    if (age > const Duration(hours: metadataTtlHours).inMilliseconds) {
      return null;
    }

    final raw = prefs.getString('$_metaPrefix$dateKey');
    if (raw == null) return null;
    return ApodEntry.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// Writes APOD metadata and freshness timestamp to local preferences.
  Future<void> saveEntry(ApodEntry entry) async {
    final prefs = await SharedPreferences.getInstance();
    final key = entry.date.toIso8601String().split('T').first;
    await prefs.setString('$_metaPrefix$key', jsonEncode(entry.toJson()));
    await prefs.setInt('$_tsPrefix$key', DateTime.now().millisecondsSinceEpoch);
  }

  /// Clears all APOD metadata and disk-cached media assets.
  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs
        .getKeys()
        .where((k) => k.startsWith(_metaPrefix) || k.startsWith(_tsPrefix))
        .toList();

    for (final k in keys) {
      await prefs.remove(k);
    }

    await imageCache.emptyCache();
  }

  /// Preloads upcoming slideshow assets without blocking UI rendering.
  Future<void> precacheUpcoming(
    List<ApodEntry> items,
    int index,
    int window,
  ) async {
    final end = (index + window).clamp(0, items.length - 1);
    for (var i = index + 1; i <= end; i++) {
      final e = items[i];
      if (e.isImage && e.bestImageUrl != null) {
        imageCache.downloadFile(e.bestImageUrl!).ignore();
      } else if (e.thumbnailUrl != null) {
        // For videos, cache only thumbnail assets, not full media.
        imageCache.downloadFile(e.thumbnailUrl!).ignore();
      }
    }
  }
}
