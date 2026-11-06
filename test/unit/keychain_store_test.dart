import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gita/core/services/keychain_store.dart';

/// Round-trips a throwaway secret through this machine's real credential
/// store. Runs where the store is reachable without user interaction
/// (Windows Credential Manager); the macOS and Linux stores can prompt or
/// need a desktop session, so they are skipped here.
void main() {
  final key = 'test.${DateTime.now().microsecondsSinceEpoch}';
  final store = KeychainStore.forPlatform();

  tearDown(() => store.delete(key));

  test('write, read, overwrite and delete a secret', () async {
    expect(await store.read(key), isNull);

    await store.write(key, 'ghp_first ünïcode');
    expect(await store.read(key), 'ghp_first ünïcode');

    await store.write(key, 'ghp_second');
    expect(await store.read(key), 'ghp_second');

    await store.delete(key);
    expect(await store.read(key), isNull);

    // Deleting something that isn't there is fine.
    await store.delete(key);
  }, skip: !Platform.isWindows);
}
