import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../models/apod_entry.dart';
import '../models/slideshow_config.dart';
import '../providers/app_providers.dart';
import '../services/wallpaper_service.dart';
import '../ui/app_theme.dart';
import '../ui/cosmic_scaffold.dart';

/// Fullscreen slideshow player for preloaded APOD entries.
class SlideshowScreen extends ConsumerStatefulWidget {
  const SlideshowScreen({
    super.key,
    required this.runDuration,
    required this.direction,
    required this.startDate,
  });

  final Duration runDuration;
  final SlideshowDirection direction;
  final DateTime startDate;

  @override
  ConsumerState<SlideshowScreen> createState() => _SlideshowScreenState();
}

class _SlideshowScreenState extends ConsumerState<SlideshowScreen> {
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

  static const _controlsHideDelay = Duration(seconds: 4);
  static const _pointerWakeDebounce = Duration(milliseconds: 250);

  @override
  void initState() {
    super.initState();
    _startedAt = DateTime.now();
    _showControlsTemporarily();
    unawaited(_bootstrapSlideshow());
  }

  Future<void> _bootstrapSlideshow() async {
    final items = ref.read(slideshowEntriesProvider);
    if (items.isEmpty) {
      if (mounted) {
        setState(() => _initialVisualReady = true);
      }
      return;
    }

    await _prepareInitialVisual(items.first);
    if (!mounted) return;

    setState(() => _initialVisualReady = true);
    _activateSlideForIndex(0);
    try {
      await _syncSlidingCacheForIndex(0, reason: 'bootstrap');
    } finally {
      if (mounted) {
        setState(() => _startupCacheReady = true);
        _tick();
      }
    }
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

  Future<void> _syncSlidingCacheForIndex(
    int index, {
    required String reason,
  }) async {
    final items = ref.read(slideshowEntriesProvider);
    if (items.isEmpty) return;
    final window = ref.read(precacheWindowProvider).clamp(5, 15);
    final start = max(0, index - window);
    final end = min(items.length - 1, index + window);
    final urls = <String>{};
    for (var idx = start; idx <= end; idx++) {
      final preview = _previewUrlForCaching(items[idx]);
      if (preview != null && preview.trim().isNotEmpty) {
        urls.add(preview);
      }
    }
    await ref
        .read(cacheServiceProvider)
        .syncSlideshowWindowUrls(urls, reason: '$reason:idx=$index');
  }

  /// Starts or refreshes the periodic frame-advance loop.
  void _tick() {
    t?.cancel();
    if (!playing) return;

    t = Timer.periodic(Duration(seconds: ref.read(slideshowIntervalProvider)), (
      _,
    ) {
      if (!_startupCacheReady) return;
      if (DateTime.now().difference(_startedAt) >= widget.runDuration) {
        setState(() => playing = false);
        t?.cancel();
        return;
      }

      // Video slides are allowed to complete naturally before advancing.
      if (_awaitingVideoCompletion) return;

      _advanceToNext();
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

  void _advanceToNext() {
    final items = ref.read(slideshowEntriesProvider);
    if (items.isEmpty) return;
    final next = ((i + 1) % items.length).toInt();
    _goToIndex(next);
  }

  void _goToIndex(int index) {
    final items = ref.read(slideshowEntriesProvider);
    if (items.isEmpty) return;
    final safe = index.clamp(0, items.length - 1);
    setState(() => i = safe);
    _activateSlideForIndex(safe);
    unawaited(_syncSlidingCacheForIndex(safe, reason: 'step'));
  }

  void _activateSlideForIndex(int index) {
    final items = ref.read(slideshowEntriesProvider);
    if (items.isEmpty) return;
    final entry = items[index];
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
          if (playing) _advanceToNext();
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
        if (playing) _advanceToNext();
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
    unawaited(_disposeSlideMedia());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(slideshowEntriesProvider);
    final elapsed = DateTime.now().difference(_startedAt);
    final remaining = widget.runDuration - elapsed;
    final remainingText = remaining.isNegative
        ? '00:00'
        : '${remaining.inMinutes.remainder(60).toString().padLeft(2, '0')}:${remaining.inSeconds.remainder(60).toString().padLeft(2, '0')}';

    if (items.isEmpty) {
      return const CosmicScaffold(
        child: Center(child: Text('No slideshow items')),
      );
    }

    if (!_initialVisualReady) {
      return CosmicScaffold(
        child: _spaceLoadingScreen(
          context,
          message: 'Preparing the next cosmic view...',
        ),
      );
    }

    final ApodEntry e = items[i];

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
              Positioned(
                right: 14,
                bottom: _controlsVisible ? 86 : 14,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
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
                    child: Text(
                      '${e.date.toIso8601String().split('T').first} • ${e.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
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
                          final items = ref.read(slideshowEntriesProvider);
                          if (items.isEmpty) return;
                          _goToIndex(
                            ((i - 1 + items.length) % items.length).toInt(),
                          );
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
                          _advanceToNext();
                          _showControlsTemporarily();
                        },
                        icon: const Icon(Icons.skip_next),
                      ),
                      if (e.shouldRenderAsImage && e.bestImageUrl != null)
                        IconButton(
                          tooltip: 'Set wallpaper',
                          onPressed: () async {
                            await _setCurrentSlideAsWallpaper(context, e);
                            _showControlsTemporarily();
                          },
                          icon: const Icon(Icons.wallpaper),
                        ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${widget.direction == SlideshowDirection.forward ? 'Forward' : 'Backward'} · $remainingText',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
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
    final imageUrl = entry.bestImageUrl;
    if (imageUrl == null || imageUrl.trim().isEmpty) {
      _skipCurrentIfPossible(entry, reason: 'missing-image-url');
      return _spaceLoadingScreen(
        context,
        message: 'Image unavailable for this entry.',
      );
    }

    return CachedNetworkImage(
      key: ValueKey('img_${entry.date.toIso8601String()}'),
      imageUrl: imageUrl,
      fit: BoxFit.cover,
      placeholder: (_, _) =>
          _spaceLoadingScreen(context, message: 'Loading image...'),
      errorWidget: (_, _, _) {
        _skipCurrentIfPossible(entry, reason: 'image-render-failed');
        return _spaceLoadingScreen(
          context,
          message: 'Unable to render this image. Skipping…',
        );
      },
    );
  }

  void _skipCurrentIfPossible(ApodEntry entry, {required String reason}) {
    final key = '${entry.date.toIso8601String()}|$reason';
    if (_failedImageSlides.contains(key)) return;
    _failedImageSlides.add(key);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final items = ref.read(slideshowEntriesProvider);
      if (items.length <= 1) return;
      if (items[i].date != entry.date) return;
      _advanceToNext();
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
      return _spaceLoadingScreen(context, message: 'Preparing video...');
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
                    height: 220,
                    fit: BoxFit.cover,
                    placeholder: (_, _) =>
                        const SizedBox(height: 220, width: 360),
                    errorWidget: (_, _, _) =>
                        const SizedBox(height: 220, width: 360),
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
    if (entry.shouldRenderAsImage && entry.bestImageUrl != null) {
      return entry.bestImageUrl;
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
      unawaited(_syncSlidingCacheForIndex(i, reason: 'preview_resolved'));
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

  Widget _spaceLoadingScreen(BuildContext context, {required String message}) {
    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0.1, -0.3),
          radius: 1.2,
          colors: [Color(0xFF132040), Color(0xFF090F1E), Color(0xFF050912)],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.auto_awesome,
              color: AppTheme.accentSoft,
              size: 46,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _setCurrentSlideAsWallpaper(
    BuildContext context,
    ApodEntry entry,
  ) async {
    final imageUrl = entry.bestImageUrl;
    if (imageUrl == null) return;

    var style = WallpaperFit.fill;
    if (Platform.isWindows) {
      final picked = await _pickWindowsWallpaperStyle(context);
      if (picked == null) return;
      style = picked;
    }

    final file = await ref
        .read(cacheServiceProvider)
        .imageCache
        .getSingleFile(imageUrl);
    final msg = await ref
        .read(wallpaperServiceProvider)
        .setImageWallpaper(file.path, style: style);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<WallpaperFit?> _pickWindowsWallpaperStyle(BuildContext context) {
    return showModalBottomSheet<WallpaperFit>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(title: Text('Wallpaper Style')),
              ListTile(
                title: const Text('Fill'),
                onTap: () => Navigator.pop(context, WallpaperFit.fill),
              ),
              ListTile(
                title: const Text('Stretch'),
                onTap: () => Navigator.pop(context, WallpaperFit.stretch),
              ),
              ListTile(
                title: const Text('Fit'),
                onTap: () => Navigator.pop(context, WallpaperFit.fit),
              ),
            ],
          ),
        );
      },
    );
  }
}
