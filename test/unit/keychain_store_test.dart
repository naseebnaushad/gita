import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gita/core/services/keychain_store.dart';

/// Round-trips a throwaway secret through this machine's real credential
/// store. Runs where the store is reachable without user interaction
/// (Windows Credential Manager). The macOS and Linux stores can prompt or
/// need a desktop session, so they only run when GITA_TEST_KEYCHAIN=1 (the
/// macOS CI runner has an unlocked login Keychain).
void main() {
  final key = 'test.${DateTime.now().microsecondsSinceEpoch}';
  final store = KeychainStore.forPlatform();

  group('the real credential store', () {
    // Only the real-store test cleans up there; elsewhere (Linux CI without
    // a desktop session) the store can't be reached at all.
    tearDown(() => store.delete(key));

    test(
      'write, read, overwrite and delete a secret',
      () async {
        expect(await store.read(key), isNull);

        await store.write(key, 'ghp_first ünïcode');
        expect(await store.read(key), 'ghp_first ünïcode');

        await store.write(key, 'ghp_second');
        expect(await store.read(key), 'ghp_second');

        await store.delete(key);
        expect(await store.read(key), isNull);

        // Deleting something that isn't there is fine.
        await store.delete(key);

        // Secrets the store must give back exactly. On macOS, `security`
        // prints some of these in hex or needs them quoted on its input line.
        for (final secret in [
          'deadbeef', // looks like the hex `security -w` would print
          r'with "quotes" and \back\slashes',
          '  spaces around  ',
          "it's ünïcode — ✓",
          'gho_${'A1b2' * 20}',
          '',
        ]) {
          await store.write(key, secret);
          expect(await store.read(key), secret, reason: 'secret: <$secret>');
        }
      },
      skip:
          !(Platform.isWindows ||
              (Platform.isMacOS && Platform.environment['GITA_TEST_KEYCHAIN'] == '1')),
    );
  });

  group('MacKeychainStore reads `security -g` output', () {
    String? parse(String s) => MacKeychainStore.parsePasswordLine(s);

    test('a plain secret, even one that looks like hex', () {
      expect(parse('keychain: "x"\npassword: "ghp_abc"\n'), 'ghp_abc');
      expect(parse('password: "6768"\n'), '6768');
    });

    test('the hex form security uses for unicode, quotes and backslashes', () {
      expect(parse(r'password: 0xC3BC6EC3AF  "\303\274n\303\257"'), 'ünï');
      expect(parse(r'password: 0x706C61696E22715C78  "plain"q\134x"'), r'plain"q\x');
    });

    test('an empty secret, and output with no password line', () {
      expect(parse('password: \nkeychain: "x"\n'), '');
      expect(parse('keychain: "x"\n'), isNull);
    });
  });
}
