/// Slideshow traversal direction from the chosen start date.
enum SlideshowDirection { forward, backward }

/// Input bundle captured before launching slideshow playback.
class SlideshowLaunchConfig {
  const SlideshowLaunchConfig({
    required this.startDate,
    required this.direction,
    required this.runDuration,
  });

  final DateTime startDate;
  final SlideshowDirection direction;
  final Duration runDuration;
}
