import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'token_store.dart';

/// The app's view of [TokenStore], plus a one-time move of tokens saved by
/// earlier Gita versions.
///
/// Earlier versions kept tokens in flutter_secure_storage. On Windows that
/// is an encrypted file only the app itself can read, so the `gita`
/// credential helper couldn't use it. The first time a token is read it is
/// moved into the shared OS credential store and the old copy is removed.
class SecureTokenService {
  SecureTokenService({TokenStore? store, FlutterSecureStorage? legacyStorage})
      : _store = store ?? TokenStore(),
        _legacy = legacyStorage ??
            // useDataProtectionKeyChain requires a keychain-access-groups
            // entitlement, which in turn requires signing with a real Apple
            // development certificate — unavailable for local/CI ad-hoc
            // builds. The legacy file-based keychain works without it.
            const FlutterSecureStorage(
              mOptions: MacOsOptions(useDataProtectionKeyChain: false),
            );

  final TokenStore _store;
  final FlutterSecureStorage _legacy;

  TokenStore get store => _store;

  Future<void> saveToken(String profileId, String token) async {
    await _store.saveToken(profileId, token);
    await _deleteLegacy(profileId);
  }

  Future<String?> readToken(String profileId) async {
    final token = await _store.readToken(profileId);
    if (token != null) return token;
    return _migrateLegacy(profileId);
  }

  Future<void> deleteToken(String profileId) async {
    await _store.deleteToken(profileId);
    await _deleteLegacy(profileId);
  }

  Future<bool> hasToken(String profileId) async =>
      (await readToken(profileId)) != null;

  Future<String?> _migrateLegacy(String profileId) async {
    final String? legacy;
    try {
      legacy = await _legacy.read(key: TokenStore.keyFor(profileId));
    } catch (_) {
      return null;
    }
    if (legacy == null) return null;
    await _store.saveToken(profileId, legacy);
    await _deleteLegacy(profileId);
    return legacy;
  }

  Future<void> _deleteLegacy(String profileId) async {
    try {
      await _legacy.delete(key: TokenStore.keyFor(profileId));
    } catch (_) {
      // Nothing to clean up, or the old store is unavailable.
    }
  }
}
