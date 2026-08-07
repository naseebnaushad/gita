import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Stores Git access tokens (PATs) in the OS credential store — Keychain on
/// macOS, Credential Manager on Windows, libsecret on Linux. Tokens are keyed
/// by profile id and never written to the plain JSON store or exported with
/// profile/rule data (see plan §16 — no private key material in exports).
class SecureTokenService {
  const SecureTokenService({FlutterSecureStorage? storage})
      : _storage = storage ??
            // useDataProtectionKeyChain requires a keychain-access-groups
            // entitlement, which in turn requires signing with a real Apple
            // development certificate — unavailable for local/CI ad-hoc
            // builds. The legacy file-based keychain works without it.
            const FlutterSecureStorage(
              mOptions: MacOsOptions(useDataProtectionKeyChain: false),
            );

  final FlutterSecureStorage _storage;

  String _keyFor(String profileId) => 'gita.token.$profileId';

  Future<void> saveToken(String profileId, String token) {
    return _storage.write(key: _keyFor(profileId), value: token);
  }

  Future<String?> readToken(String profileId) {
    return _storage.read(key: _keyFor(profileId));
  }

  Future<void> deleteToken(String profileId) {
    return _storage.delete(key: _keyFor(profileId));
  }

  Future<bool> hasToken(String profileId) async {
    return (await readToken(profileId)) != null;
  }
}
