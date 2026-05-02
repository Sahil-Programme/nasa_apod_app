import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/apod_entry.dart';

enum ApodDateSearchDirection { backward, forward, nearest }

/// Typed API exception surfaced to UI for user-friendly handling.
class NasaApiException implements Exception {
  const NasaApiException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// NASA APOD REST client.
class NasaApiService {
  static const _base = 'https://api.nasa.gov/planetary/apod';
  static final DateTime firstApodDate = DateTime(1995, 6, 16);

  /// Validates credentials by issuing a minimal APOD request.
  Future<void> validateApiKey(String key) async {
    await fetchToday(key);
  }

  /// Returns today's APOD entry.
  Future<ApodEntry> fetchToday(String key) async => _fetchOne(key, {});

  /// Returns APOD for an explicit calendar day.
  Future<ApodEntry> fetchByDate(String key, DateTime date) async =>
      _fetchOne(key, {'date': _fmt(date)});

  /// Resolves the nearest APOD to [target] using a directional search strategy.
  Future<ApodEntry> fetchNearestAvailableByDate(
    String key,
    DateTime target, {
    ApodDateSearchDirection direction = ApodDateSearchDirection.backward,
    int maxSearchDays = 31,
    DateTime? minDate,
    DateTime? maxDate,
  }) async {
    final minAllowed = _stripTime(minDate ?? firstApodDate);
    final maxAllowed = _stripTime(maxDate ?? DateTime.now().toUtc());
    if (maxAllowed.isBefore(minAllowed)) {
      throw const NasaApiException('Invalid APOD date window.');
    }

    var seed = _stripTime(target);
    if (seed.isBefore(minAllowed)) seed = minAllowed;
    if (seed.isAfter(maxAllowed)) seed = maxAllowed;

    final candidates = <DateTime>[];
    final seen = <String>{};
    void push(DateTime d) {
      if (d.isBefore(minAllowed) || d.isAfter(maxAllowed)) return;
      final keyDate = _fmt(d);
      if (seen.add(keyDate)) candidates.add(d);
    }

    switch (direction) {
      case ApodDateSearchDirection.backward:
        for (var offset = 0; offset <= maxSearchDays; offset++) {
          push(seed.subtract(Duration(days: offset)));
        }
        break;
      case ApodDateSearchDirection.forward:
        for (var offset = 0; offset <= maxSearchDays; offset++) {
          push(seed.add(Duration(days: offset)));
        }
        break;
      case ApodDateSearchDirection.nearest:
        push(seed);
        for (var offset = 1; offset <= maxSearchDays; offset++) {
          push(seed.subtract(Duration(days: offset)));
          push(seed.add(Duration(days: offset)));
        }
        break;
    }

    Object? lastError;
    for (final date in candidates) {
      try {
        return await fetchByDate(key, date);
      } catch (e) {
        lastError = e;
      }
    }

    if (lastError is NasaApiException) {
      throw lastError;
    }
    throw NasaApiException(
      'No APOD entry was found within $maxSearchDays day(s) of ${_fmt(seed)}.',
    );
  }

  /// Fetches a random APOD entry via count=1 and unwraps the list payload.
  Future<ApodEntry> fetchRandom(String key) async {
    final list = await _fetchMany(key, {'count': '1'});
    return list.first;
  }

  /// Fetches APOD entries for an inclusive start/end date range.
  Future<List<ApodEntry>> fetchRange(
    String key,
    DateTime start,
    DateTime end,
  ) async =>
      _fetchMany(key, {'start_date': _fmt(start), 'end_date': _fmt(end)});

  /// Executes a single-object APOD request and maps known API-level errors.
  Future<ApodEntry> _fetchOne(String key, Map<String, String> q) async {
    final res = await _call(key, q);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (body['code'] != null) {
      throw NasaApiException('${body['msg'] ?? 'API error'}');
    }
    return ApodEntry.fromJson(body);
  }

  /// Executes a list-capable APOD request and normalizes both object/list payloads.
  Future<List<ApodEntry>> _fetchMany(String key, Map<String, String> q) async {
    final res = await _call(key, q);
    final decoded = jsonDecode(res.body);
    if (decoded is Map<String, dynamic>) {
      if (decoded['code'] != null) {
        throw NasaApiException('${decoded['msg'] ?? 'API error'}');
      }
      return [ApodEntry.fromJson(decoded)];
    }
    return (decoded as List)
        .map((e) => ApodEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Shared HTTP execution path with transport-level error mapping.
  Future<http.Response> _call(String key, Map<String, String> q) async {
    final uri = Uri.parse(
      _base,
    ).replace(queryParameters: {'api_key': key, 'thumbs': 'true', ...q});

    final res = await http.get(uri);
    if (res.statusCode == 429) {
      throw const NasaApiException('NASA API rate limit reached (429).');
    }
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw const NasaApiException('Invalid API key.');
    }
    if (res.statusCode >= 400) {
      final body = res.body;
      if (body.isNotEmpty) {
        try {
          final decoded = jsonDecode(body);
          if (decoded is Map<String, dynamic>) {
            final msg =
                decoded['msg'] ?? decoded['error'] ?? decoded['message'];
            if (msg != null && msg.toString().trim().isNotEmpty) {
              throw NasaApiException(msg.toString());
            }
          }
        } catch (_) {
          // Fall back to status-based message when response is not JSON.
        }
      }
      throw NasaApiException('Request failed (${res.statusCode}).');
    }
    return res;
  }

  String _fmt(DateTime d) => d.toIso8601String().split('T').first;

  DateTime _stripTime(DateTime d) => DateTime(d.year, d.month, d.day);
}
