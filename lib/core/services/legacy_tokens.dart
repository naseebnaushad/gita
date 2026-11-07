import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

import 'token_store.dart';

/// Tokens saved by Gita versions that used flutter_secure_storage.
abstract class LegacyTokens {
  /// Moves every old token into [store] (keeping any newer token already
  /// there) and returns how many were moved. Never throws.
  Future<int> migrateAll(TokenStore store, Iterable<String> profileIds);

  /// Forgets the old copy of one profile's token, so it can't come back.
  Future<void> forget(String profileId);
}

/// macOS and Linux: the plugin keeps tokens in the Keychain / libsecret,
/// which it reads safely, so it is used as it is.
class PluginLegacyTokens implements LegacyTokens {
  PluginLegacyTokens([FlutterSecureStorage? storage])
      : _storage = storage ??
            // useDataProtectionKeyChain requires a keychain-access-groups
            // entitlement, which requires signing with a real Apple
            // development certificate. The file-based keychain doesn't.
            const FlutterSecureStorage(
              mOptions: MacOsOptions(useDataProtectionKeyChain: false),
            );

  final FlutterSecureStorage _storage;

  @override
  Future<int> migrateAll(TokenStore store, Iterable<String> profileIds) async {
    var moved = 0;
    for (final id in profileIds) {
      try {
        final old = await _storage.read(key: TokenStore.keyFor(id));
        if (old == null) continue;
        if (await store.readToken(id) == null) {
          await store.saveToken(id, old);
          moved++;
        }
        await _storage.delete(key: TokenStore.keyFor(id));
      } catch (_) {
        // The old store is unavailable; leave the token where it is.
      }
    }
    return moved;
  }

  @override
  Future<void> forget(String profileId) async {
    try {
      await _storage.delete(key: TokenStore.keyFor(profileId));
    } catch (_) {
      // Nothing to clean up, or the old store is unavailable.
    }
  }
}

/// Windows: the plugin kept every value in one DPAPI-encrypted JSON file,
/// `flutter_secure_storage.dat`, and deleted the whole file whenever it
/// couldn't decrypt it — even on a passing error — losing every token.
///
/// So Gita no longer lets the plugin touch that file. It decrypts the file
/// itself, copies the tokens into Credential Manager, and then renames the
/// file to `.migrated` instead of deleting it. A file it can't read is left
/// exactly as it is, to try again next start.
class DpapiLegacyTokens implements LegacyTokens {
  DpapiLegacyTokens({required this.file, Uint8List? Function(Uint8List)? unprotect})
      : _unprotect = unprotect ?? dpapiUnprotect;

  /// Where earlier Gita builds kept the file:
  /// `%APPDATA%\<CompanyName>\<ProductName>\flutter_secure_storage.dat`,
  /// taken from the Windows runner's version resource.
  factory DpapiLegacyTokens.forThisUser() {
    final appData = Platform.environment['APPDATA'] ?? '';
    return DpapiLegacyTokens(
      file: File(p.join(appData, 'net.nsbglobal.gita', 'gita', 'flutter_secure_storage.dat')),
    );
  }

  final File file;
  final Uint8List? Function(Uint8List) _unprotect;

  File get backup => File('${file.path}.migrated');

  @override
  Future<int> migrateAll(TokenStore store, Iterable<String> profileIds) async {
    final values = _read();
    if (values == null) return 0;

    const prefix = 'gita.token.';
    var moved = 0;
    try {
      for (final entry in values.entries) {
        if (!entry.key.startsWith(prefix)) continue;
        final id = entry.key.substring(prefix.length);
        if (await store.readToken(id) == null) {
          await store.saveToken(id, entry.value);
          moved++;
        }
      }
    } catch (_) {
      // Credential Manager refused; keep the file to try again next start.
      return moved;
    }
    _retire();
    return moved;
  }

  @override
  Future<void> forget(String profileId) async {
    // The file is retired as a whole once its tokens are moved; until then
    // it is never rewritten, so there is nothing to do per profile.
  }

  /// The file's values, or null when there is no file or it can't be read.
  Map<String, String>? _read() {
    final Uint8List bytes;
    try {
      if (!file.existsSync()) return null;
      bytes = file.readAsBytesSync();
    } on FileSystemException {
      return null;
    }
    final plain = _unprotect(bytes);
    if (plain == null) return null;
    try {
      final decoded = jsonDecode(utf8.decode(plain));
      if (decoded is! Map) return null;
      return {
        for (final e in decoded.entries)
          if (e.key is String && e.value is String) e.key as String: e.value as String,
      };
    } on FormatException {
      return null;
    }
  }

  void _retire() {
    try {
      if (backup.existsSync()) backup.deleteSync();
      file.renameSync(backup.path);
    } on FileSystemException {
      // Still readable next time; migrating again keeps newer tokens.
    }
  }
}

/// Decrypts a DPAPI blob made for the current Windows user. Null if it
/// can't be decrypted (another user, another machine, a damaged file).
Uint8List? dpapiUnprotect(Uint8List encrypted) {
  if (!Platform.isWindows) return null;
  return using((arena) {
    final input = arena<Uint8>(encrypted.length);
    input.asTypedList(encrypted.length).setAll(0, encrypted);
    final inBlob = arena<CRYPT_INTEGER_BLOB>()
      ..ref.cbData = encrypted.length
      ..ref.pbData = input;
    final outBlob = arena<CRYPT_INTEGER_BLOB>();
    if (CryptUnprotectData(inBlob, nullptr, nullptr, nullptr, nullptr, 0, outBlob) == 0 ||
        outBlob.ref.pbData == nullptr) {
      return null;
    }
    try {
      return Uint8List.fromList(outBlob.ref.pbData.asTypedList(outBlob.ref.cbData));
    } finally {
      LocalFree(outBlob.ref.pbData);
    }
  });
}

/// Encrypts [plain] for the current Windows user, the way the old plugin
/// did. Used by tests to make a real legacy file.
Uint8List? dpapiProtect(Uint8List plain) {
  if (!Platform.isWindows) return null;
  return using((arena) {
    final input = arena<Uint8>(plain.length);
    input.asTypedList(plain.length).setAll(0, plain);
    final inBlob = arena<CRYPT_INTEGER_BLOB>()
      ..ref.cbData = plain.length
      ..ref.pbData = input;
    final outBlob = arena<CRYPT_INTEGER_BLOB>();
    if (CryptProtectData(inBlob, nullptr, nullptr, nullptr, nullptr, 0, outBlob) == 0) {
      return null;
    }
    try {
      return Uint8List.fromList(outBlob.ref.pbData.asTypedList(outBlob.ref.cbData));
    } finally {
      LocalFree(outBlob.ref.pbData);
    }
  });
}
