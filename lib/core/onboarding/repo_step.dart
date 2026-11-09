/// The onboarding "repo" step: makes sure a repository the organisation needs
/// is on the machine, in a folder of its own, as a clean copy of the right
/// project. Pure Dart: no Flutter imports.
library;

import 'dart:io';

import 'system.dart';

/// What [RepoEnsurer.ensure] did.
class RepoOutcome {
  /// Creates an outcome with a short [summary] for the final report.
  const RepoOutcome(this.summary, {this.failed = false, this.hint});

  /// One of 'downloaded', 'updated', 'kept (update failed)',
  /// 'kept (local changes)', 'dry run' or 'failed'.
  final String summary;

  /// True when the repository is not usable and onboarding should stop.
  final bool failed;

  /// What the person can do next, when [failed] is true.
  final String? hint;
}

/// The state of the target folder before anything is changed.
sealed class _State {
  const _State();
}

class _Clean extends _State {
  const _Clean();
}

class _Dirty extends _State {
  const _Dirty();
}

/// The folder must be moved aside; [reason] completes "`<dir>` is ...".
class _Move extends _State {
  const _Move(this.reason);
  final String reason;
}

/// Downloads or updates one repository.
///
/// A copy that isn't usable (not a folder, empty, not a git copy, a copy of a
/// different project, damaged) is never deleted: it is moved aside to
/// `<dir>.backup-YYYYMMDD-HHMMSS` and a fresh copy is downloaded.
class RepoEnsurer {
  /// Creates the step. [now] is used for backup names; with [dryRun] nothing
  /// on the machine is changed.
  RepoEnsurer({
    required this._runner,
    required this._reporter,
    String gitExecutable = 'git',
    this._now = DateTime.now,
    this._dryRun = false,
  }) : _git = gitExecutable;

  final CommandRunner _runner;
  final Reporter _reporter;
  final String _git;
  final DateTime Function() _now;
  final bool _dryRun;

  /// Git must never stop to ask for a password, passphrase or host key.
  static const Map<String, String?> _gitEnv = {
    'GIT_SSH_COMMAND': 'ssh -o BatchMode=yes -o ConnectTimeout=15',
    'GIT_TERMINAL_PROMPT': '0',
  };

  static const _pullTimeout = Duration(seconds: 180);

  /// Makes sure [dir] (an absolute path) holds a clean copy of [url].
  ///
  /// [name] is how the repository is called in messages. [clone] downloads it
  /// into [dir] (normally Gita's clone service with the right profile) and
  /// returns whether it worked. [profileLabel], [profileLogin],
  /// [accountEmail] and [orgName] (the owner part of [url]) are only used to
  /// explain a failed download. When [offerRetry] is given and returns true
  /// after a failed download (the caller asked the person and signed them in
  /// again), the download is tried once more.
  ///
  /// Returns one of: 'downloaded', 'updated', 'kept (update failed)',
  /// 'kept (local changes)', 'dry run', 'failed'.
  Future<RepoOutcome> ensure({
    required String url,
    required String dir,
    required String name,
    required String profileLabel,
    required String? profileLogin,
    required String accountEmail,
    required String orgName,
    required Future<bool> Function() clone,
    Future<bool> Function()? offerRetry,
  }) async {
    if (FileSystemEntity.typeSync(dir, followLinks: false) != FileSystemEntityType.notFound) {
      final state = await _state(dir, url);
      switch (state) {
        case _Clean():
          return _update(dir, name);
        case _Dirty():
          _reporter.warn('$name in $dir has local changes, so it was not updated.');
          return const RepoOutcome('kept (local changes)');
        case _Move(:final reason):
          final backup = _backupName(dir);
          _reporter.warn('$dir is $reason. Moving it to $backup and downloading a fresh copy.');
          if (_dryRun) {
            _reporter.note('[dry run] would move $dir to $backup');
          } else {
            try {
              await _entity(dir).rename(backup);
            } on FileSystemException catch (e) {
              _reporter.warn("Couldn't move $dir to $backup: ${e.osError?.message ?? e.message}");
              return const RepoOutcome(
                'failed',
                failed: true,
                hint: 'Close any program using that folder, then run this again.',
              );
            }
          }
      }
    }
    return _clone(
      dir: dir,
      name: name,
      profileLabel: profileLabel,
      profileLogin: profileLogin,
      accountEmail: accountEmail,
      orgName: orgName,
      clone: clone,
      offerRetry: offerRetry,
    );
  }

  /// Compares repository addresses: lower-case, no scheme (https, ssh, git),
  /// no `user@`, `github.com:` as `github.com/`, no trailing `/` or `.git`.
  static String normaliseUrl(String url) {
    var u = url.trim().toLowerCase();
    u = u.replaceFirst(RegExp(r'^(https?|ssh|git)://'), '');
    u = u.replaceFirst(RegExp(r'^[^@/]+@'), '');
    u = u.replaceFirst(RegExp(r'^github\.com:'), 'github.com/');
    u = u.replaceFirst(RegExp(r'/+$'), '');
    u = u.replaceFirst(RegExp(r'\.git$'), '');
    return u;
  }

  Future<_State> _state(String dir, String url) async {
    if (FileSystemEntity.typeSync(dir) != FileSystemEntityType.directory) return const _Move('not a folder');
    if (Directory(dir).listSync().isEmpty) return const _Move('empty');
    final dotGit = '$dir${Platform.pathSeparator}.git';
    if (FileSystemEntity.typeSync(dotGit) == FileSystemEntityType.notFound) return const _Move('not a git copy');
    final origin = await _runGit(['-C', dir, 'config', '--get', 'remote.origin.url']);
    // Exit 1 only means "no origin"; anything else means git can't read the copy.
    if (!origin.ok && origin.exitCode != 1) return const _Move('a damaged git copy');
    if (normaliseUrl(origin.stdout) != normaliseUrl(url)) return const _Move('a copy of a different project');
    final status = await _runGit(['-C', dir, 'status', '--porcelain']);
    if (!status.ok) return const _Move('a damaged git copy');
    if (status.stdout.trim().isNotEmpty) return const _Dirty();
    return const _Clean();
  }

  Future<RepoOutcome> _update(String dir, String name) async {
    _reporter.say('Updating $name');
    if (_dryRun) {
      _reporter.note('[dry run] would update $dir (git pull --ff-only)');
      return const RepoOutcome('dry run');
    }
    final r = await _runGit([
      '-C',
      dir,
      '-c',
      'http.lowSpeedLimit=1000',
      '-c',
      'http.lowSpeedTime=60',
      '-c',
      'advice.diverging=false',
      'pull',
      '--ff-only',
      '-q',
    ], timeout: _pullTimeout);
    if (r.ok) {
      _reporter.note('$name is up to date.');
      return const RepoOutcome('updated');
    }
    // Pass git's own explanation on, without its multi-line "hint:" advice.
    for (final line in '${r.stdout}\n${r.stderr}'.split(RegExp(r'\r?\n'))) {
      final t = line.trimRight();
      if (t.trim().isEmpty || t.trimLeft().startsWith('hint:')) continue;
      _reporter.note(t);
    }
    if (r.exitCode == CommandResult.timedOut) _reporter.note('git took too long and was stopped.');
    _reporter.warn("Couldn't update $name (the message above says why). Using the copy you have.");
    return const RepoOutcome('kept (update failed)');
  }

  Future<RepoOutcome> _clone({
    required String dir,
    required String name,
    required String profileLabel,
    required String? profileLogin,
    required String accountEmail,
    required String orgName,
    required Future<bool> Function() clone,
    required Future<bool> Function()? offerRetry,
  }) async {
    _reporter.say('Downloading $name');
    if (_dryRun) {
      _reporter.note('[dry run] would download $name into $dir');
      return const RepoOutcome('dry run');
    }
    for (var attempt = 1; attempt <= 2; attempt++) {
      if (await _tryClone(clone)) return const RepoOutcome('downloaded');
      // The folder did not exist before this clone, so anything left is a partial copy.
      await _removePartial(dir);
      _explainCloneFailure(name, profileLabel, profileLogin, accountEmail, orgName);
      if (attempt != 1 || offerRetry == null) break;
      if (!await offerRetry()) break;
    }
    return const RepoOutcome('failed', failed: true, hint: 'Check the causes listed above, then run this again.');
  }

  Future<bool> _tryClone(Future<bool> Function() clone) async {
    try {
      return await clone();
    } on Exception catch (e) {
      _reporter.note('The download stopped with an error: $e');
      return false;
    }
  }

  Future<void> _removePartial(String dir) async {
    try {
      if (FileSystemEntity.typeSync(dir, followLinks: false) != FileSystemEntityType.notFound) {
        await _entity(dir).delete(recursive: true);
      }
    } on FileSystemException {
      _reporter.note('Part of the download is still in $dir. Delete that folder before trying again.');
    }
  }

  void _explainCloneFailure(String name, String label, String? login, String email, String org) {
    final who = (login == null || login.trim().isEmpty) ? 'unknown' : login.trim();
    _reporter.warn("Couldn't download $name. Likely causes:");
    _reporter.note("  1. The organization $org hasn't approved the Gita app yet (the most common cause). On");
    _reporter.note('     github.com open Settings > Applications > Authorized OAuth Apps > Gita, click');
    _reporter.note('     "Request" next to $org, and ask an org owner to approve it under');
    _reporter.note('     Organization settings > Third-party access.');
    _reporter.note('  2. The profile "$label" is signed in as @$who. It must be your $email GitHub account,');
    _reporter.note('     the one that is a member of $org.');
    _reporter.note("  3. Your account hasn't been added to $org yet. Ask an admin.");
    _reporter.note('  4. No connection to github.com.');
  }

  /// A free `<path>.backup-<date-time>` name; never an earlier backup's.
  String _backupName(String path) {
    final t = _now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${t.year.toString().padLeft(4, '0')}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
    var backup = '$path.backup-$stamp';
    var n = 2;
    while (FileSystemEntity.typeSync(backup, followLinks: false) != FileSystemEntityType.notFound) {
      backup = '$path.backup-$stamp-$n';
      n++;
    }
    return backup;
  }

  static FileSystemEntity _entity(String path) => switch (FileSystemEntity.typeSync(path, followLinks: false)) {
    FileSystemEntityType.directory => Directory(path),
    FileSystemEntityType.link => Link(path),
    _ => File(path),
  };

  Future<CommandResult> _runGit(List<String> args, {Duration timeout = const Duration(seconds: 30)}) =>
      _runner.run(_git, args, environment: _gitEnv, timeout: timeout);
}
