import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../models/apod_entry.dart';
import '../models/slideshow_config.dart';
import '../providers/app_providers.dart';
import '../services/cache_service.dart';
import '../services/nasa_api_service.dart';
import '../services/wallpaper_service.dart';
import '../ui/app_theme.dart';
import '../ui/cosmic_scaffold.dart';
import '../widgets/space_loading.dart';
import 'wallpaper_setup_overlay.dart';

/// Fullscreen slideshow player for runtime directional APOD playback.
class SlideshowScreen extends ConsumerStatefulWidget {
  const SlideshowScreen({
    super.key,
    required this.runDuration,
    required this.direction,
    required this.startDate,
    required this.latestAvailableDate,
    required this.initialEntry,
  });

  final Duration runDuration;
  final SlideshowDirection direction;
  final DateTime startDate;
  final DateTime latestAvailableDate;
  final ApodEntry initialEntry;

  @override
  ConsumerState<SlideshowScreen> createState() => _SlideshowScreenState();
}

class _SlideshowScreenState extends ConsumerState<SlideshowScreen> {
  static const bool _showHud = false;
  int i = 0;
  bool playing = true;
  Timer? t;
  Timer? _controlsTimer;
  late final DateTime _startedAt;
  bool _controlsVisible = true;
  bool _initialVisualReady = false;
  bool _startupCacheReady = false;
  DateTime _lastPointerWake = DateTime.fromMillisecondsSinceEpoch(0);

  VideoPlayerController? _videoController;
  VoidCallback? _videoListener;
  YoutubePlayerController? _youtubeController;
  StreamSubscription<YoutubePlayerValue>? _youtubeSubscription;
  bool _awaitingVideoCompletion = false;
  String? _activeSlideKey;
  String? _videoStateNote;
  final Set<String> _failedImageSlides = <String>{};
  final Map<String, String?> _resolvedLaunchPreview = <String, String?>{};
  final Set<String> _previewResolveInFlight = <String>{};
  final Set<String> _hdUpgradeReadyUrls = <String>{};
  final Set<String> _hdUpgradeInFlightUrls = <String>{};
  int _prefetchReadyCount = 0;
  int _prefetchTargetCount = 0;
  final List<ApodEntry> _timeline = <ApodEntry>[];
  final Set<String> _timelineDates = <String>{};
  DateTime? _prefetchCursorDate;
  bool _prefetchInProgress = false;
  bool _timelineAdvanceInProgress = false;
  int _cacheCurrentBytes = 0;
  int _appCacheBytes = 0;
  int _cacheMaxBytes = 0;
  bool _cacheTrimInProgress = false;
  DateTime? _cacheLastTrimAt;
  int _cacheLastTrimRemovedBytes = 0;
  int _cacheLastTrimRemovedCount = 0;
  VoidCallback? _cacheDebugListener;
  CacheService? _cacheService;

  static const _controlsHideDelay = Duration(seconds: 4);
  static const _pointerWakeDebounce = Duration(milliseconds: 250);
  static const _fixedWorkingSetWindow = 5;
  static final DateTime _firstApodDate = NasaApiService.firstApodDate;

  String? _imageUrlForEntry(ApodEntry entry, {bool? lowInternetUsage}) =>
      entry.imageUrlFor(
        lowInternetUsage:
            lowInternetUsage ?? ref.read(lowInternetUsageModeProvider),
      );

  String? _fastImageUrlForEntry(ApodEntry entry, {bool? lowInternetUsage}) {
    final lowInternet =
        lowInternetUsage ?? (ref.read(lowInternetUsageModeProvider) == true);
    return lowInternet ? entry.standardImageUrl : entry.slideshowImageUrl;
  }

  int get _directionStep =>
      widget.direction == SlideshowDirection.forward ? 1 : -1;

  @override
  void initState() {
    super.initState();
    _startedAt = DateTime.now();
    _timeline.add(widget.initialEntry);
    _timelineDates.add(_dateKey(widget.initialEntry.date));
    _prefetchCursorDate = _shiftDate(widget.initialEntry.date, _directionStep);
    _attachCacheDebugListener();
    unawaited(WakelockPlus.enable());
    _showControlsTemporarily();
    unawaited(_bootstrapSlideshow());
  }

  void _attachCacheDebugListener() {
    final cacheService = ref.read(cacheServiceProvider);
    _cacheService = cacheService;
    void syncFromSnapshot() {
      final snapshot = cacheService.debugSnapshot.value;
      if (!mounted) return;
      setState(() {
        _cacheCurrentBytes = snapshot.currentBytes;
        _appCacheBytes = snapshot.appCacheBytes;
        _cacheMaxBytes = snapshot.maxBytes;
        _cacheTrimInProgress = snapshot.isTrimming;
        _cacheLastTrimAt = snapshot.lastTrimAt;
        _cacheLastTrimRemovedBytes = snapshot.lastTrimRemovedBytes;
        _cacheLastTrimRemovedCount = snapshot.lastTrimRemovedCount;
      });
    }

    _cacheDebugListener = syncFromSnapshot;
    cacheService.debugSnapshot.addListener(syncFromSnapshot);
    syncFromSnapshot();
    unawaited(cacheService.refreshDebugCacheSize());
  }

  Future<void> _bootstrapSlideshow() async {
    await _prepareInitialVisual(_timeline.first);
    if (!mounted) return;

    setState(() {
      _initialVisualReady = true;
      _startupCacheReady = true;
    });
    _activateSlideForIndex(0);
    _tick();
    final first = _timeline.first;
    final lowInternetUsage = ref.read(lowInternetUsageModeProvider);
    final firstFast = _fastImageUrlForEntry(
      first,
      lowInternetUsage: lowInternetUsage,
    );
    final firstHd = lowInternetUsage ? null : first.hdurl;
    if (!lowInternetUsage &&
        firstFast != null &&
        firstHd != null &&
        firstHd.trim().isNotEmpty &&
        firstHd != firstFast) {
      unawaited(_primeHdUpgrade(first));
    }
    unawaited(_prefetchAhead(reason: 'bootstrap'));
    unawaited(_syncDirectionalCache(reason: 'bootstrap'));
  }

  Future<void> _prepareInitialVisual(ApodEntry entry) async {
    final previewUrl = _previewUrlForCaching(entry);
    if (previewUrl == null) return;
    final cache = ref.read(cacheServiceProvider).imageCache;
    final cached = await cache.getFileFromCache(previewUrl);
    if (cached != null) return;
    // Kick off first-visual caching in background; do not block slideshow boot.
    unawaited(cache.downloadFile(previewUrl));
  }

  Future<void> _syncDirectionalCache({required String reason}) async {
    if (_timeline.isEmpty) return;
    final window = _fixedWorkingSetWindow;
    final start = i.clamp(0, _timeline.length - 1);
    final end = min(_timeline.length - 1, start + window);
    final urls = <String>{};
    final hdCandidates = <ApodEntry>[];
    final lowInternetUsage = ref.read(lowInternetUsageModeProvider);
    for (var idx = start; idx <= end; idx++) {
      final entry = _timeline[idx];
      final preview = _previewUrlForCaching(entry);
      if (preview != null && preview.trim().isNotEmpty) {
        urls.add(preview);
      }
      if (!lowInternetUsage && entry.shouldRenderAsImage) {
        final fast = _fastImageUrlForEntry(
          entry,
          lowInternetUsage: lowInternetUsage,
        );
        final hd = entry.hdurl;
        if (fast != null && hd != null && hd.trim().isNotEmpty && hd != fast) {
          urls.add(hd);
          hdCandidates.add(entry);
        }
      }
    }
    for (final entry in hdCandidates) {
      unawaited(_primeHdUpgrade(entry));
    }
    await ref
        .read(cacheServiceProvider)
        .syncSlideshowWindowUrls(
          urls,
          reason: '$reason:idx=$i',
          pinnedUrls: urls,
        );
    if (!mounted) return;
    await _refreshPrefetchStatus(urls);
  }

  /// Starts or refreshes the periodic frame-advance loop.
  void _tick() {
    t?.cancel();
    if (!playing) return;

    final interval = ref.read(slideshowIntervalProvider).clamp(8, 300);
    t = Timer.periodic(Duration(seconds: interval), (_) {
      if (!_startupCacheReady) return;
      if (DateTime.now().difference(_startedAt) >= widget.runDuration) {
        setState(() => playing = false);
        t?.cancel();
        return;
      }

      // Video slides are allowed to complete naturally before advancing.
      if (_awaitingVideoCompletion) return;

      unawaited(_advanceToNext(stopWhenUnavailable: true));
    });
  }

  void _showControlsTemporarily() {
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _controlsTimer?.cancel();
    _controlsTimer = Timer(_controlsHideDelay, () {
      if (!mounted) return;
      setState(() => _controlsVisible = false);
    });
  }

  void _onPointerActivity() {
    final now = DateTime.now();
    if (now.difference(_lastPointerWake) < _pointerWakeDebounce) return;
    _lastPointerWake = now;
    _showControlsTemporarily();
  }

  Future<void> _advanceToNext({required bool stopWhenUnavailable}) async {
    if (_timelineAdvanceInProgress) return;
    _timelineAdvanceInProgress = true;
    try {
      if (i + 1 >= _timeline.length) {
        await _prefetchAhead(minUpcoming: 1, reason: 'advance');
      }
      if (!mounted) return;
      if (i + 1 < _timeline.length) {
        _goToIndex(i + 1);
        return;
      }
      if (stopWhenUnavailable) {
        setState(() => playing = false);
        t?.cancel();
      }
    } finally {
      _timelineAdvanceInProgress = false;
    }
  }

  void _goToIndex(int index) {
    if (_timeline.isEmpty) return;
    final safe = index.clamp(0, _timeline.length - 1);
    setState(() => i = safe);
    _activateSlideForIndex(safe);
    final entry = _timeline[safe];
    final lowInternetUsage = ref.read(lowInternetUsageModeProvider);
    final fast = _fastImageUrlForEntry(
      entry,
      lowInternetUsage: lowInternetUsage,
    );
    final hd = lowInternetUsage ? null : entry.hdurl;
    if (!lowInternetUsage &&
        fast != null &&
        hd != null &&
        hd.trim().isNotEmpty &&
        hd != fast &&
        !_hdUpgradeReadyUrls.contains(hd)) {
      unawaited(_primeHdUpgrade(entry));
    }
    unawaited(_prefetchAhead(reason: 'step'));
    unawaited(_syncDirectionalCache(reason: 'step'));
  }

  void _activateSlideForIndex(int index) {
    if (_timeline.isEmpty) return;
    final entry = _timeline[index];
    final key =
        '${entry.date.toIso8601String()}|${entry.mediaType}|${entry.url}|${entry.thumbnailUrl}';
    if (_activeSlideKey == key) return;
    _activeSlideKey = key;
    _videoStateNote = null;
    unawaited(_disposeSlideMedia());

    if (!entry.shouldRenderAsVideo) {
      _awaitingVideoCompletion = false;
      return;
    }

    _startVideoSlidePlayback(entry);
  }

  bool _isWithinDateBounds(DateTime date) =>
      !date.isBefore(_firstApodDate) &&
      !date.isAfter(widget.latestAvailableDate);

  DateTime _shiftDate(DateTime date, int days) {
    final base = DateTime(date.year, date.month, date.day);
    return base.add(Duration(days: days));
  }

  String _dateKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  bool _isUsableTimelineEntry(ApodEntry entry) {
    if (!_isWithinDateBounds(entry.date)) return false;
    if (entry.shouldRenderAsVideo) return false;
    if (entry.shouldRenderAsImage) {
      final url = _imageUrlForEntry(entry);
      return url != null && url.trim().isNotEmpty;
    }
    return true;
  }

  Future<void> _prefetchAhead({
    required String reason,
    int? minUpcoming,
  }) async {
    if (_prefetchInProgress || _prefetchCursorDate == null) return;
    final apiKey = ref.read(apiKeyProvider);
    if (apiKey == null || apiKey.trim().isEmpty) return;

    final targetUpcoming = minUpcoming ?? _fixedWorkingSetWindow;
    if ((_timeline.length - i - 1) >= targetUpcoming) return;

    final lowInternetUsage = ref.read(lowInternetUsageModeProvider);
    final api = ref.read(nasaApiServiceProvider);
    _prefetchInProgress = true;
    try {
      while (mounted && (_timeline.length - i - 1) < targetUpcoming) {
        final candidateDate = _prefetchCursorDate;
        if (candidateDate == null || !_isWithinDateBounds(candidateDate)) {
          break;
        }

        try {
          final entry = await api.fetchByDate(apiKey, candidateDate);
          _prefetchCursorDate = _shiftDate(candidateDate, _directionStep);
          if (!_isUsableTimelineEntry(entry)) {
            continue;
          }
          final key = _dateKey(entry.date);
          if (_timelineDates.contains(key)) {
            continue;
          }
          _timeline.add(entry);
          _timelineDates.add(key);
          unawaited(
            ref
                .read(cacheServiceProvider)
                .warmEntry(
                  entry,
                  reason: '$reason:prefetch',
                  lowInternetUsage: lowInternetUsage,
                ),
          );
        } on NasaApiException catch (e) {
          if (e.shouldAbortDateSearch) {
            break;
          }
          // Missing/unavailable APOD dates are skipped as part of directional traversal.
          _prefetchCursorDate = _shiftDate(candidateDate, _directionStep);
        } catch (_) {
          // Keep current cursor and retry later on transient failures.
          break;
        }
      }
    } finally {
      try {
        await _syncDirectionalCache(reason: reason);
      } finally {
        _prefetchInProgress = false;
        if (mounted) setState(() {});
      }
    }
  }

  Future<void> _startVideoSlidePlayback(ApodEntry entry) async {
    final url = entry.launchUrl;
    if (url == null || url.trim().isEmpty) {
      _awaitingVideoCompletion = false;
      _videoStateNote = 'Video URL unavailable. Showing preview.';
      return;
    }

    final youtubeId = YoutubePlayerController.convertUrlToId(url);
    if (youtubeId != null) {
      final controller = YoutubePlayerController(
        params: const YoutubePlayerParams(
          mute: true,
          showControls: false,
          enableKeyboard: false,
          showFullscreenButton: false,
          strictRelatedVideos: true,
          playsInline: true,
        ),
      );
      _youtubeController = controller;
      _awaitingVideoCompletion = true;
      _youtubeSubscription = controller.listen((value) {
        if (!mounted) return;
        if (value.playerState == PlayerState.ended) {
          _awaitingVideoCompletion = false;
          if (playing) {
            unawaited(_advanceToNext(stopWhenUnavailable: true));
          }
        }
      });

      controller.loadVideoById(videoId: youtubeId);
      controller.mute();
      if (!playing) {
        controller.pauseVideo();
      }
      return;
    }

    final uri = Uri.tryParse(url);
    if (uri == null) {
      _awaitingVideoCompletion = false;
      _videoStateNote = 'Unsupported video URL. Showing preview.';
      return;
    }

    final controller = VideoPlayerController.networkUrl(uri);
    _videoController = controller;
    _awaitingVideoCompletion = true;

    _videoListener = () {
      if (!mounted || _videoController != controller) return;
      final value = controller.value;
      if (value.isCompleted) {
        _awaitingVideoCompletion = false;
        if (playing) {
          unawaited(_advanceToNext(stopWhenUnavailable: true));
        }
      }
    };
    controller.addListener(_videoListener!);

    try {
      await controller.initialize();
      await controller.setVolume(0);
      if (playing) {
        await controller.play();
      }
      if (mounted) setState(() {});
    } catch (_) {
      _awaitingVideoCompletion = false;
      _videoStateNote = 'Inline playback unavailable. Showing preview.';
      if (mounted) setState(() {});
    }
  }

  Future<void> _syncCurrentMediaPlayback() async {
    if (_videoController != null) {
      if (playing) {
        await _videoController!.play();
      } else {
        await _videoController!.pause();
      }
    }

    if (_youtubeController != null) {
      if (playing) {
        await _youtubeController!.playVideo();
      } else {
        await _youtubeController!.pauseVideo();
      }
    }
  }

  Future<void> _disposeSlideMedia() async {
    if (_videoController != null && _videoListener != null) {
      _videoController!.removeListener(_videoListener!);
    }
    _videoListener = null;
    await _videoController?.dispose();
    _videoController = null;

    await _youtubeSubscription?.cancel();
    _youtubeSubscription = null;
    await _youtubeController?.close();
    _youtubeController = null;
  }

  @override
  void dispose() {
    t?.cancel();
    _controlsTimer?.cancel();
    final cacheListener = _cacheDebugListener;
    if (cacheListener != null) {
      _cacheService?.debugSnapshot.removeListener(cacheListener);
    }
    _cacheDebugListener = null;
    _cacheService = null;
    unawaited(WakelockPlus.disable());
    unawaited(_disposeSlideMedia());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = _timeline;
    final lowInternetUsage = ref.watch(lowInternetUsageModeProvider);

    if (items.isEmpty) {
      return const CosmicScaffold(
        child: Center(child: Text('No slideshow items are available.')),
      );
    }

    if (!_initialVisualReady) {
      return CosmicScaffold(
        child: _spaceLoadingScreen(
          message: 'Preparing the next cosmic view...',
        ),
      );
    }

    final safeIndex = i.clamp(0, items.length - 1);
    if (safeIndex != i) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => i = safeIndex);
      });
    }
    final ApodEntry e = items[safeIndex];

    return CosmicScaffold(
      padding: EdgeInsets.zero,
      child: Listener(
        onPointerHover: (_) => _onPointerActivity(),
        onPointerMove: (_) => _onPointerActivity(),
        onPointerDown: (_) => _showControlsTemporarily(),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _showControlsTemporarily,
          child: Stack(
            children: [
              Positioned.fill(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 650),
                  child: _buildSlideContent(e),
                ),
              ),
              if (_showHud)
                Positioned(
                  top: 14,
                  right: 14,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.44),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: AppTheme.accent.withValues(alpha: 0.2),
                      ),
                    ),
                    child: DefaultTextStyle(
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall!.copyWith(color: Colors.white70),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Cache ${_formatBytes(_cacheCurrentBytes)} / ${_formatBytes(_cacheMaxBytes)}',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          Text(
                            'App cache: ${_formatBytes(_appCacheBytes)}',
                            style: const TextStyle(color: Colors.white60),
                          ),
                          if (_prefetchTargetCount > 0)
                            Text(
                              'Window prefetched: $_prefetchReadyCount/$_prefetchTargetCount',
                              style: const TextStyle(color: Colors.white60),
                            ),
                          Text(
                            _cacheTrimInProgress
                                ? 'Cleaning cache...'
                                : 'Clean idle',
                            style: TextStyle(
                              color: _cacheTrimInProgress
                                  ? AppTheme.accentSoft
                                  : Colors.white60,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (!_cacheTrimInProgress &&
                              _cacheLastTrimRemovedCount > 0 &&
                              _cacheLastTrimAt != null)
                            Text(
                              'Last clean: -${_formatBytes(_cacheLastTrimRemovedBytes)} (${_cacheLastTrimRemovedCount})',
                              style: const TextStyle(color: Colors.white60),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              Positioned(
                left: 12,
                right: 12,
                bottom: _controlsVisible ? 86 : 14,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: AppTheme.accent.withValues(alpha: 0.24),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        e.date.toIso8601String().split('T').first,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppTheme.accentSoft,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        e.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              AnimatedPositioned(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                left: 12,
                right: 12,
                bottom: _controlsVisible ? 14 : -120,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: AppTheme.accent.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Close',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                      IconButton(
                        onPressed: () {
                          if (i <= 0) return;
                          _goToIndex(i - 1);
                          _showControlsTemporarily();
                        },
                        icon: const Icon(Icons.skip_previous),
                      ),
                      IconButton(
                        onPressed: () async {
                          setState(() => playing = !playing);
                          if (playing) {
                            _tick();
                          } else {
                            t?.cancel();
                          }
                          await _syncCurrentMediaPlayback();
                          _showControlsTemporarily();
                        },
                        icon: Icon(
                          playing ? Icons.pause_circle : Icons.play_circle,
                        ),
                      ),
                      IconButton(
                        onPressed: () {
                          unawaited(_advanceToNext(stopWhenUnavailable: false));
                          _showControlsTemporarily();
                        },
                        icon: const Icon(Icons.skip_next),
                      ),
                      if (e.shouldRenderAsImage &&
                          _imageUrlForEntry(
                                e,
                                lowInternetUsage: lowInternetUsage,
                              ) !=
                              null)
                        IconButton(
                          tooltip: 'Set wallpaper',
                          onPressed: () async {
                            await _setCurrentSlideAsWallpaper(context, e);
                            _showControlsTemporarily();
                          },
                          icon: const Icon(Icons.wallpaper),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSlideContent(ApodEntry entry) {
    if (entry.shouldRenderAsImage) return _buildImageSlide(entry);
    if (entry.shouldRenderAsVideo) return _buildVideoSlide(entry);
    if (entry.shouldRenderAsAudio) return _buildAudioSlide(entry);
    return _buildUnknownSlide(entry);
  }

  Widget _buildImageSlide(ApodEntry entry) {
    final lowInternetUsage = ref.read(lowInternetUsageModeProvider);
    final cacheManager = ref.read(cacheServiceProvider).imageCache;
    final hdFallbackUrl = lowInternetUsage ? null : entry.bestImageUrl;
    final imageUrl = _effectiveSlideImageUrl(entry);
    if (imageUrl == null || imageUrl.trim().isEmpty) {
      _skipCurrentIfPossible(entry, reason: 'missing-image-url');
      return _spaceLoadingScreen(message: 'Image unavailable for this entry.');
    }

    return CachedNetworkImage(
      key: ValueKey('img_${entry.date.toIso8601String()}_$imageUrl'),
      imageUrl: imageUrl,
      cacheManager: cacheManager,
      fit: BoxFit.cover,
      placeholder: (_, _) => _spaceLoadingScreen(message: 'Loading image...'),
      errorWidget: (_, _, _) {
        if (hdFallbackUrl != null &&
            hdFallbackUrl.trim().isNotEmpty &&
            hdFallbackUrl != imageUrl) {
          return CachedNetworkImage(
            imageUrl: hdFallbackUrl,
            cacheManager: cacheManager,
            fit: BoxFit.cover,
            placeholder: (_, _) =>
                _spaceLoadingScreen(message: 'Loading fallback...'),
            errorWidget: (_, _, _) {
              _skipCurrentIfPossible(entry, reason: 'image-fallback-failed');
              return _spaceLoadingScreen(
                message: 'Unable to render this image. Skipping…',
              );
            },
          );
        }
        _skipCurrentIfPossible(entry, reason: 'image-render-failed');
        return _spaceLoadingScreen(
          message: 'Unable to render this image. Skipping…',
        );
      },
    );
  }

  String? _effectiveSlideImageUrl(ApodEntry entry) {
    final lowInternetUsage = ref.read(lowInternetUsageModeProvider);
    final fast = _fastImageUrlForEntry(
      entry,
      lowInternetUsage: lowInternetUsage,
    );
    if (lowInternetUsage) return fast;
    if (fast == null || fast.trim().isEmpty) {
      return entry.imageUrlFor(lowInternetUsage: false);
    }
    final hd = entry.hdurl;
    if (hd != null &&
        hd.trim().isNotEmpty &&
        hd != fast &&
        _hdUpgradeReadyUrls.contains(hd)) {
      return hd;
    }
    return fast;
  }

  void _skipCurrentIfPossible(ApodEntry entry, {required String reason}) {
    final key = '${entry.date.toIso8601String()}|$reason';
    if (_failedImageSlides.contains(key)) return;
    _failedImageSlides.add(key);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_timeline.length <= 1) return;
      if (i < 0 || i >= _timeline.length) return;
      if (_timeline[i].date != entry.date) return;
      unawaited(_advanceToNext(stopWhenUnavailable: true));
    });
  }

  Widget _buildVideoSlide(ApodEntry entry) {
    if (_youtubeController != null) {
      return Container(
        key: ValueKey('yt_${entry.date.toIso8601String()}'),
        color: const Color(0xFF050B18),
        alignment: Alignment.center,
        child: YoutubePlayer(
          controller: _youtubeController!,
          aspectRatio: 16 / 9,
          enableFullScreenOnVerticalDrag: false,
        ),
      );
    }

    if (_videoController != null) {
      if (_videoController!.value.isInitialized) {
        return Container(
          key: ValueKey('vp_${entry.date.toIso8601String()}'),
          color: const Color(0xFF050B18),
          alignment: Alignment.center,
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: _videoController!.value.size.width,
              height: _videoController!.value.size.height,
              child: VideoPlayer(_videoController!),
            ),
          ),
        );
      }
      return _spaceLoadingScreen(message: 'Preparing video...');
    }

    return _buildPreviewFallback(
      entry,
      message: _videoStateNote ?? 'Video preview',
      noPreviewMessage: 'No preview available for this video.',
      keyPrefix: 'vf',
      icon: Icons.ondemand_video,
    );
  }

  Widget _buildAudioSlide(ApodEntry entry) {
    return _buildPreviewFallback(
      entry,
      message: 'Audio entry. Open in browser for playback.',
      noPreviewMessage: 'No preview available for this audio entry.',
      keyPrefix: 'af',
      icon: Icons.graphic_eq,
    );
  }

  Widget _buildUnknownSlide(ApodEntry entry) {
    return _buildPreviewFallback(
      entry,
      message: 'Unsupported media type: ${entry.mediaType}.',
      noPreviewMessage: 'No preview available for this media.',
      keyPrefix: 'uf',
      icon: Icons.auto_awesome_mosaic,
    );
  }

  Widget _buildPreviewFallback(
    ApodEntry entry, {
    required String message,
    required String noPreviewMessage,
    required String keyPrefix,
    required IconData icon,
  }) {
    unawaited(_ensureDynamicPreviewResolved(entry));
    final cacheManager = ref.read(cacheServiceProvider).imageCache;
    final previewUrl = _previewUrlForCaching(entry);
    return Container(
      key: ValueKey('${keyPrefix}_${entry.date.toIso8601String()}'),
      color: const Color(0xFF0E1A2F),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (previewUrl != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: CachedNetworkImage(
                    imageUrl: previewUrl,
                    cacheManager: cacheManager,
                    height: 220,
                    fit: BoxFit.cover,
                    placeholder: (_, _) => const SpaceImagePlaceholder(
                      height: 220,
                      width: 360,
                      showIndicator: false,
                    ),
                    errorWidget: (_, _, _) => const SpaceImagePlaceholder(
                      height: 220,
                      width: 360,
                      showIndicator: false,
                    ),
                  ),
                )
              else
                Icon(icon, size: 52, color: AppTheme.accentSoft),
              const SizedBox(height: 14),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              if (previewUrl == null) ...[
                const SizedBox(height: 8),
                Text(
                  noPreviewMessage,
                  style: const TextStyle(color: Colors.white54),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String? _previewUrlForCaching(ApodEntry entry) {
    final fastImage = _fastImageUrlForEntry(entry);
    if (entry.shouldRenderAsImage && fastImage != null) {
      return fastImage;
    }
    if (entry.thumbnailUrl != null && entry.thumbnailUrl!.trim().isNotEmpty) {
      return entry.thumbnailUrl;
    }
    final launch = entry.launchUrl;
    if (launch == null || launch.trim().isEmpty) return null;
    final resolved = _resolvedLaunchPreview[launch];
    if (resolved != null && resolved.trim().isNotEmpty) return resolved;
    final providerPreview = _providerPreviewFromLaunch(launch);
    if (providerPreview != null) return providerPreview;
    final youtubeId = YoutubePlayerController.convertUrlToId(launch);
    if (youtubeId != null) {
      return 'https://img.youtube.com/vi/$youtubeId/hqdefault.jpg';
    }
    return null;
  }

  Future<void> _primeHdUpgrade(ApodEntry entry) async {
    if (ref.read(lowInternetUsageModeProvider)) return;
    final hd = entry.hdurl;
    final fast = _fastImageUrlForEntry(entry, lowInternetUsage: false);
    if (hd == null || hd.trim().isEmpty || hd == fast) return;
    if (_hdUpgradeReadyUrls.contains(hd) ||
        _hdUpgradeInFlightUrls.contains(hd)) {
      return;
    }
    _hdUpgradeInFlightUrls.add(hd);
    try {
      final cache = ref.read(cacheServiceProvider).imageCache;
      final cached = await cache.getFileFromCache(hd);
      if (cached == null) {
        await cache.downloadFile(hd);
      }
      _hdUpgradeReadyUrls.add(hd);
      if (mounted) setState(() {});
    } catch (_) {
      // Keep slideshow smooth even if HD upgrade fails.
    } finally {
      _hdUpgradeInFlightUrls.remove(hd);
    }
  }

  Future<void> _refreshPrefetchStatus(Set<String> urls) async {
    final cache = ref.read(cacheServiceProvider).imageCache;
    final checks = await Future.wait(
      urls.map((url) => cache.getFileFromCache(url)),
      eagerError: false,
    );
    var ready = 0;
    for (final cached in checks) {
      if (cached != null) ready++;
    }
    if (!mounted) return;
    setState(() {
      _prefetchTargetCount = urls.length;
      _prefetchReadyCount = ready;
    });
  }

  String? _providerPreviewFromLaunch(String launch) {
    final uri = Uri.tryParse(launch);
    if (uri == null) return null;
    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    if (path.endsWith('.jpg') ||
        path.endsWith('.jpeg') ||
        path.endsWith('.png') ||
        path.endsWith('.gif') ||
        path.endsWith('.webp')) {
      return launch;
    }
    if (host.contains('vimeo.com')) {
      final match = RegExp(r'vimeo\.com/(?:video/)?(\d+)').firstMatch(launch);
      final id = match?.group(1);
      if (id != null && id.isNotEmpty) {
        return 'https://vumbnail.com/$id.jpg';
      }
    }
    if (host.contains('dailymotion.com')) {
      final match = RegExp(r'/video/([A-Za-z0-9]+)').firstMatch(path);
      final id = match?.group(1);
      if (id != null && id.isNotEmpty) {
        return 'https://www.dailymotion.com/thumbnail/video/$id';
      }
    }
    return null;
  }

  Future<void> _ensureDynamicPreviewResolved(ApodEntry entry) async {
    final launch = entry.launchUrl;
    if (launch == null || launch.trim().isEmpty) return;
    if (_previewResolveInFlight.contains(launch)) return;
    if (_previewUrlForCaching(entry) != null) return;

    _previewResolveInFlight.add(launch);
    String? discovered;
    try {
      final uri = Uri.tryParse(launch);
      if (uri != null) {
        final response = await http
            .get(uri, headers: const {'User-Agent': 'nasa-apod-explorer/1.0'})
            .timeout(const Duration(seconds: 5));
        if (response.statusCode >= 200 &&
            response.statusCode < 300 &&
            response.body.isNotEmpty) {
          discovered = _extractMetaPreviewImage(response.body, uri);
        }
      }
    } catch (_) {
      // Keep graceful fallback when preview resolution fails.
    } finally {
      _previewResolveInFlight.remove(launch);
    }

    _resolvedLaunchPreview[launch] = discovered;
    if (!mounted) return;
    setState(() {});
    if (discovered != null && discovered.trim().isNotEmpty) {
      unawaited(_syncDirectionalCache(reason: 'preview_resolved'));
    }
  }

  String? _extractMetaPreviewImage(String html, Uri base) {
    final patterns = <RegExp>[
      RegExp(
        r'''<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']''',
        caseSensitive: false,
      ),
      RegExp(
        r'''<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image["']''',
        caseSensitive: false,
      ),
      RegExp(
        r'''<meta[^>]+name=["']twitter:image["'][^>]+content=["']([^"']+)["']''',
        caseSensitive: false,
      ),
      RegExp(
        r'''<meta[^>]+content=["']([^"']+)["'][^>]+name=["']twitter:image["']''',
        caseSensitive: false,
      ),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(html);
      final candidate = match?.group(1)?.trim();
      if (candidate == null || candidate.isEmpty) continue;
      final resolved = Uri.tryParse(candidate);
      if (resolved == null) continue;
      final absolute = resolved.hasScheme
          ? resolved
          : base.resolveUri(resolved);
      return absolute.toString();
    }
    return null;
  }

  String _formatBytes(int bytes) {
    final safe = max(0, bytes);
    if (safe == 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = safe.toDouble();
    var unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex++;
    }
    final display = unitIndex == 0
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
    return '$display ${units[unitIndex]}';
  }

  Widget _spaceLoadingScreen({required String message}) {
    return SpaceLoadingSurface(
      message: message,
      size: SpaceIndicatorSize.large,
    );
  }

  Future<void> _setCurrentSlideAsWallpaper(
    BuildContext context,
    ApodEntry entry,
  ) async {
    final imageUrl = _imageUrlForEntry(entry);
    if (imageUrl == null) return;

    final wallpaperService = ref.read(wallpaperServiceProvider);
    final wasPlaying = playing;
    if (wasPlaying) {
      setState(() => playing = false);
      t?.cancel();
      await _syncCurrentMediaPlayback();
    }

    try {
      final file = await ref
          .read(cacheServiceProvider)
          .imageCache
          .getSingleFile(imageUrl);
      if (!context.mounted) return;
      if (Platform.isAndroid) {
        final confirm = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Set wallpaper?'),
            content: const Text(
              'Open Android wallpaper settings for this image?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Continue'),
              ),
            ],
          ),
        );
        if (!context.mounted || confirm != true) return;
        final msg = await wallpaperService.openAndroidSystemWallpaperPicker(
          file.path,
        );
        if (!context.mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(msg)));
        return;
      }
      final platformTargetSize = await wallpaperService
          .getPlatformWallpaperTargetSize();
      if (!context.mounted) return;
      final setup = await showWallpaperSetupOverlay(
        context,
        sourcePath: file.path,
        title: entry.title,
        platformTargetSize: platformTargetSize,
      );
      if (!context.mounted || setup == null || !setup.applied) return;
      final outputPath = setup.outputPath ?? file.path;

      final msg = await wallpaperService.setImageWallpaper(
        outputPath,
        style: setup.style,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } finally {
      if (wasPlaying && mounted) {
        setState(() => playing = true);
        _tick();
        await _syncCurrentMediaPlayback();
      }
    }
  }
}
