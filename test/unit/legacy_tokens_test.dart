import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gita/core/services/keychain_store.dart';
import 'package:gita/core/services/legacy_tokens.dart';
import 'package:gita/core/services/secure_token_service.dart';
import 'package:gita/core/services/token_store.dart';
import 'package:path/path.dart' as p;

/// A keychain that refuses every write, like a locked credential store.
class _RefusingKeychain extends InMemoryKeychainStore {
  @override
  Future<void> write(String key, String value) async =>
      throw KeychainException('locked');
}

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('gita_legacy_');
    file = File(p.join(dir.path, 'flutter_secure_storage.dat'));
  });

  tearDown(() => dir.deleteSync(recursive: true));

  // A stand-in for DPAPI: "encrypted" is the JSON reversed.
  Uint8List fakeProtect(String json) => Uint8List.fromList(utf8.encode(json).reversed.toList());
  Uint8List? fakeUnprotect(Uint8List bytes) => Uint8List.fromList(bytes.reversed.toList());

  DpapiLegacyTokens legacy({Uint8List? Function(Uint8List)? unprotect}) =>
      DpapiLegacyTokens(file: file, unprotect: unprotect ?? fakeUnprotect);

  group('DpapiLegacyTokens', () {
    test('moves every token into the store and keeps the file as a backup', () async {
      file.writeAsBytesSync(fakeProtect(jsonEncode({
        'gita.token.work': 'gho_work',
        'gita.token.home': 'gho_home',
        'something.else': 'x',
      })));
      final store = TokenStore(keychain: InMemoryKeychainStore());

      final moved = await legacy().migrateAll(store, const []);

      expect(moved, 2);
      expect(await store.readToken('work'), 'gho_work');
      expect(await store.readToken('home'), 'gho_home');
      expect(file.existsSync(), isFalse);
      expect(File('${file.path}.migrated').existsSync(), isTrue);
    });

    test('never replaces a newer token already in the store', () async {
      file.writeAsBytesSync(fakeProtect(jsonEncode({'gita.token.work': 'old'})));
      final store = TokenStore(keychain: InMemoryKeychainStore({'gita.token.work': 'new'}));

      expect(await legacy().migrateAll(store, const []), 0);
      expect(await store.readToken('work'), 'new');
    });

    test('a file it cannot decrypt is left exactly as it is', () async {
      file.writeAsBytesSync([1, 2, 3]);
      final store = TokenStore(keychain: InMemoryKeychainStore());

      expect(await legacy(unprotect: (_) => null).migrateAll(store, const []), 0);
      expect(file.readAsBytesSync(), [1, 2, 3]);
      expect(File('${file.path}.migrated').existsSync(), isFalse);
    });

    test('a file that is not JSON is left alone too', () async {
      file.writeAsBytesSync(fakeProtect('not json'));

      await legacy().migrateAll(TokenStore(keychain: InMemoryKeychainStore()), const []);

      expect(file.existsSync(), isTrue);
    });

    test('keeps the file when the credential store refuses the token', () async {
      file.writeAsBytesSync(fakeProtect(jsonEncode({'gita.token.work': 'gho'})));

      await legacy().migrateAll(TokenStore(keychain: _RefusingKeychain()), const []);

      expect(file.existsSync(), isTrue);
    });

    test('no file means nothing to do', () async {
      expect(await legacy().migrateAll(TokenStore(keychain: InMemoryKeychainStore()), const []), 0);
    });

    test('reads a file really encrypted with DPAPI', () async {
      final encrypted = dpapiProtect(utf8.encode(jsonEncode({'gita.token.real': 'gho_real'})));
      if (encrypted == null) {
        markTestSkipped('DPAPI is Windows only');
        return;
      }
      file.writeAsBytesSync(encrypted);
      final store = TokenStore(keychain: InMemoryKeychainStore());

      expect(await DpapiLegacyTokens(file: file).migrateAll(store, const []), 1);
      expect(await store.readToken('real'), 'gho_real');
    }, skip: !Platform.isWindows);
  });

  group('SecureTokenService', () {
    test('the first read finds a token from an old version', () async {
      file.writeAsBytesSync(fakeProtect(jsonEncode({'gita.token.work': 'gho_old'})));
      final service = SecureTokenService(
        store: TokenStore(keychain: InMemoryKeychainStore()),
        legacy: legacy(),
      );

      expect(await service.readToken('work'), 'gho_old');
      expect(await service.hasToken('work'), isTrue);
    });

    test('a deleted token does not come back from the old file', () async {
      file.writeAsBytesSync(fakeProtect(jsonEncode({'gita.token.work': 'gho_old'})));
      final service = SecureTokenService(
        store: TokenStore(keychain: InMemoryKeychainStore()),
        legacy: legacy(),
      );
      await service.migrateLegacy(['work']);

      await service.deleteToken('work');

      expect(await service.readToken('work'), isNull);
    });

    test('reads made at the same time all wait for the move', () async {
      file.writeAsBytesSync(fakeProtect(jsonEncode({'gita.token.work': 'gho_old'})));
      final service = SecureTokenService(
        store: TokenStore(keychain: InMemoryKeychainStore()),
        legacy: legacy(),
      );

      final reads = await Future.wait([service.readToken('work'), service.readToken('work')]);

      expect(reads, ['gho_old', 'gho_old']);
    });
  });
}
