import 'dart:io';

/// Thin wrapper around the `gpg` CLI, used only to check whether a secret
/// key exists for a given identity — never to sign or manage keys itself.
class GpgService {
  const GpgService();

  Future<bool> isInstalled() async {
    try {
      final result = await Process.run('gpg', ['--version']);
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  /// True if a secret key usable for signing exists for [identity] (an
  /// email address or key fingerprint) — the same lookup `git commit -S`
  /// relies on.
  Future<bool> hasSecretKeyFor(String identity) async {
    try {
      final result = await Process.run(
        'gpg',
        ['--list-secret-keys', '--with-colons', identity],
      );
      if (result.exitCode != 0) return false;
      return (result.stdout as String).contains('sec:');
    } on ProcessException {
      return false;
    }
  }
}
