/// Native token storage: flutter_secure_storage 11 (ARCHITECTURE §7.6).
library;

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'token_store.dart';

/// [TokenBackend] over the platform keystore. The v11 Android default is its
/// own cipher (`encryptedSharedPreferences` no longer exists);
/// `first_unlock_this_device` keeps tokens out of iCloud/encrypted backups.
class SecureStorageTokenBackend implements TokenBackend {
  SecureStorageTokenBackend([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(),
            iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
          );

  final FlutterSecureStorage _storage;

  /// A keystore that cannot decrypt its entry (restored device, key
  /// invalidated) reads as "no tokens": the user signs in again instead of
  /// the app failing at start-up.
  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } on PlatformException {
      try {
        await _storage.delete(key: key);
      } on PlatformException {
        // Nothing more to do.
      }
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

TokenStore createPlatformTokenStore() => BackendTokenStore(SecureStorageTokenBackend());
