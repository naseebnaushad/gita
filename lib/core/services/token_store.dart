import 'keychain_store.dart';

/// GitHub access tokens per profile, kept in the OS credential store.
///
/// Pure Dart so the desktop app and the `gita credential` helper share it.
/// Tokens are never written to Gita's JSON files or exported.
class TokenStore {
  TokenStore({KeychainStore? keychain})
      : keychain = keychain ?? KeychainStore.forPlatform();

  final KeychainStore keychain;

  static String keyFor(String profileId) => 'gita.token.$profileId';

  Future<String?> readToken(String profileId) =>
      keychain.read(keyFor(profileId));

  Future<void> saveToken(String profileId, String token) =>
      keychain.write(keyFor(profileId), token);

  Future<void> deleteToken(String profileId) =>
      keychain.delete(keyFor(profileId));

  Future<bool> hasToken(String profileId) async =>
      (await readToken(profileId)) != null;
}
