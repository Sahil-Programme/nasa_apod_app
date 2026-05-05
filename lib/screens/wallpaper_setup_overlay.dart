import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../services/wallpaper_service.dart';
import '../ui/app_theme.dart';
import '../widgets/space_loading.dart';

class WallpaperSetupResult {
  const WallpaperSetupResult({
    required this.applied,
    required this.outputPath,
    required this.style,
  });

  final bool applied;
  final String? outputPath;
  final WallpaperFit style;
}

Future<WallpaperSetupResult?> showWallpaperSetupOverlay(
  BuildContext context, {
  required String sourcePath,
  required String title,
  WallpaperFit initialStyle = WallpaperFit.fill,
  WallpaperTargetSize? platformTargetSize,
}) {
  return Navigator.of(context).push<WallpaperSetupResult>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => WallpaperSetupOverlay(
        sourcePath: sourcePath,
        title: title,
        initialStyle: initialStyle,
        platformTargetSize: platformTargetSize,
      ),
    ),
  );
}

class WallpaperSetupOverlay extends StatefulWidget {
  const WallpaperSetupOverlay({
    super.key,
    required this.sourcePath,
    required this.title,
    this.initialStyle = WallpaperFit.fill,
    this.platformTargetSize,
  });

  final String sourcePath;
  final String title;
  final WallpaperFit initialStyle;
  final WallpaperTargetSize? platformTargetSize;

  @override
  State<WallpaperSetupOverlay> createState() => _WallpaperSetupOverlayState();
}

class _WallpaperSetupOverlayState extends State<WallpaperSetupOverlay> {
  static const double _canvasZoomOutFactor = 0.25;
  static const double _minVisibleOverlapPx = 1.0;

  ui.Image? _image;
  bool _loading = true;
  bool _exporting = false;
  String? _loadError;

  Size _cropSize = Size.zero;
  double _scale = 1;
  double _minScale = 1;
  double _maxScale = 6;
  Offset _offset = Offset.zero;

  double _gestureStartScale = 1;
  Offset _gestureContentPoint = Offset.zero;

  late WallpaperFit _style;

  bool get _isCanvasMode => Platform.isAndroid || Platform.isWindows;

  double _previewAspectRatio(Size fallbackScreen) {
    final target = widget.platformTargetSize;
    if (_isCanvasMode && target != null && target.heightPx > 0) {
      return target.widthPx / target.heightPx;
    }
    return fallbackScreen.width / fallbackScreen.height;
  }

  @override
  void initState() {
    super.initState();
    _style = widget.initialStyle;
    _loadImage();
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _loadImage() async {
    try {
      final bytes = await File(widget.sourcePath).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted) return;
      setState(() {
        _image = frame.image;
        _loading = false;
      });
      _applyTransformConstraints(resetToMinScale: true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = 'Could not load image for wallpaper setup.';
      });
    }
  }

  double _coverScaleFor(Size crop, ui.Image image) {
    final imageW = image.width.toDouble();
    final imageH = image.height.toDouble();
    if (imageW <= 0 || imageH <= 0 || crop.isEmpty) return 1;
    return max(crop.width / imageW, crop.height / imageH);
  }

  double _containScaleFor(Size crop, ui.Image image) {
    final imageW = image.width.toDouble();
    final imageH = image.height.toDouble();
    if (imageW <= 0 || imageH <= 0 || crop.isEmpty) return 1;
    return min(crop.width / imageW, crop.height / imageH);
  }

  Offset _clampOffset(Offset raw, double scale, {Size? crop, ui.Image? image}) {
    final activeCrop = crop ?? _cropSize;
    final activeImage = image ?? _image;
    if (activeCrop.isEmpty || activeImage == null) return raw;

    final scaledW = activeImage.width * scale;
    final scaledH = activeImage.height * scale;
    final maxDx = scaledW >= activeCrop.width
        ? (scaledW - activeCrop.width) / 2
        : ((scaledW + activeCrop.width) / 2) - _minVisibleOverlapPx;
    final maxDy = scaledH >= activeCrop.height
        ? (scaledH - activeCrop.height) / 2
        : ((scaledH + activeCrop.height) / 2) - _minVisibleOverlapPx;

    return Offset(
      raw.dx.clamp(-max(0.0, maxDx), max(0.0, maxDx)).toDouble(),
      raw.dy.clamp(-max(0.0, maxDy), max(0.0, maxDy)).toDouble(),
    );
  }

  void _applyTransformConstraints({bool resetToMinScale = false}) {
    final image = _image;
    if (image == null || _cropSize.isEmpty || !mounted) return;

    final coverScale = _coverScaleFor(_cropSize, image);
    final containScale = _containScaleFor(_cropSize, image);
    final nextMinScale = _isCanvasMode
        ? max(0.05, containScale * _canvasZoomOutFactor)
        : coverScale;
    final nextMaxScale = max(coverScale, coverScale * 6);

    var nextScale = _scale;
    var nextOffset = _offset;

    if (resetToMinScale) {
      nextScale = _isCanvasMode ? containScale : coverScale;
      nextOffset = Offset.zero;
    } else {
      if (nextScale < nextMinScale) nextScale = nextMinScale;
      if (nextScale > nextMaxScale) nextScale = nextMaxScale;
      nextOffset = _clampOffset(nextOffset, nextScale);
    }

    if (nextScale == _scale &&
        nextOffset == _offset &&
        nextMinScale == _minScale &&
        nextMaxScale == _maxScale) {
      return;
    }

    setState(() {
      _scale = nextScale;
      _offset = nextOffset;
      _minScale = nextMinScale;
      _maxScale = nextMaxScale;
    });
  }

  Rect _largestRectWithAspect(Size bounds, double aspect) {
    if (bounds.isEmpty || aspect <= 0) return Rect.zero;
    final boundAspect = bounds.width / bounds.height;
    if (boundAspect > aspect) {
      final width = bounds.height * aspect;
      final left = (bounds.width - width) / 2;
      return Rect.fromLTWH(left, 0, width, bounds.height);
    }
    final height = bounds.width / aspect;
    final top = (bounds.height - height) / 2;
    return Rect.fromLTWH(0, top, bounds.width, height);
  }

  Future<String> _exportCurrentWallpaper() async {
    final image = _image;
    if (image == null || _cropSize.isEmpty) {
      throw StateError('Wallpaper image is not ready.');
    }

    final target = widget.platformTargetSize;
    late final int outW;
    late final int outH;
    if (_isCanvasMode && target != null) {
      outW = max(1, target.widthPx);
      outH = max(1, target.heightPx);
    } else {
      final screenSize = MediaQuery.sizeOf(context);
      final dpr = MediaQuery.devicePixelRatioOf(context);
      outW = max(1, (screenSize.width * dpr).round());
      outH = max(1, (screenSize.height * dpr).round());
    }

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble()),
    );
    final outputRect = Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble());
    canvas.clipRect(outputRect);
    canvas.drawRect(outputRect, Paint()..color = Colors.black);

    final cropCenter = _cropSize.center(Offset.zero);
    final ratioX = outW / _cropSize.width;
    final ratioY = outH / _cropSize.height;
    final centerX = (cropCenter.dx + _offset.dx) * ratioX;
    final centerY = (cropCenter.dy + _offset.dy) * ratioY;
    final imageDstRect = Rect.fromCenter(
      center: Offset(centerX, centerY),
      width: image.width * _scale * ratioX,
      height: image.height * _scale * ratioY,
    );

    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      imageDstRect,
      Paint()..filterQuality = FilterQuality.high,
    );

    final picture = recorder.endRecording();
    final rendered = await picture.toImage(outW, outH);
    final data = await rendered.toByteData(format: ui.ImageByteFormat.png);
    rendered.dispose();
    if (data == null) {
      throw StateError('Wallpaper export failed.');
    }

    final outputDir = await getTemporaryDirectory();
    final outputPath =
        '${outputDir.path}${Platform.pathSeparator}wallpaper_export_${DateTime.now().millisecondsSinceEpoch}.png';
    final outputFile = File(outputPath);
    await outputFile.writeAsBytes(data.buffer.asUint8List(), flush: true);
    return outputPath;
  }

  void _onScaleStart(ScaleStartDetails details) {
    if (_image == null || _cropSize.isEmpty) return;
    _gestureStartScale = _scale;
    final center = _cropSize.center(Offset.zero);
    _gestureContentPoint =
        (details.localFocalPoint - center - _offset) / _gestureStartScale;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (_image == null || _cropSize.isEmpty || _exporting) return;
    final center = _cropSize.center(Offset.zero);
    final nextScale =
        (_gestureStartScale * details.scale).clamp(_minScale, _maxScale)
            as double;
    final rawOffset =
        details.localFocalPoint - center - (_gestureContentPoint * nextScale);

    setState(() {
      _scale = nextScale;
      _offset = _clampOffset(rawOffset, nextScale);
    });
  }

  Future<void> _onApply() async {
    if (_exporting || _image == null) return;
    setState(() => _exporting = true);
    try {
      final outputPath = await _exportCurrentWallpaper();
      if (!mounted) return;
      Navigator.pop(
        context,
        WallpaperSetupResult(
          applied: true,
          outputPath: outputPath,
          style: _isCanvasMode ? WallpaperFit.fill : _style,
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not prepare wallpaper image.')),
      );
      setState(() => _exporting = false);
    }
  }

  void _onCancel() {
    Navigator.pop(
      context,
      WallpaperSetupResult(applied: false, outputPath: null, style: _style),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final targetAspect = _previewAspectRatio(screenSize);

    return Scaffold(
      backgroundColor: const Color(0xFF040A18),
      appBar: AppBar(
        title: const Text('Wallpaper Setup'),
        actions: [
          TextButton(
            onPressed: _exporting ? null : _onCancel,
            child: const Text('Cancel'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final bounds = Size(
                      constraints.maxWidth,
                      constraints.maxHeight,
                    );
                    final cropRect = _largestRectWithAspect(
                      bounds,
                      targetAspect,
                    );
                    final cropSize = cropRect.size;

                    if ((_cropSize.width - cropSize.width).abs() > 0.5 ||
                        (_cropSize.height - cropSize.height).abs() > 0.5) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (!mounted) return;
                        _cropSize = cropSize;
                        _applyTransformConstraints();
                      });
                    }

                    return Align(
                      alignment: Alignment.center,
                      child: Container(
                        width: cropSize.width,
                        height: cropSize.height,
                        decoration: BoxDecoration(
                          color: Colors.black,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: AppTheme.accent.withValues(alpha: 0.32),
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: _buildCropSurface(),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _isCanvasMode
                        ? 'Pinch to zoom, drag to reposition. Black canvas is your final wallpaper.'
                        : 'Pinch to zoom and drag to reposition.',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: Colors.white70),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Zoom',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: Colors.white70),
                  ),
                  Slider(
                    value: _scale.clamp(_minScale, _maxScale),
                    min: _minScale,
                    max: _maxScale,
                    onChanged: (_image == null || _exporting)
                        ? null
                        : (value) {
                            setState(() {
                              _scale = value;
                              _offset = _clampOffset(_offset, _scale);
                            });
                          },
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: (_loading || _image == null || _exporting)
                          ? null
                          : _onApply,
                      icon: _exporting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.wallpaper),
                      label: Text(
                        _exporting
                            ? 'Preparing wallpaper...'
                            : 'Apply Wallpaper',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCropSurface() {
    if (_loading) {
      return const Center(
        child: SpaceLoadingIndicator(
          size: SpaceIndicatorSize.small,
          semanticLabel: 'Preparing wallpaper editor',
        ),
      );
    }

    if (_loadError != null || _image == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            _loadError ?? 'Could not load image.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70),
          ),
        ),
      );
    }

    final image = _image!;
    return GestureDetector(
      onScaleStart: _onScaleStart,
      onScaleUpdate: _onScaleUpdate,
      child: Container(
        color: Colors.black,
        child: Center(
          child: Transform.translate(
            offset: _offset,
            child: Transform.scale(
              scale: _scale,
              child: SizedBox(
                width: image.width.toDouble(),
                height: image.height.toDouble(),
                child: RawImage(image: image),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
