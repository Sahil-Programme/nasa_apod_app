import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/apod_entry.dart';

class CacheDebugSnapshot {
  const CacheDebugSnapshot({
    required this.currentBytes,
    required this.appCacheBytes,
    required this.maxBytes,
    required this.isTrimming,
    this.lastTrimAt,
    this.lastTrimRemovedBytes = 0,
    this.lastTrimRemovedCount = 0,
  });

  final int currentBytes;
  final int appCacheBytes;
  final int maxBytes;
  final bool isTrimming;
  final DateTime? lastTrimAt;
  final int lastTrimRemovedBytes;
  final int lastTrimRemovedCount;

  CacheDebugSnapshot copyWith({
    int? currentBytes,
    int? appCacheBytes,
    int? maxBytes,
    bool? isTrimming,
    DateTime? lastTrimAt,
    int? lastTrimRemovedBytes,
    int? lastTrimRemovedCount,
  }) {
    return CacheDebugSnapshot(
      currentBytes: currentBytes ?? this.currentBytes,
      appCacheBytes: appCacheBytes ?? this.appCacheBytes,
      maxBytes: maxBytes ?? this.maxBytes,
      isTrimming: isTrimming ?? this.isTrimming,
      lastTrimAt: lastTrimAt ?? this.lastTrimAt,
      lastTrimRemovedBytes: lastTrimRemovedBytes ?? this.lastTrimRemovedBytes,
      lastTrimRemovedCount: lastTrimRemovedCount ?? this.lastTrimRemovedCount,
    );
  }
}

/// Hybrid cache layer:
/// - metadata via SharedPreferences (keyed by APOD date)
/// - image/thumbnail files via disk cache manager
class CacheService {
  static const _metaPrefix = 'apod_meta_';
  static const _tsPrefix = 'apod_ts_';
  static const _lastHomeEntryKey = 'apod_last_home_entry';
  static const int _maxCacheBytes = 300 * 1024 * 1024;
  static const int _trimTargetBytes = 200 * 1024 * 1024;
  static const Duration _trimMinInterval = Duration(seconds: 45);

  final CacheManager imageCache = DefaultCacheManager();
  final Set<String> _managedSlideshowUrls = <String>{};
  final ValueNotifier<CacheDebugSnapshot> _debugSnapshot = ValueNotifier(
    const CacheDebugSnapshot(
      currentBytes: 0,
      appCacheBytes: 0,
      maxBytes: _maxCacheBytes,
      isTrimming: false,
    ),
  );
  Future<void>? _budgetTrimTask;
  DateTime _lastBudgetTrimAt = DateTime.fromMillisecondsSinceEpoch(0);

  ValueListenable<CacheDebugSnapshot> get debugSnapshot => _debugSnapshot;

  String _mediaUrlForEntry(ApodEntry entry, {required bool lowInternetUsage}) =>
      entry.shouldRenderAsImage
      ? (entry.imageUrlFor(lowInternetUsage: lowInternetUsage) ?? '')
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

  void _publishDebug({
    int? currentBytes,
    int? appCacheBytes,
    bool? isTrimming,
    DateTime? lastTrimAt,
    int? lastTrimRemovedBytes,
    int? lastTrimRemovedCount,
  }) {
    _debugSnapshot.value = _debugSnapshot.value.copyWith(
      currentBytes: currentBytes,
      appCacheBytes: appCacheBytes,
      isTrimming: isTrimming,
      lastTrimAt: lastTrimAt,
      lastTrimRemovedBytes: lastTrimRemovedBytes,
      lastTrimRemovedCount: lastTrimRemovedCount,
      maxBytes: _maxCacheBytes,
    );
  }

  Future<List<({String key, int bytes, DateTime touched})>>
  _readCacheEntries() async {
    final repo = imageCache.config.repo;
    final objects = await repo.getAllObjects();
    final entries = <({String key, int bytes, DateTime touched})>[];

    for (final object in objects) {
      final key = object.key.trim();
      if (key.isEmpty) continue;
      var bytes = max(0, object.length ?? 0);
      if (bytes == 0) {
        final file = await imageCache.config.fileSystem.createFile(
          object.relativePath,
        );
        try {
          if (await file.exists()) {
            bytes = await file.length();
          }
        } catch (_) {
          bytes = 0;
        }
      }
      entries.add((
        key: key,
        bytes: max(0, bytes),
        touched: object.touched ?? DateTime.fromMillisecondsSinceEpoch(0),
      ));
    }
    return entries;
  }

  Future<void> refreshDebugCacheSize() async {
    try {
      final entries = await _readCacheEntries();
      final managerBytes = entries.fold<int>(0, (sum, e) => sum + e.bytes);
      final appBytes = await _readAppCacheBytes();
      _publishDebug(currentBytes: managerBytes, appCacheBytes: appBytes);
    } catch (_) {
      // Keep the slideshow debug overlay resilient on metadata failures.
    }
  }

  Future<int> _readAppCacheBytes() async {
    int total = 0;
    try {
      final dir = await getTemporaryDirectory();
      if (!await dir.exists()) return 0;
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        try {
          total += await entity.length();
        } catch (_) {
          // Ignore individual file stat errors.
        }
      }
    } catch (_) {
      return 0;
    }
    return max(0, total);
  }

  Future<void> _enforceAppCacheBudget() async {
    var appBytes = await _readAppCacheBytes();
    _publishDebug(appCacheBytes: appBytes);
    if (appBytes <= _maxCacheBytes) return;

    // First clear managed image cache (fast, safe for our app state).
    await imageCache.emptyCache();
    _managedSlideshowUrls.clear();
    appBytes = await _readAppCacheBytes();
    _publishDebug(currentBytes: 0, appCacheBytes: appBytes);
    if (appBytes > _maxCacheBytes) {
      _log(
        'APP_CACHE_OVER_BUDGET bytes=$appBytes max=$_maxCacheBytes (skipped non-managed temp-file deletion)',
      );
    }
  }

  /// Ensures current media (or video thumbnail) is cached and logs status in debug.
  Future<void> warmEntry(
    ApodEntry entry, {
    String reason = 'entry',
    bool lowInternetUsage = false,
  }) async {
    final url = _mediaUrlForEntry(entry, lowInternetUsage: lowInternetUsage);
    if (url.isEmpty) {
      _log('SKIP reason=$reason date=${entry.date.toIso8601String()}');
      return;
    }
    await _cacheUrl(url, reason: reason);
    await _enforceCacheBudget(reason: reason);
    await refreshDebugCacheSize();
  }

  /// Returns the last APOD entry shown on the home screen, if one was saved.
  Future<ApodEntry?> readLastHomeEntry() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_lastHomeEntryKey);
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return ApodEntry.fromJson(decoded);
      }
    } catch (e) {
      _log('LAST_HOME_READ_ERROR error=$e');
    }
    return null;
  }

  /// Saves the most recent startup APOD metadata for a faster next launch.
  Future<void> saveLastHomeEntry(ApodEntry entry) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastHomeEntryKey, jsonEncode(entry.toJson()));
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
    await prefs.remove(_lastHomeEntryKey);

    await imageCache.emptyCache();
    _managedSlideshowUrls.clear();
    _budgetTrimTask = null;
    _lastBudgetTrimAt = DateTime.fromMillisecondsSinceEpoch(0);
    _publishDebug(
      currentBytes: 0,
      appCacheBytes: 0,
      isTrimming: false,
      lastTrimAt: DateTime.now(),
      lastTrimRemovedBytes: 0,
      lastTrimRemovedCount: 0,
    );
  }

  /// Keeps a managed slideshow cache set in sync with the desired URL window.
  Future<void> syncSlideshowWindowUrls(
    Set<String> desiredUrls, {
    String reason = 'slideshow_window',
    Set<String>? pinnedUrls,
  }) async {
    final desired = desiredUrls
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet();
    final pinned = (pinnedUrls ?? desired)
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet();
    final add = desired.difference(_managedSlideshowUrls);
    final purge = _managedSlideshowUrls.difference(desired);

    _log(
      'SYNC reason=$reason keep=${desired.length} add=${add.length} purge=${purge.length}',
    );

    // Sequential caching avoids burst parallel downloads that can jank slideshow playback.
    for (final url in add) {
      await _cacheUrl(url, reason: '$reason:add');
    }
    for (final url in purge) {
      await _purgeUrl(url, reason: '$reason:purge');
    }

    _managedSlideshowUrls
      ..clear()
      ..addAll(desired);
    await _enforceCacheBudget(reason: reason, pinnedUrls: pinned);
    await refreshDebugCacheSize();
  }

  /// Backward-compatible wrapper for older slideshow callsites.
  Future<void> precacheUpcoming(
    List<ApodEntry> items,
    int index,
    int window, {
    bool lowInternetUsage = false,
  }) async {
    if (items.isEmpty) return;
    final start = (index - window).clamp(0, items.length - 1);
    final end = (index + window).clamp(0, items.length - 1);
    final urls = <String>{};
    for (var i = start; i <= end; i++) {
      final url = _mediaUrlForEntry(
        items[i],
        lowInternetUsage: lowInternetUsage,
      );
      if (url.isNotEmpty) urls.add(url);
    }
    await syncSlideshowWindowUrls(urls, reason: 'legacy_window');
  }

  Future<void> _enforceCacheBudget({
    required String reason,
    Set<String> pinnedUrls = const <String>{},
  }) async {
    if (_budgetTrimTask != null) {
      await _budgetTrimTask;
      return;
    }

    final now = DateTime.now();
    if (now.difference(_lastBudgetTrimAt) < _trimMinInterval) return;
    _lastBudgetTrimAt = now;

    final task = _runBudgetTrim(reason: reason, pinnedUrls: pinnedUrls);
    _budgetTrimTask = task;
    try {
      await task;
    } finally {
      _budgetTrimTask = null;
    }
  }

  Future<void> _runBudgetTrim({
    required String reason,
    required Set<String> pinnedUrls,
  }) async {
    _publishDebug(isTrimming: true);
    try {
      final entries = await _readCacheEntries();
      final beforeBytes = entries.fold<int>(0, (sum, e) => sum + e.bytes);
      _publishDebug(currentBytes: beforeBytes);
      if (beforeBytes <= _maxCacheBytes) {
        await _enforceAppCacheBudget();
        return;
      }

      final keysToTrim = planTrimKeys(
        entries: entries,
        pinnedKeys: pinnedUrls,
        maxBytes: _maxCacheBytes,
        targetBytes: _trimTargetBytes,
      );
      if (keysToTrim.isEmpty) return;

      final bytesByKey = <String, int>{
        for (final entry in entries) entry.key: entry.bytes,
      };
      var removedBytes = 0;
      for (final key in keysToTrim) {
        removedBytes += bytesByKey[key] ?? 0;
        await _purgeUrl(key, reason: '$reason:budget_trim');
        _managedSlideshowUrls.remove(key);
      }
      final afterBytes = max(0, beforeBytes - removedBytes);
      _publishDebug(
        currentBytes: afterBytes,
        lastTrimAt: DateTime.now(),
        lastTrimRemovedBytes: removedBytes,
        lastTrimRemovedCount: keysToTrim.length,
      );
      _log(
        'BUDGET_TRIM reason=$reason before=$beforeBytes after=$afterBytes removed=${keysToTrim.length}',
      );
      await _enforceAppCacheBudget();
    } finally {
      await refreshDebugCacheSize();
      _publishDebug(isTrimming: false);
    }
  }

  @visibleForTesting
  static Set<String> planTrimKeys({
    required List<({String key, int bytes, DateTime touched})> entries,
    required Set<String> pinnedKeys,
    required int maxBytes,
    required int targetBytes,
  }) {
    final total = entries.fold<int>(0, (sum, e) => sum + max(0, e.bytes));
    if (total <= maxBytes) return <String>{};

    final ordered = [...entries]
      ..sort((a, b) {
        final byTouched = a.touched.compareTo(b.touched);
        if (byTouched != 0) return byTouched;
        return a.key.compareTo(b.key);
      });
    var runningBytes = total;
    final selected = <String>{};

    void trimFrom(List<({String key, int bytes, DateTime touched})> bucket) {
      for (final item in bucket) {
        if (runningBytes <= targetBytes) return;
        if (selected.add(item.key)) {
          runningBytes -= max(0, item.bytes);
        }
      }
    }

    trimFrom(ordered.where((e) => !pinnedKeys.contains(e.key)).toList());
    if (runningBytes > targetBytes) {
      trimFrom(ordered.where((e) => pinnedKeys.contains(e.key)).toList());
    }

    return selected;
  }
}
