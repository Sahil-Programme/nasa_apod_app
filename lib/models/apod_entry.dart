import 'dart:convert';

/// Domain model representing a single APOD payload.
///
/// The NASA endpoint can return image and video entries. This model keeps raw
/// fields plus convenience getters used by UI and caching layers.
class ApodEntry {
  const ApodEntry({
    required this.date,
    required this.title,
    required this.explanation,
    required this.mediaType,
    this.url,
    this.hdurl,
    this.thumbnailUrl,
    this.copyright,
  });

  final DateTime date;
  final String title;
  final String explanation;
  final String mediaType;
  final String? url;
  final String? hdurl;
  final String? thumbnailUrl;
  final String? copyright;

  static const Set<String> _imageExt = {
    '.jpg',
    '.jpeg',
    '.png',
    '.gif',
    '.webp',
    '.bmp',
    '.tif',
    '.tiff',
    '.avif',
  };
  static const Set<String> _videoExt = {
    '.mp4',
    '.mov',
    '.m4v',
    '.webm',
    '.mkv',
    '.avi',
  };
  static const Set<String> _audioExt = {
    '.mp3',
    '.wav',
    '.ogg',
    '.m4a',
    '.flac',
    '.aac',
  };

  String get normalizedMediaType => mediaType.trim().toLowerCase();

  /// True when APOD payload is image-based media.
  bool get isImage => normalizedMediaType == 'image';

  /// True when APOD payload is video-based media.
  bool get isVideo => normalizedMediaType == 'video';

  /// True when APOD payload is explicitly audio-based media.
  bool get isAudio => normalizedMediaType == 'audio';

  /// Best-effort display image URL preference.
  String? get bestImageUrl => hdurl ?? url ?? thumbnailUrl;

  /// Slideshow-optimized image source (prefer non-HD for faster first paint).
  String? get slideshowImageUrl => url ?? hdurl ?? thumbnailUrl;

  String? get primaryUrl => url ?? hdurl ?? thumbnailUrl;

  String? get launchUrl => primaryUrl;

  bool get looksLikeImage =>
      _looksLike(url, _imageExt) ||
      _looksLike(hdurl, _imageExt) ||
      _looksLike(thumbnailUrl, _imageExt);

  bool get looksLikeVideo =>
      _looksLike(url, _videoExt) ||
      _looksLike(hdurl, _videoExt) ||
      _looksLikeYouTube(url);

  bool get looksLikeAudio =>
      _looksLike(url, _audioExt) || _looksLike(hdurl, _audioExt);

  bool get shouldRenderAsImage => isImage || (!isVideo && looksLikeImage);

  bool get shouldRenderAsVideo =>
      isVideo || (!shouldRenderAsImage && looksLikeVideo);

  bool get shouldRenderAsAudio =>
      isAudio ||
      (!shouldRenderAsImage && !shouldRenderAsVideo && looksLikeAudio);

  factory ApodEntry.fromJson(Map<String, dynamic> json) {
    return ApodEntry(
      date: DateTime.parse(json['date'] as String),
      title: (json['title'] ?? '') as String,
      explanation: (json['explanation'] ?? '') as String,
      mediaType: (json['media_type'] ?? '') as String,
      url: json['url'] as String?,
      hdurl: json['hdurl'] as String?,
      thumbnailUrl: json['thumbnail_url'] as String?,
      copyright: json['copyright'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'date': _fmt(date),
    'title': title,
    'explanation': explanation,
    'media_type': mediaType,
    'url': url,
    'hdurl': hdurl,
    'thumbnail_url': thumbnailUrl,
    'copyright': copyright,
  };

  /// Formats to APOD-compatible yyyy-mm-dd date string.
  static String _fmt(DateTime d) => d.toIso8601String().split('T').first;

  /// Helper for persisting lists to JSON storage.
  static String encodeList(List<ApodEntry> list) =>
      jsonEncode(list.map((e) => e.toJson()).toList());

  static bool _looksLike(String? candidate, Set<String> extensions) {
    if (candidate == null || candidate.trim().isEmpty) return false;
    final uri = Uri.tryParse(candidate);
    if (uri == null) return false;
    final p = uri.path.toLowerCase();
    for (final ext in extensions) {
      if (p.endsWith(ext)) return true;
    }
    return false;
  }

  static bool _looksLikeYouTube(String? candidate) {
    if (candidate == null || candidate.trim().isEmpty) return false;
    final uri = Uri.tryParse(candidate);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    return host.contains('youtube.com') || host.contains('youtu.be');
  }
}
