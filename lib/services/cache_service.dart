import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/apod_entry.dart';

/// Hybrid cache layer:
/// - metadata via SharedPreferences (keyed by APOD date)
/// - image/thumbnail files via disk cache manager
class CacheService {
  static const _metaPrefix = 'apod_meta_';
  static const _tsPrefix = 'apod_ts_';

  final CacheManager imageCache = DefaultCacheManager();
  final Set<String> _managedSlideshowUrls = <String>{};

  String _mediaUrlForEntry(ApodEntry entry) => entry.shouldRenderAsImage
      ? (entry.bestImageUrl ?? '')
      : (entry.thumbnailUrl ?? '');

  void _log(String message) {
    if (!kDebugMode) return;
    final now = DateTime.now().toIso8601String();
    debugPrint('[CACHE][$now] $message');
  }

  Future<void> _cacheUrl(String url, {required String reason}) async {
    if (url.trim().isEmpty) return;
    final cached = await imageCache.getFileFromCache(url);
    if (cached != null) {
      _log('HIT reason=$reason url=$url');
      return;
    }

    _log('MISS reason=$reason url=$url');
    try {
      await imageCache.downloadFile(url);
      _log('SAVED reason=$reason url=$url');
    } catch (e) {
      _log('ERROR reason=$reason url=$url error=$e');
    }
  }

  Future<void> _purgeUrl(String url, {required String reason}) async {
    if (url.trim().isEmpty) return;
    try {
      await imageCache.removeFile(url);
      _log('PURGED reason=$reason url=$url');
    } catch (e) {
      _log('PURGE_ERROR reason=$reason url=$url error=$e');
    }
  }

  /// Ensures current media (or video thumbnail) is cached and logs status in debug.
  Future<void> warmEntry(ApodEntry entry, {String reason = 'entry'}) async {
    final url = _mediaUrlForEntry(entry);
    if (url.isEmpty) {
      _log('SKIP reason=$reason date=${entry.date.toIso8601String()}');
      return;
    }
    await _cacheUrl(url, reason: reason);
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
    _managedSlideshowUrls.clear();
  }

  /// Keeps a managed slideshow cache set in sync with the desired URL window.
  Future<void> syncSlideshowWindowUrls(
    Set<String> desiredUrls, {
    String reason = 'slideshow_window',
  }) async {
    final desired = desiredUrls
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet();
    final add = desired.difference(_managedSlideshowUrls);
    final purge = _managedSlideshowUrls.difference(desired);

    _log(
      'SYNC reason=$reason keep=${desired.length} add=${add.length} purge=${purge.length}',
    );

    for (final url in add) {
      await _cacheUrl(url, reason: '$reason:add');
    }
    for (final url in purge) {
      await _purgeUrl(url, reason: '$reason:purge');
    }

    _managedSlideshowUrls
      ..clear()
      ..addAll(desired);
  }

  /// Backward-compatible wrapper for older slideshow callsites.
  Future<void> precacheUpcoming(
    List<ApodEntry> items,
    int index,
    int window,
  ) async {
    if (items.isEmpty) return;
    final start = (index - window).clamp(0, items.length - 1);
    final end = (index + window).clamp(0, items.length - 1);
    final urls = <String>{};
    for (var i = start; i <= end; i++) {
      final url = _mediaUrlForEntry(items[i]);
      if (url.isNotEmpty) urls.add(url);
    }
    await syncSlideshowWindowUrls(urls, reason: 'legacy_window');
  }
}
