import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/ssh_key.dart';
import 'platform_paths.dart';

/// Runs a program and returns what it printed. Tests swap in a fake.
typedef ProcessRunner = Future<ProcessResult> Function(
    String executable, List<String> arguments);

Future<ProcessResult> _runProcess(String executable, List<String> arguments) =>
    Process.run(executable, arguments);

/// Creates one SSH key per profile and checks which GitHub account it
/// signs in as.
///
/// Git uses the key through `core.sshCommand` in the profile's include
/// file (see [sshCommandFor]), so ordinary `git@github.com:org/repo`
/// remotes work as they are: no host aliases and no remote rewriting.
class SshKeyService {
  SshKeyService({required this.paths, ProcessRunner? run})
      : _run = run ?? _runProcess;

  final PlatformPaths paths;
  final ProcessRunner _run;

  static const gitHubHost = 'github.com';

  String get sshDir => p.join(paths.homeDir(), '.ssh');

  String get knownHostsPath => p.join(sshDir, 'known_hosts');

  /// Makes a new ed25519 key for the profile called [profileLabel], in
  /// `~/.ssh/gita_<label>` (plus `.pub`), without a passphrase so pushes
  /// never stop to ask for one.
  Future<SshKey> generate({
    required String profileLabel,
    required String email,
  }) async {
    await Directory(sshDir).create(recursive: true);
    final privateKeyPath = _freeKeyPath(profileLabel);
    final result = await _runTool('ssh-keygen', [
      '-t', 'ed25519',
      '-f', privateKeyPath,
      '-N', '',
      '-C', email.trim().isEmpty ? 'gita $profileLabel' : email.trim(),
      '-q',
    ]);
    if (result.exitCode != 0 || !File(privateKeyPath).existsSync()) {
      throw SshKeyException(
        "Couldn't create an SSH key: ${_output(result)}",
      );
    }
    return SshKey(
      id: const Uuid().v4(),
      label: profileLabel,
      privateKeyPath: privateKeyPath,
      publicKeyPath: '$privateKeyPath.pub',
      hostAlias: gitHubHost,
      realHost: gitHubHost,
      createdAt: DateTime.now(),
    );
  }

  String _freeKeyPath(String label) {
    var slug = label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    slug = slug.replaceAll(RegExp(r'^_+|_+$'), '');
    if (slug.isEmpty) slug = 'profile';
    final base = p.join(sshDir, 'gita_$slug');
    var candidate = base;
    for (var n = 2; File(candidate).existsSync() || File('$candidate.pub').existsSync(); n++) {
      candidate = '${base}_$n';
    }
    return candidate;
  }

  Future<String> readPublicKey(SshKey key) async =>
      (await File(key.publicKeyPath).readAsString()).trim();

  /// The command git runs instead of plain `ssh` in the profile's folders:
  /// it offers this profile's key first and ignores keys loaded in an SSH
  /// agent, which would otherwise sign in as whichever account they
  /// belong to.
  String sshCommandFor(SshKey key) =>
      'ssh -i "${paths.toGitConfigPath(key.privateKeyPath)}" -o IdentitiesOnly=yes';

  /// Asks GitHub which account [key] signs in as, using only that key.
  Future<SshCheckResult> check(SshKey key) async {
    if (!File(key.privateKeyPath).existsSync()) {
      return SshCheckResult.failed(
          'The key file ${key.privateKeyPath} is missing. Remove the key from '
          'this profile and set up SSH again.');
    }
    final ProcessResult result;
    try {
      result = await _runTool('ssh', [
        '-T',
        // Only this key, and none of the person's own SSH settings, so the
        // answer is about this key and nothing else.
        '-F', 'none',
        '-i', key.privateKeyPath,
        '-o', 'IdentitiesOnly=yes',
        // The file trustGitHub writes. Named outright because an ssh run
        // outside git may not agree with git on where home is.
        '-o', 'UserKnownHostsFile="${paths.toGitConfigPath(knownHostsPath)}"',
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=20',
        'git@$gitHubHost',
      ]);
    } on SshKeyException catch (e) {
      return SshCheckResult.failed(e.message);
    }
    final output = _output(result);
    final hi = RegExp(r'Hi ([A-Za-z0-9-]+)!').firstMatch(output);
    if (hi != null) return SshCheckResult.ok(hi.group(1)!);
    if (output.contains('Permission denied')) {
      return SshCheckResult.failed(
          "GitHub doesn't know this key yet. Add it to the GitHub account, "
          'then check again.');
    }
    if (output.contains('Host key verification failed')) {
      return SshCheckResult.failed(
          "This computer hasn't confirmed GitHub's identity yet. Press "
          'Check again; if this stays, check the internet connection.');
    }
    return SshCheckResult.failed(
        "Couldn't reach GitHub over SSH: $output. Some company networks "
        'block SSH; HTTPS pushes still work.');
  }

  /// Whether `~/.ssh/known_hosts` already lists GitHub, so the first push
  /// doesn't stop to ask "Are you sure you want to continue connecting?".
  Future<bool> knowsGitHub() async {
    if (!File(knownHostsPath).existsSync()) return false;
    try {
      final result = await _runTool('ssh-keygen', ['-F', gitHubHost, '-f', knownHostsPath]);
      return result.exitCode == 0 && _output(result).isNotEmpty;
    } on SshKeyException {
      return false;
    }
  }

  /// Adds GitHub's host keys (as published at api.github.com/meta, fetched
  /// over HTTPS) to `~/.ssh/known_hosts` unless GitHub is already there.
  Future<void> trustGitHub(Future<List<String>> Function() fetchHostKeys) async {
    if (await knowsGitHub()) return;
    final keys = await fetchHostKeys();
    if (keys.isEmpty) return;
    await Directory(sshDir).create(recursive: true);
    final file = File(knownHostsPath);
    final existing = file.existsSync() ? await file.readAsString() : '';
    final buffer = StringBuffer(existing);
    if (existing.isNotEmpty && !existing.endsWith('\n')) buffer.writeln();
    for (final key in keys) {
      buffer.writeln('$gitHubHost ${key.trim()}');
    }
    await file.writeAsString(buffer.toString());
  }

  /// Runs an OpenSSH tool. On Windows, the copy that comes with Git is
  /// preferred: it is the one git itself runs for `core.sshCommand`.
  Future<ProcessResult> _runTool(String name, List<String> args) async {
    for (final exe in await _toolCandidates(name)) {
      try {
        return await _run(exe, args);
      } on ProcessException {
        continue;
      }
    }
    throw SshKeyException(
        "Couldn't find $name on this computer. Install Git (it includes "
        'SSH), then try again.');
  }

  /// Git for Windows' `usr/bin`, once looked up (null: not found).
  Future<String?>? _gitUsrBin;

  Future<List<String>> _toolCandidates(String name) async {
    if (!Platform.isWindows) return [name];
    final gitUsrBin = await (_gitUsrBin ??= _findGitUsrBin());
    return [
      if (gitUsrBin != null) p.join(gitUsrBin, '$name.exe'),
      name,
    ];
  }

  Future<String?> _findGitUsrBin() async {
    try {
      // e.g. C:/Program Files/Git/mingw64/libexec/git-core
      final result = await _run('git', ['--exec-path']);
      final execPath = (result.stdout as String).trim();
      if (result.exitCode != 0 || execPath.isEmpty) return null;
      final dir = p.normalize(p.join(execPath, '..', '..', '..', 'usr', 'bin'));
      return Directory(dir).existsSync() ? dir : null;
    } on ProcessException {
      // No git on PATH; fall back to whatever ssh is on PATH.
      return null;
    }
  }

  static String _output(ProcessResult result) =>
      '${result.stdout}\n${result.stderr}'.trim();
}

class SshCheckResult {
  const SshCheckResult.ok(String this.login) : message = null;
  const SshCheckResult.failed(String this.message) : login = null;

  /// The GitHub account the key signs in as, when it works.
  final String? login;

  /// What went wrong and what to do, when it doesn't.
  final String? message;

  bool get works => login != null;
}

class SshKeyException implements Exception {
  const SshKeyException(this.message);

  final String message;

  @override
  String toString() => 'SshKeyException: $message';
}
