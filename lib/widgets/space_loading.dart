import 'package:flutter/material.dart';

import '../ui/app_theme.dart';

enum SpaceIndicatorSize { tiny, small, medium, large }

extension on SpaceIndicatorSize {
  double get diameter {
    switch (this) {
      case SpaceIndicatorSize.tiny:
        return 16;
      case SpaceIndicatorSize.small:
        return 24;
      case SpaceIndicatorSize.medium:
        return 36;
      case SpaceIndicatorSize.large:
        return 56;
    }
  }

  double get strokeWidth {
    switch (this) {
      case SpaceIndicatorSize.tiny:
        return 1.8;
      case SpaceIndicatorSize.small:
        return 2.0;
      case SpaceIndicatorSize.medium:
        return 2.4;
      case SpaceIndicatorSize.large:
        return 2.8;
    }
  }
}

/// Shared cosmic spinner tuned for subtle motion and low visual noise.
class SpaceLoadingIndicator extends StatefulWidget {
  const SpaceLoadingIndicator({
    super.key,
    this.size = SpaceIndicatorSize.medium,
    this.semanticLabel = 'Loading',
  });

  final SpaceIndicatorSize size;
  final String semanticLabel;

  @override
  State<SpaceLoadingIndicator> createState() => _SpaceLoadingIndicatorState();
}

class _SpaceLoadingIndicatorState extends State<SpaceLoadingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _orbit = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  )..repeat();

  @override
  void dispose() {
    _orbit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.size.diameter;
    final ringColor = AppTheme.accentSoft.withValues(alpha: 0.92);
    final trackColor = AppTheme.accent.withValues(alpha: 0.18);

    return Semantics(
      label: widget.semanticLabel,
      container: true,
      liveRegion: true,
      child: SizedBox(
        width: d,
        height: d,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: d * 0.76,
              height: d * 0.76,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    AppTheme.accent.withValues(alpha: 0.26),
                    Colors.transparent,
                  ],
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.accent.withValues(alpha: 0.14),
                    blurRadius: d * 0.34,
                    spreadRadius: 1.2,
                  ),
                ],
              ),
            ),
            RotationTransition(
              turns: _orbit,
              child: SizedBox(
                width: d,
                height: d,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: d * 0.86,
                      height: d * 0.86,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: AppTheme.accent.withValues(alpha: 0.22),
                          width: 1.0,
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.topCenter,
                      child: Container(
                        width: d * 0.11,
                        height: d * 0.11,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppTheme.accentSoft,
                          boxShadow: [
                            BoxShadow(
                              color: AppTheme.accentSoft.withValues(
                                alpha: 0.45,
                              ),
                              blurRadius: d * 0.14,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            CircularProgressIndicator(
              strokeWidth: widget.size.strokeWidth,
              color: ringColor,
              backgroundColor: trackColor,
            ),
          ],
        ),
      ),
    );
  }
}

class SpaceLoadingSurface extends StatelessWidget {
  const SpaceLoadingSurface({
    super.key,
    this.message,
    this.size = SpaceIndicatorSize.medium,
    this.withCosmicGradient = true,
    this.padding = const EdgeInsets.all(24),
  });

  final String? message;
  final SpaceIndicatorSize size;
  final bool withCosmicGradient;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(
      context,
    ).textTheme.bodyLarge?.copyWith(color: Colors.white70);

    final content = Center(
      child: Padding(
        padding: padding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SpaceLoadingIndicator(size: size),
            if (message != null && message!.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(message!, style: textStyle, textAlign: TextAlign.center),
            ],
          ],
        ),
      ),
    );

    if (!withCosmicGradient) return content;

    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0.1, -0.3),
          radius: 1.18,
          colors: [Color(0xFF132040), Color(0xFF090F1E), Color(0xFF050912)],
        ),
      ),
      child: content,
    );
  }
}

class SpaceImagePlaceholder extends StatelessWidget {
  const SpaceImagePlaceholder({
    super.key,
    this.width,
    this.height,
    this.borderRadius = BorderRadius.zero,
    this.message,
    this.showIndicator = true,
    this.indicatorSize = SpaceIndicatorSize.small,
  });

  final double? width;
  final double? height;
  final BorderRadius borderRadius;
  final String? message;
  final bool showIndicator;
  final SpaceIndicatorSize indicatorSize;

  @override
  Widget build(BuildContext context) {
    final child = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0D172C), Color(0xFF0B1222)],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showIndicator) SpaceLoadingIndicator(size: indicatorSize),
            if (message != null && message!.trim().isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                message!,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Colors.white60),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );

    if (borderRadius == BorderRadius.zero) return child;
    return ClipRRect(borderRadius: borderRadius, child: child);
  }
}

class SpaceProgressBadge extends StatelessWidget {
  const SpaceProgressBadge({
    super.key,
    required this.current,
    required this.total,
    this.label = 'Progress',
  });

  final int current;
  final int total;
  final String label;

  @override
  Widget build(BuildContext context) {
    final safeTotal = total <= 0 ? 1 : total;
    final safeCurrent = current.clamp(0, safeTotal);
    final value = safeCurrent / safeTotal;

    return Semantics(
      label: '$label $safeCurrent of $safeTotal',
      value: '${(value * 100).round()} percent',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.44),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.accent.withValues(alpha: 0.2)),
        ),
        child: SizedBox(
          width: 176,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '$label $safeCurrent/$safeTotal',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.white70,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                  minHeight: 3.5,
                  value: value,
                  backgroundColor: AppTheme.accent.withValues(alpha: 0.14),
                  valueColor: const AlwaysStoppedAnimation(AppTheme.accentSoft),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
