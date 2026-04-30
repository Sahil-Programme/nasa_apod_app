import 'dart:async';
import 'dart:math';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../models/apod_entry.dart';
import '../models/slideshow_config.dart';
import '../providers/app_providers.dart';
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
  DateTime _lastPointerWake = DateTime.fromMillisecondsSinceEpoch(0);

  VideoPlayerController? _videoController;
  VoidCallback? _videoListener;
  YoutubePlayerController? _youtubeController;
  StreamSubscription<YoutubePlayerValue>? _youtubeSubscription;
  bool _awaitingVideoCompletion = false;
  String? _activeSlideKey;
  String? _videoError;

  static const _controlsHideDelay = Duration(seconds: 4);
  static const _pointerWakeDebounce = Duration(milliseconds: 250);

  @override
  void initState() {
    super.initState();
    _startedAt = DateTime.now();
    _showControlsTemporarily();
    _warmInitialCache();
    _activateSlideForIndex(0);
    _tick();
  }

  /// Starts or refreshes the periodic frame-advance loop.
  void _tick() {
    t?.cancel();
    if (!playing) return;

    t = Timer.periodic(Duration(seconds: ref.read(slideshowIntervalProvider)), (
      _,
    ) {
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

  Future<void> _warmInitialCache() async {
    final items = ref.read(slideshowEntriesProvider);
    if (items.isEmpty) return;
    final cache = ref.read(cacheServiceProvider).imageCache;
    final warmCount = min(items.length, 20);

    for (var idx = 0; idx < warmCount; idx++) {
      final entry = items[idx];
      final url = entry.isImage ? entry.bestImageUrl : entry.thumbnailUrl;
      if (url != null) {
        cache.downloadFile(url).ignore();
      }
    }
  }

  void _prefetchUpcoming(List<ApodEntry> items, int index) {
    final window = max(ref.read(precacheWindowProvider), 16);
    ref.read(cacheServiceProvider).precacheUpcoming(items, index, window);
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
    _prefetchUpcoming(items, safe);
  }

  void _activateSlideForIndex(int index) {
    final items = ref.read(slideshowEntriesProvider);
    if (items.isEmpty) return;
    final entry = items[index];
    final key =
        '${entry.date.toIso8601String()}|${entry.mediaType}|${entry.url}';
    if (_activeSlideKey == key) return;
    _activeSlideKey = key;
    _videoError = null;
    _disposeSlideMedia();

    if (!entry.isVideo) {
      _awaitingVideoCompletion = false;
      return;
    }

    _startVideoSlidePlayback(entry);
  }

  Future<void> _startVideoSlidePlayback(ApodEntry entry) async {
    final url = entry.url;
    if (url == null || url.trim().isEmpty) {
      _awaitingVideoCompletion = false;
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
      _videoError = 'Unsupported video URL';
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
      _videoError = 'Unable to autoplay this video source.';
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
    _disposeSlideMedia();
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
                  child: e.isImage ? _buildImageSlide(e) : _buildVideoSlide(e),
                ),
              ),
              Positioned(
                right: 14,
                bottom: _controlsVisible ? 86 : 14,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
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
                      e.title,
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

  Widget _buildImageSlide(ApodEntry entry) {
    return CachedNetworkImage(
      key: ValueKey('img_${entry.date.toIso8601String()}'),
      imageUrl: entry.bestImageUrl ?? '',
      fit: BoxFit.cover,
      placeholder: (_, _) => const ColoredBox(
        color: Color(0xFF0E1A2F),
        child: Center(child: CircularProgressIndicator()),
      ),
      errorWidget: (_, _, _) => const ColoredBox(
        color: Color(0xFF0E1A2F),
        child: Center(child: Icon(Icons.broken_image_outlined)),
      ),
    );
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
      return const ColoredBox(
        color: Color(0xFF050B18),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return Container(
      key: ValueKey('vf_${entry.date.toIso8601String()}'),
      color: const Color(0xFF0E1A2F),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (entry.thumbnailUrl != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.network(entry.thumbnailUrl!, height: 200),
                ),
              const SizedBox(height: 14),
              Text(
                _videoError ?? 'Video source could not autoplay inline.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
