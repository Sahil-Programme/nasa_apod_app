import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../models/apod_entry.dart';
import '../ui/app_theme.dart';
import 'space_loading.dart';

enum ApodInlineMediaKind { unsupported, youtube, networkVideo }

class ApodInlineMediaDecision {
  const ApodInlineMediaDecision._({
    required this.kind,
    this.launchUrl,
    this.youtubeId,
  });

  final ApodInlineMediaKind kind;
  final String? launchUrl;
  final String? youtubeId;

  bool get isInlineCapable => kind != ApodInlineMediaKind.unsupported;

  static const Set<String> _directVideoExt = {
    '.mp4',
    '.mov',
    '.m4v',
    '.webm',
    '.mkv',
    '.avi',
  };

  static ApodInlineMediaDecision resolve(ApodEntry entry) {
    if (!entry.shouldRenderAsVideo) {
      return const ApodInlineMediaDecision._(
        kind: ApodInlineMediaKind.unsupported,
      );
    }
    final launch = entry.launchUrl?.trim();
    if (launch == null || launch.isEmpty) {
      return const ApodInlineMediaDecision._(
        kind: ApodInlineMediaKind.unsupported,
      );
    }

    final youtubeId = YoutubePlayerController.convertUrlToId(launch);
    if (youtubeId != null && youtubeId.trim().isNotEmpty) {
      return ApodInlineMediaDecision._(
        kind: ApodInlineMediaKind.youtube,
        launchUrl: launch,
        youtubeId: youtubeId,
      );
    }

    final uri = Uri.tryParse(launch);
    if (uri != null) {
      final path = uri.path.toLowerCase();
      for (final ext in _directVideoExt) {
        if (path.endsWith(ext)) {
          return ApodInlineMediaDecision._(
            kind: ApodInlineMediaKind.networkVideo,
            launchUrl: launch,
          );
        }
      }
    }

    return ApodInlineMediaDecision._(
      kind: ApodInlineMediaKind.unsupported,
      launchUrl: launch,
    );
  }
}

class ApodInlineMedia extends StatefulWidget {
  const ApodInlineMedia({
    super.key,
    required this.entry,
    this.autoplayMuted = true,
    this.showPlaybackControls = false,
    this.interactive = true,
    this.fit = BoxFit.cover,
    this.fallbackBuilder,
  });

  final ApodEntry entry;
  final bool autoplayMuted;
  final bool showPlaybackControls;
  final bool interactive;
  final BoxFit fit;
  final Widget Function(BuildContext context, ApodEntry entry)? fallbackBuilder;

  @override
  State<ApodInlineMedia> createState() => _ApodInlineMediaState();
}

class _ApodInlineMediaState extends State<ApodInlineMedia>
    with WidgetsBindingObserver {
  ApodInlineMediaDecision _decision = const ApodInlineMediaDecision._(
    kind: ApodInlineMediaKind.unsupported,
  );
  VideoPlayerController? _videoController;
  YoutubePlayerController? _youtubeController;
  StreamSubscription<YoutubePlayerValue>? _youtubeSubscription;
  bool _isMuted = true;
  bool _isPlaying = false;
  bool _resumeOnForeground = false;

  bool get _youtubeInlineSupported =>
      kIsWeb || WebViewPlatform.instance != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _configureForEntry();
  }

  @override
  void didUpdateWidget(covariant ApodInlineMedia oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldLaunch = oldWidget.entry.launchUrl ?? '';
    final newLaunch = widget.entry.launchUrl ?? '';
    if (oldLaunch != newLaunch ||
        oldWidget.entry.mediaType != widget.entry.mediaType) {
      _configureForEntry();
    }
  }

  Future<void> _configureForEntry() async {
    await _disposeControllers();
    final decision = ApodInlineMediaDecision.resolve(widget.entry);
    _decision = decision;
    _isMuted = true;
    _isPlaying = false;
    _resumeOnForeground = false;
    if (!mounted) return;
    setState(() {});

    if (!decision.isInlineCapable) {
      return;
    }

    if (decision.kind == ApodInlineMediaKind.youtube) {
      if (!_youtubeInlineSupported || decision.youtubeId == null) {
        setState(() {});
        return;
      }
      final controller = YoutubePlayerController(
        params: YoutubePlayerParams(
          mute: widget.autoplayMuted,
          showControls: widget.showPlaybackControls,
          showFullscreenButton: widget.showPlaybackControls,
          enableKeyboard: false,
          strictRelatedVideos: true,
          playsInline: true,
        ),
      );
      _youtubeController = controller;
      _youtubeSubscription = controller.listen((value) {
        if (!mounted) return;
        if (value.playerState == PlayerState.ended) {
          unawaited(_restartYoutubeLoop(controller));
        }
        final playing =
            value.playerState == PlayerState.playing ||
            value.playerState == PlayerState.buffering;
        setState(() {
          _isPlaying = playing;
        });
      });
      await controller.loadVideoById(videoId: decision.youtubeId!);
      if (widget.autoplayMuted) {
        await controller.mute();
      }
      setState(() {});
      return;
    }

    if (decision.kind == ApodInlineMediaKind.networkVideo &&
        decision.launchUrl != null) {
      final uri = Uri.tryParse(decision.launchUrl!);
      if (uri == null) {
        setState(() {});
        return;
      }
      final controller = VideoPlayerController.networkUrl(uri);
      _videoController = controller;
      controller.addListener(_onVideoValueChanged);
      try {
        await controller.initialize();
        await controller.setLooping(true);
        await controller.setVolume(widget.autoplayMuted ? 0 : 1);
        if (widget.autoplayMuted) _isMuted = true;
        if (widget.autoplayMuted) {
          await controller.play();
        }
      } catch (_) {
        await _disposeControllers();
      }
      if (mounted) setState(() {});
    }
  }

  void _onVideoValueChanged() {
    final controller = _videoController;
    if (!mounted || controller == null) return;
    final value = controller.value;
    setState(() {
      _isPlaying = value.isPlaying;
      _isMuted = value.volume <= 0;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_resumeOnForeground) {
        unawaited(_resumeMuted());
      }
      _resumeOnForeground = false;
      return;
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _resumeOnForeground = _isPlaying;
      unawaited(_pausePlayback());
    }
  }

  Future<void> _pausePlayback() async {
    if (_youtubeController != null) {
      await _youtubeController!.pauseVideo();
      return;
    }
    if (_videoController != null && _videoController!.value.isInitialized) {
      await _videoController!.pause();
    }
  }

  Future<void> _resumeMuted() async {
    if (_youtubeController != null) {
      await _youtubeController!.mute();
      await _youtubeController!.playVideo();
      return;
    }
    if (_videoController != null && _videoController!.value.isInitialized) {
      await _videoController!.setVolume(0);
      await _videoController!.play();
      if (mounted) {
        setState(() => _isMuted = true);
      }
    }
  }

  Future<void> _togglePlayback() async {
    if (_youtubeController != null) {
      if (_isPlaying) {
        await _youtubeController!.pauseVideo();
      } else {
        await _youtubeController!.playVideo();
      }
      return;
    }
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      await controller.play();
    }
  }

  Future<void> _toggleMute() async {
    if (_youtubeController != null) {
      if (_isMuted) {
        await _youtubeController!.unMute();
      } else {
        await _youtubeController!.mute();
      }
      return;
    }
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) return;
    final nextMuted = !_isMuted;
    await controller.setVolume(nextMuted ? 0 : 1);
    if (mounted) {
      setState(() => _isMuted = nextMuted);
    }
  }

  Future<void> _restartYoutubeLoop(YoutubePlayerController controller) async {
    if (_youtubeController != controller) return;
    try {
      await controller.seekTo(seconds: 0);
      await controller.playVideo();
    } catch (_) {
      // Ignore transient player errors while attempting to loop.
    }
  }

  Future<void> _disposeControllers() async {
    if (_videoController != null) {
      _videoController!.removeListener(_onVideoValueChanged);
    }
    await _videoController?.dispose();
    _videoController = null;
    await _youtubeSubscription?.cancel();
    _youtubeSubscription = null;
    await _youtubeController?.close();
    _youtubeController = null;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_disposeControllers());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canInline =
        _decision.isInlineCapable &&
        (_decision.kind != ApodInlineMediaKind.youtube ||
            _youtubeInlineSupported);
    if (!canInline) {
      return _buildFallback(context);
    }

    Widget content;
    if (_decision.kind == ApodInlineMediaKind.youtube &&
        _youtubeController != null) {
      content = YoutubePlayer(
        key: const ValueKey('inline_youtube_player'),
        controller: _youtubeController!,
        aspectRatio: 16 / 9,
        enableFullScreenOnVerticalDrag: false,
      );
    } else if (_decision.kind == ApodInlineMediaKind.networkVideo &&
        _videoController != null &&
        _videoController!.value.isInitialized) {
      content = FittedBox(
        fit: widget.fit,
        child: SizedBox(
          width: _videoController!.value.size.width,
          height: _videoController!.value.size.height,
          child: VideoPlayer(
            key: const ValueKey('inline_network_video_player'),
            _videoController!,
          ),
        ),
      );
    } else {
      content = const Center(
        child: SpaceLoadingIndicator(
          size: SpaceIndicatorSize.small,
          semanticLabel: 'Preparing media',
        ),
      );
    }

    if (!widget.interactive) {
      content = IgnorePointer(child: content);
    }

    return Container(
      key: const ValueKey('inline_media_surface'),
      color: const Color(0xFF050B18),
      child: Stack(
        fit: StackFit.expand,
        children: [
          content,
          if (widget.showPlaybackControls)
            Positioned(
              left: 10,
              right: 10,
              bottom: 10,
              child: _controlsBar(context),
            ),
        ],
      ),
    );
  }

  Widget _controlsBar(BuildContext context) {
    return Container(
      key: const ValueKey('inline_media_controls'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.accent.withValues(alpha: 0.24)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            onPressed: _togglePlayback,
            icon: Icon(_isPlaying ? Icons.pause_circle : Icons.play_circle),
            tooltip: _isPlaying ? 'Pause' : 'Play',
          ),
          IconButton(
            onPressed: _toggleMute,
            icon: Icon(_isMuted ? Icons.volume_off : Icons.volume_up),
            tooltip: _isMuted ? 'Unmute' : 'Mute',
          ),
        ],
      ),
    );
  }

  Widget _buildFallback(BuildContext context) {
    final custom = widget.fallbackBuilder;
    if (custom != null) return custom(context, widget.entry);
    final launch = widget.entry.launchUrl;
    return Container(
      key: const ValueKey('inline_media_fallback'),
      color: const Color(0xFF101A2E),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.ondemand_video,
              size: 46,
              color: AppTheme.accentSoft,
            ),
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: launch == null
                  ? null
                  : () => launchUrl(Uri.parse(launch)),
              child: Text(
                widget.entry.shouldRenderAsAudio ? 'Open Audio' : 'Open Media',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget buildInlineMediaFallbackCard(BuildContext context, ApodEntry entry) {
  final thumbnail = entry.thumbnailUrl;
  return Stack(
    fit: StackFit.expand,
    children: [
      if (thumbnail != null)
        CachedNetworkImage(
          imageUrl: thumbnail,
          fit: BoxFit.cover,
          placeholder: (_, _) =>
              const SpaceImagePlaceholder(showIndicator: false),
          errorWidget: (_, _, _) =>
              const SpaceImagePlaceholder(showIndicator: false),
        )
      else
        const SpaceImagePlaceholder(showIndicator: false),
      Container(color: Colors.black.withValues(alpha: 0.38)),
      Center(
        child: ElevatedButton.icon(
          onPressed: entry.launchUrl == null
              ? null
              : () => launchUrl(Uri.parse(entry.launchUrl!)),
          icon: Icon(
            entry.shouldRenderAsAudio ? Icons.graphic_eq : Icons.open_in_new,
          ),
          label: Text(entry.shouldRenderAsAudio ? 'Open Audio' : 'Open Media'),
        ),
      ),
    ],
  );
}
