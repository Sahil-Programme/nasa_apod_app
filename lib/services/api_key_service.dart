import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secure storage wrapper for NASA API key material.
class ApiKeyService {
  static const _k = 'nasa_api_key';
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  /// Returns the saved NASA API key, if one exists.
  Future<String?> read() => _storage.read(key: _k);

  /// Persists the NASA API key in secure platform storage.
  Future<void> save(String key) => _storage.write(key: _k, value: key);

  /// Deletes the saved NASA API key.
  Future<void> clear() => _storage.delete(key: _k);
}
