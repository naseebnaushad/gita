import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// A small secret store backed by the operating system's own credential
/// store: Credential Manager on Windows, the login Keychain on macOS and
/// libsecret (GNOME Keyring / KWallet) on Linux.
///
/// It is pure Dart on purpose. The desktop app and the headless `gita` CLI
/// (which git runs as a credential helper) must read the same secrets, and
/// the CLI cannot use Flutter plugins such as flutter_secure_storage.
abstract class KeychainStore {
  const KeychainStore();

  /// The store for the current operating system.
  factory KeychainStore.forPlatform() {
    if (Platform.isWindows) return const WindowsCredentialStore();
    if (Platform.isMacOS) return const MacKeychainStore();
    return const LinuxSecretToolStore();
  }

  Future<String?> read(String key);

  Future<void> write(String key, String value);

  /// Removes [key]. Does nothing if it isn't stored.
  Future<void> delete(String key);
}

/// Thrown when the OS credential store refused an operation.
class KeychainException implements Exception {
  KeychainException(this.message);

  final String message;

  @override
  String toString() => 'KeychainException: $message';
}

/// Service name every Gita secret is filed under, so users can find (and
/// remove) them in Keychain Access / Credential Manager / Seahorse.
const keychainServiceName = 'gita';

/// Windows Credential Manager, through advapi32 `CredReadW`/`CredWriteW`.
///
/// Entries are generic credentials named `gita:<key>`, persisted for this
/// user on this machine only (never roamed to other machines).
class WindowsCredentialStore extends KeychainStore {
  const WindowsCredentialStore();

  String _target(String key) => '$keychainServiceName:$key';

  /// The Dart VM doesn't reliably preserve the Windows last-error value
  /// across FFI calls (it reads 0 after a missing credential even with leaf
  /// calls), so 0 is treated like ERROR_NOT_FOUND. Real failures such as
  /// ERROR_NO_SUCH_LOGON_SESSION still surface when they are reported.
  static bool _isNotFound(int error) => error == ERROR_NOT_FOUND || error == 0;

  @override
  Future<String?> read(String key) async {
    return using((arena) {
      final target = _target(key).toNativeUtf16(allocator: arena);
      final out = arena<Pointer<CREDENTIAL>>();
      if (_Advapi.credRead(target, CRED_TYPE_GENERIC, 0, out) == 0) {
        final error = _Advapi.lastError();
        if (_isNotFound(error)) return null;
        throw KeychainException('CredRead failed (error $error)');
      }
      try {
        final cred = out.value.ref;
        final bytes = cred.CredentialBlob.asTypedList(cred.CredentialBlobSize);
        return utf8.decode(bytes);
      } finally {
        CredFree(out.value);
      }
    });
  }

  @override
  Future<void> write(String key, String value) async {
    using((arena) {
      final bytes = utf8.encode(value);
      final blob = arena<Uint8>(bytes.length);
      blob.asTypedList(bytes.length).setAll(0, bytes);

      final cred = arena<CREDENTIAL>();
      cred.ref
        ..Flags = 0
        ..Type = CRED_TYPE_GENERIC
        ..TargetName = _target(key).toNativeUtf16(allocator: arena)
        ..Comment = 'Saved by Gita'.toNativeUtf16(allocator: arena)
        ..CredentialBlobSize = bytes.length
        ..CredentialBlob = blob
        ..Persist = CRED_PERSIST_LOCAL_MACHINE
        ..AttributeCount = 0
        ..Attributes = nullptr
        ..TargetAlias = nullptr
        ..UserName = 'gita'.toNativeUtf16(allocator: arena);

      if (_Advapi.credWrite(cred, 0) == 0) {
        throw KeychainException('CredWrite failed (error ${_Advapi.lastError()})');
      }
      // Don't leave the secret lying around in freed native memory.
      blob.asTypedList(bytes.length).fillRange(0, bytes.length, 0);
    });
  }

  @override
  Future<void> delete(String key) async {
    using((arena) {
      final target = _target(key).toNativeUtf16(allocator: arena);
      if (_Advapi.credDelete(target, CRED_TYPE_GENERIC, 0) == 0) {
        final error = _Advapi.lastError();
        if (!_isNotFound(error)) {
          throw KeychainException('CredDelete failed (error $error)');
        }
      }
    });
  }
}

/// macOS login Keychain through `/usr/bin/security`.
///
/// Both the app and the CLI go through the same `security` binary, so the
/// item's access list (which trusts `security`) works for both without
/// extra prompts. Secrets are passed on stdin (`security -i`), never as
/// command-line arguments where other processes could see them.
class MacKeychainStore extends KeychainStore {
  const MacKeychainStore();

  static const _security = '/usr/bin/security';

  @override
  Future<String?> read(String key) async {
    final result = await Process.run(_security, [
      'find-generic-password',
      '-s', keychainServiceName,
      '-a', key,
      '-w',
    ]);
    // 44 = errSecItemNotFound.
    if (result.exitCode == 44) return null;
    if (result.exitCode != 0) {
      throw KeychainException('security find-generic-password failed: '
          '${(result.stderr as String).trim()}');
    }
    return (result.stdout as String).replaceFirst(RegExp(r'\n$'), '');
  }

  @override
  Future<void> write(String key, String value) async {
    final process = await Process.start(_security, ['-i']);
    process.stdin.writeln('add-generic-password -U '
        '-s ${_quote(keychainServiceName)} -a ${_quote(key)} '
        '-l ${_quote('Gita: $key')} -w ${_quote(value)}');
    await process.stdin.close();
    final stderr = await process.stderr.transform(utf8.decoder).join();
    await process.stdout.drain<void>();
    if (await process.exitCode != 0 || stderr.trim().isNotEmpty) {
      throw KeychainException('security add-generic-password failed: '
          '${stderr.trim()}');
    }
  }

  @override
  Future<void> delete(String key) async {
    final result = await Process.run(_security, [
      'delete-generic-password',
      '-s', keychainServiceName,
      '-a', key,
    ]);
    if (result.exitCode != 0 && result.exitCode != 44) {
      throw KeychainException('security delete-generic-password failed: '
          '${(result.stderr as String).trim()}');
    }
  }

  /// Quotes an argument for `security -i`, which splits its input lines
  /// like a shell: double quotes group, backslash escapes.
  static String _quote(String s) =>
      '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
}

/// Linux libsecret through `secret-tool` (package `libsecret-tools`).
/// The secret is passed on stdin, never as an argument.
class LinuxSecretToolStore extends KeychainStore {
  const LinuxSecretToolStore();

  List<String> _attributes(String key) =>
      ['service', keychainServiceName, 'account', key];

  @override
  Future<String?> read(String key) async {
    final ProcessResult result;
    try {
      result = await Process.run('secret-tool', ['lookup', ..._attributes(key)]);
    } on ProcessException {
      throw KeychainException(_missingToolMessage);
    }
    // secret-tool exits 1 with no output when nothing matches.
    if (result.exitCode != 0) return null;
    final value = result.stdout as String;
    return value.isEmpty ? null : value;
  }

  @override
  Future<void> write(String key, String value) async {
    final Process process;
    try {
      process = await Process.start('secret-tool', [
        'store',
        '--label=Gita: $key',
        ..._attributes(key),
      ]);
    } on ProcessException {
      throw KeychainException(_missingToolMessage);
    }
    process.stdin.write(value);
    await process.stdin.close();
    final stderr = await process.stderr.transform(utf8.decoder).join();
    await process.stdout.drain<void>();
    if (await process.exitCode != 0) {
      throw KeychainException('secret-tool store failed: ${stderr.trim()}');
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await Process.run('secret-tool', ['clear', ..._attributes(key)]);
    } on ProcessException {
      throw KeychainException(_missingToolMessage);
    }
  }

  static const _missingToolMessage =
      'secret-tool is not installed. Install it with: '
      'sudo apt install libsecret-tools';
}

/// Keeps secrets in memory only. For tests.
class InMemoryKeychainStore extends KeychainStore {
  InMemoryKeychainStore([Map<String, String>? initial])
      : values = {...?initial};

  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// Leaf bindings for the Credential Manager calls. A leaf call doesn't hand
/// control back to the Dart VM between the call and [lastError], so the
/// Windows last-error value isn't clobbered the way it can be with the
/// regular (non-leaf) bindings in package:win32.
abstract final class _Advapi {
  static final _advapi32 = DynamicLibrary.open('advapi32.dll');
  static final _kernel32 = DynamicLibrary.open('kernel32.dll');

  static final credRead = _advapi32.lookupFunction<
      Int32 Function(Pointer<Utf16>, Uint32, Uint32, Pointer<Pointer<CREDENTIAL>>),
      int Function(Pointer<Utf16>, int, int, Pointer<Pointer<CREDENTIAL>>)>(
    'CredReadW',
    isLeaf: true,
  );

  static final credWrite = _advapi32.lookupFunction<
      Int32 Function(Pointer<CREDENTIAL>, Uint32),
      int Function(Pointer<CREDENTIAL>, int)>('CredWriteW', isLeaf: true);

  static final credDelete = _advapi32.lookupFunction<
      Int32 Function(Pointer<Utf16>, Uint32, Uint32),
      int Function(Pointer<Utf16>, int, int)>('CredDeleteW', isLeaf: true);

  static final lastError = _kernel32.lookupFunction<Uint32 Function(),
      int Function()>('GetLastError', isLeaf: true);
}
