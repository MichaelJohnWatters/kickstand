// Thin wrapper around flutter_secure_storage. On mobile this is Keychain /
// Keystore; on web it falls back to localStorage. Dev-grade — production
// web would use HttpOnly cookies, but localStorage is acceptable for now.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class TokenStorage {
  static const _key = 'ks.auth.token';
  final _store = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Future<String?> read() => _store.read(key: _key);
  Future<void> write(String token) => _store.write(key: _key, value: token);
  Future<void> clear() => _store.delete(key: _key);
}
