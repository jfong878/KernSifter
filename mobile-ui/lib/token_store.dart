/// Keystore-backed token storage for the KernSifter mobile client.
///
/// The bearer token is a credential for the user's synced data, so it belongs in
/// the platform keystore (Android Keystore / iOS Keychain) and nowhere else.
/// In particular it must never sit in `shared_preferences`, which is plain XML
/// on disk, nor in a log line.
///
/// `flutter_secure_storage` defaults to EncryptedSharedPreferences on Android
/// and the Keychain on iOS. If you tune [FlutterSecureStorage] options, keep
/// both of those properties.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'auth.dart';

/// Stores the sync token via `flutter_secure_storage`.
class SecureTokenStore implements TokenStore {
  SecureTokenStore({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  /// Namespaced so a future second credential cannot collide with this one.
  static const String storageKey = 'kernsifter.sync.access_token';

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: storageKey);

  @override
  Future<void> write(String token) => _storage.write(key: storageKey, value: token);

  @override
  Future<void> clear() => _storage.delete(key: storageKey);
}
