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

  /// True when APOD payload is image-based media.
  bool get isImage => mediaType == 'image';

  /// True when APOD payload is video-based media.
  bool get isVideo => mediaType == 'video';

  /// Best-effort display image URL preference.
  String? get bestImageUrl => hdurl ?? url ?? thumbnailUrl;

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
}
