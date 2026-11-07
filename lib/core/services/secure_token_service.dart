import 'dart:io';

import 'legacy_tokens.dart';
import 'token_store.dart';

/// The app's view of [TokenStore], plus a one-time move of tokens saved by
/// earlier Gita versions.
///
/// Earlier versions kept tokens in flutter_secure_storage. On Windows that
/// is an encrypted file only the app itself can read, so the `gita`
/// credential helper couldn't use it. [migrateLegacy] moves them into the
/// shared OS credential store; it runs at startup and again before the
/// first read.
class SecureTokenService {
  SecureTokenService({TokenStore? store, LegacyTokens? legacy})
      : _store = store ?? TokenStore(),
        _legacy = legacy ??
            (Platform.isWindows ? DpapiLegacyTokens.forThisUser() : PluginLegacyTokens());

  final TokenStore _store;
  final LegacyTokens _legacy;
  final _checked = <String>{};

  TokenStore get store => _store;

  /// Moves old tokens for [profileIds] (on Windows: every old token) into
  /// the OS store. Each profile is only looked up once. Never throws.
  Future<int> migrateLegacy(Iterable<String> profileIds) {
    final todo = profileIds.where(_checked.add).toList();
    // Runs one move at a time, and a read waits for any move already
    // running, so it never misses a token that is on its way.
    final run = _queue.then<int>((_) => todo.isEmpty ? 0 : _legacy.migrateAll(_store, todo));
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<void> _queue = Future.value();

  Future<void> saveToken(String profileId, String token) async {
    await _store.saveToken(profileId, token);
    await _legacy.forget(profileId);
  }

  Future<String?> readToken(String profileId) async {
    await migrateLegacy([profileId]);
    return _store.readToken(profileId);
  }

  Future<void> deleteToken(String profileId) async {
    await _store.deleteToken(profileId);
    await _legacy.forget(profileId);
  }

  Future<bool> hasToken(String profileId) async =>
      (await readToken(profileId)) != null;
}
