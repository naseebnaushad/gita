/// Finds and removes old GitHub sign-ins and settings that make git or gh use
/// another account than the one Gita signed in. Ported from the setup
/// scripts' clean-up step so `gita onboard` (and later `gita cleanup`) share
/// one tested implementation. Pure Dart: no Flutter imports.
library;

import 'dart:io';

import 'onboarding_file.dart';
import 'system.dart';

/// What kind of thing a [CleanupItem] is, which decides how it is removed.
enum CleanupKind {
  /// github.com logins saved by a git credential helper (not gh or Gita).
  savedLogin,

  /// A Windows Credential Manager entry for github.com.
  credentialManager,

  /// A global git setting (rewrite, fixed header or login helper).
  gitConfig,

  /// A GitHub CLI login.
  ghLogin,

  /// A Windows user-level GH_TOKEN / GITHUB_TOKEN variable.
  userTokenVariable,
}

/// One thing the clean-up can remove.
class CleanupItem {
  /// Creates an item. [description] must already be redacted.
  const CleanupItem(this.kind, this.description, this.arg);

  /// How the item is removed.
  final CleanupKind kind;

  /// Plain-English description, with any token in an address replaced by
  /// `//***@`. Safe to show.
  final String description;

  /// What removal needs (setting name, entry name, login, variable name).
  /// A [CleanupKind.gitConfig] key may contain a token: never print it.
  final String arg;
}

/// What [GitHubCleanup.find] found.
class CleanupFindings {
  /// Creates findings.
  const CleanupFindings(this.items, this.reportOnly);

  /// Things that can be removed.
  final List<CleanupItem> items;

  /// Things that are only reported, never changed.
  final List<String> reportOnly;
}

/// How the clean-up step ended.
class CleanupOutcome {
  /// Creates an outcome.
  const CleanupOutcome(this.summary, {this.ghLoggedOut = false, this.failed = false});

  /// Short result, e.g. `cleaned (3)` or `nothing to clean`.
  final String summary;

  /// True when a GitHub CLI login was removed, so the caller can tell the
  /// person to run `gh auth login` again.
  final bool ghLoggedOut;

  /// True when something could not be removed or backed up.
  final bool failed;
}

/// Finds and removes old GitHub sign-ins. See [run].
class GitHubCleanup {
  /// Creates the step. [isWindows] selects the Windows-only checks (Credential
  /// Manager, registry variables) independently of the host, so tests can
  /// cover both. [environment] defaults to this process's environment.
  GitHubCleanup({
    required this._runner,
    required this._reporter,
    required this._prompter,
    required this._isWindows,
    required String homeDir,
    String gitExecutable = 'git',
    String ghExecutable = 'gh',
    this._now = DateTime.now,
    Map<String, String>? environment,
  }) : _home = homeDir,
       _git = gitExecutable,
       _gh = ghExecutable,
       _env = environment ?? Platform.environment;

  final CommandRunner _runner;
  final Reporter _reporter;
  final Prompter _prompter;
  final bool _isWindows;
  final String _home;
  final String _git;
  final String _gh;
  final DateTime Function() _now;
  final Map<String, String> _env;

  static const _tokenVars = ['GH_TOKEN', 'GITHUB_TOKEN'];
  static const _userEnvKey = r'HKCU\Environment';
  static const _machineEnvKey = r'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment';
  static const _maxFileBytes = 1024 * 1024;

  /// The GitHub CLI must never use a token from the environment while we ask
  /// which accounts it has saved, or it would report that token instead.
  static const _noTokens = <String, String?>{'GH_TOKEN': null, 'GITHUB_TOKEN': null};

  /// A program name that does not exist: askpass fails at once, so no window
  /// or prompt can appear while git looks for a saved login.
  static const _noAskpass = 'gita-no-askpass';

  static const _credentialEnv = <String, String?>{
    'GIT_TERMINAL_PROMPT': '0',
    'GCM_INTERACTIVE': 'never',
    'GIT_ASKPASS': _noAskpass,
    'SSH_ASKPASS': _noAskpass,
  };

  static const _credentialRequest = 'protocol=https\nhost=github.com\n\n';

  static final _cmdkeyName = RegExp(r'(git:https://([^@/\s]+@)?github\.com(/\S*)?)\s*$');
  static final _ghLogin = RegExp(r'Logged in to github\.com (?:account|as) ([A-Za-z0-9-]+)');
  static final _sshHost = RegExp(r'^[ \t]*host[ \t].*github\.com', caseSensitive: false, multiLine: true);
  static final _authHeader = RegExp(r'^\s*authorization', caseSensitive: false, multiLine: true);

  /// Characters cmd.exe acts on. On Windows the system runner starts programs
  /// through the shell, so an argument holding one of these could be cut short
  /// or run as a command; such items are reported instead of removed.
  static final _shellUnsafe = RegExp(r'[%^|<>&"!\x00-\x1f]');

  /// Hides a token that may sit in an address (https://user:token@github.com).
  static String redact(String text) => text.replaceAll(RegExp(r'//[^/@ ]+@'), '//***@');

  String get _gitconfigLabel => _isWindows ? r'~\.gitconfig' : '~/.gitconfig';

  String _path(String name) => '$_home${Platform.pathSeparator}$name';

  /// A folder outside any repository, so no repository's settings (or Gita's
  /// per-folder rules) take part in git's answers.
  String get _outside {
    if (_isWindows) {
      final m = RegExp(r'^[A-Za-z]:[\\/]').firstMatch(_home);
      return m != null ? _home.substring(0, 3) : _home;
    }
    return Platform.isWindows ? _home : '/';
  }

  Future<CommandResult> _gitRun(List<String> args, {Map<String, String?> env = const {}, String? stdin}) => _runner.run(
    _git,
    args,
    workingDirectory: _outside,
    environment: env,
    stdinText: stdin,
    timeout: const Duration(seconds: 60),
  );

  static List<String> _lines(String s) => [
    for (final l in s.split('\n'))
      if (l.trim().isNotEmpty) l.trimRight(),
  ];

  /// Global git settings as (key, value) pairs, in file order. Read with
  /// `--list -z` and filtered here, because a regex argument would pass
  /// through cmd.exe on Windows, which treats `|` and `^` as its own.
  Future<List<(String, String)>> _globalConfig() async {
    final r = await _gitRun(['config', '--global', '--list', '-z']);
    if (!r.ok) return const [];
    final out = <(String, String)>[];
    for (final entry in r.stdout.split('\x00')) {
      if (entry.isEmpty) continue;
      final nl = entry.indexOf('\n');
      out.add(nl < 0 ? (entry, '') : (entry.substring(0, nl), entry.substring(nl + 1)));
    }
    return out;
  }

  /// Helpers that may hold an old login: every configured `credential.helper`
  /// plus global github.com-specific ones, without gh's and Gita's own.
  Future<List<String>> _oldHelpers(List<(String, String)> global) async {
    final all = await _gitRun(['config', '--get-all', 'credential.helper']);
    final helpers = <String>[];
    void add(String h) {
      final t = h.trim();
      if (t.isEmpty || t.contains('gh auth') || t.contains('gita') || helpers.contains(t)) return;
      helpers.add(t);
    }

    if (all.ok) _lines(all.stdout).forEach(add);
    for (final (k, v) in global) {
      if (_isGithubHelperKey(k)) add(v);
    }
    return helpers;
  }

  static bool _isGithubHelperKey(String k) {
    final l = k.toLowerCase();
    return l.startsWith('credential.') && l.endsWith('.helper') && l.contains('github.com');
  }

  /// Runs `git credential <action>` for github.com through [helpers] only.
  /// The leading empty `credential.helper` clears every configured helper, so
  /// gh's and Gita's own helpers neither answer the check nor lose their
  /// logins on reject. Git's answer may hold a password: it is dropped here.
  Future<bool> _credential(String action, List<String> helpers) async {
    final r = await _gitRun(
      [
        '-c',
        'core.askPass=$_noAskpass',
        '-c',
        'credential.interactive=false',
        '-c',
        'credential.helper=',
        for (final h in helpers) ...['-c', 'credential.helper=$h'],
        'credential',
        action,
      ],
      env: _credentialEnv,
      stdin: _credentialRequest,
    );
    return r.ok;
  }

  bool _safeArg(String a) => !_isWindows || !_shellUnsafe.hasMatch(a);

  /// Looks for old GitHub sign-ins and settings. Changes nothing.
  Future<CleanupFindings> find() async {
    final items = <CleanupItem>[];
    final report = <String>[];
    void add(CleanupKind kind, String text, String arg) {
      if (items.any((i) => i.kind == kind && i.arg == arg)) return;
      items.add(CleanupItem(kind, text, arg));
    }

    final global = await _globalConfig();

    // Saved logins come first: they are erased while every helper is still
    // configured.
    final helpers = await _oldHelpers(global);
    if (!helpers.every(_safeArg)) {
      report.add(
        'A git credential helper is set up in a way Gita can\'t check safely, so saved github.com logins in it '
        'were not looked for. Check it with "git config --show-origin --get-all credential.helper".',
      );
    } else if (helpers.isNotEmpty && await _credential('fill', helpers)) {
      var h = helpers.join(', ');
      if (RegExp('password|token').hasMatch(h)) h = '(a custom helper)';
      add(CleanupKind.savedLogin, 'Saved github.com logins in: $h (erased with "git credential reject")', '');
    }

    if (_isWindows) {
      // Git Credential Manager keeps one entry per account and a reject only
      // reaches the default one. Matched on the entry name, not cmdkey's
      // labels, which are translated on non-English Windows.
      final r = await _runner.run('cmdkey', ['/list'], timeout: const Duration(seconds: 30));
      if (r.ok) {
        for (final name in _cmdkeyEntries(r.stdout)) {
          add(CleanupKind.credentialManager, 'Windows Credential Manager entry ${redact(name)}', name);
        }
      }
    }

    for (final (k, v) in global) {
      final l = k.toLowerCase();
      if (l.startsWith('url.') && (l.endsWith('.insteadof') || l.endsWith('.pushinsteadof'))) {
        if ('$k $v'.toLowerCase().contains('github.com')) {
          add(
            CleanupKind.gitConfig,
            'git setting ${redact(k)} = ${redact(v)} (sends github.com addresses somewhere else, e.g. SSH)',
            k,
          );
        }
      }
    }
    for (final (k, _) in global) {
      final l = k.toLowerCase();
      if (l.startsWith('http.') && l.endsWith('.extraheader') && l.contains('github.com')) {
        add(CleanupKind.gitConfig, 'git setting ${redact(k)} (sends a fixed sign-in with every github.com request)', k);
      }
    }
    if (global.any((e) => e.$1.toLowerCase() == 'http.extraheader' && _authHeader.hasMatch(e.$2))) {
      add(
        CleanupKind.gitConfig,
        'git setting http.extraheader (a sign-in header sent to every site, github.com included)',
        'http.extraheader',
      );
    }
    for (final (k, v) in global) {
      if (!_isGithubHelperKey(k)) continue;
      final shown = RegExp('password|token|=').hasMatch(v) ? '(a custom command)' : redact(v);
      add(CleanupKind.gitConfig, 'git setting ${redact(k)} = $shown (an old github.com login helper)', k);
    }

    final gh = await _runner.run(
      _gh,
      ['auth', 'status', '--hostname', 'github.com'],
      environment: _noTokens,
      timeout: const Duration(seconds: 30),
    );
    if (gh.exitCode != CommandResult.notFound) {
      // Older gh versions print the status on stderr.
      for (final m in _ghLogin.allMatches('${gh.stdout}\n${gh.stderr}')) {
        final login = m.group(1)!;
        add(CleanupKind.ghLogin, 'GitHub CLI login @$login (gh auth logout)', login);
      }
    }

    final userVars = <String>{};
    if (_isWindows) {
      for (final v in _tokenVars) {
        if ((await _regQuery(_userEnvKey, v))) {
          userVars.add(v);
          add(
            CleanupKind.userTokenVariable,
            'Your Windows environment variable $v (gh and other tools use it instead of your sign-in)',
            v,
          );
        }
        if (await _regQuery(_machineEnvKey, v)) {
          report.add(
            '$v is set for all users of this computer. gh and other tools use it instead of your sign-in. '
            'Ask an admin to remove it.',
          );
        }
      }
    }
    report.addAll(await _processTokenReport(userVars));

    final ssh = _readCapped('.ssh${Platform.pathSeparator}config');
    if (ssh != null && _sshHost.hasMatch(ssh)) {
      report.add(
        'Your SSH settings file (.ssh${_isWindows ? r'\' : '/'}config in your home folder) has a "Host github.com" '
        'entry. It only matters for SSH addresses (git@github.com:...) and was not changed.',
      );
    }
    return CleanupFindings(List.unmodifiable(items), List.unmodifiable(report));
  }

  /// github.com entry names in `cmdkey /list` output, each once.
  static List<String> _cmdkeyEntries(String listing) {
    final names = <String>[];
    for (final line in listing.split('\n')) {
      final m = _cmdkeyName.firstMatch(line);
      if (m != null && !names.contains(m.group(1))) names.add(m.group(1)!);
    }
    return names;
  }

  Future<bool> _regQuery(String key, String name) async =>
      (await _runner.run('reg', ['query', key, '/v', name], timeout: const Duration(seconds: 30))).ok;

  /// Token variables set in this process. They can't be changed from here,
  /// so the person is told where they probably come from. On Windows a
  /// user-level variable already listed explains it.
  Future<List<String>> _processTokenReport(Set<String> userVars) async {
    final out = <String>[];
    const profiles = ['.bashrc', '.bash_profile', '.profile', '.zshrc', '.zprofile', '.zshenv'];
    for (final v in _tokenVars) {
      final inProcess = (_env[v] ?? '').isNotEmpty;
      if (_isWindows) {
        if (inProcess && !userVars.contains(v)) {
          out.add(
            '$v is set in this terminal. gh and other tools use it instead of your sign-in. It probably comes from '
            'your PowerShell profile or the program that opened this terminal; remove it there, then open a new '
            'terminal.',
          );
        }
        continue;
      }
      final line = RegExp('^[ \\t]*(export[ \\t]+)?$v=', multiLine: true);
      final files = [
        for (final f in profiles)
          if (line.hasMatch(_readCapped(f) ?? '')) '~/$f',
      ];
      if (inProcess || files.isNotEmpty) {
        final where = files.isEmpty ? ', probably in your shell profile' : ' in ${files.join(' ')}';
        out.add(
          '$v is set$where. gh and other tools use it instead of your sign-in. '
          'Remove that line yourself, then open a new terminal.',
        );
      }
    }
    return out;
  }

  /// Reads a file under the home folder, or null when it is missing, larger
  /// than 1 MB or unreadable.
  String? _readCapped(String relative) {
    try {
      final f = File(_path(relative));
      if (!f.existsSync() || f.lengthSync() > _maxFileBytes) return null;
      return f.readAsStringSync();
    } on Object {
      return null;
    }
  }

  /// The whole step: finds old sign-ins, lists them, then per [mode]:
  /// skip does nothing; a [dryRun] only lists; ask keeps everything without a
  /// terminal and otherwise asks; yes (or a yes answer) backs up
  /// ~/.gitconfig and removes each item. Report-only lines are always shown.
  Future<CleanupOutcome> run(CleanupMode mode, {bool dryRun = false}) async {
    if (mode == CleanupMode.skip) return const CleanupOutcome('skipped');
    _reporter.say('Looking for old GitHub sign-ins and settings');
    final found = await find();
    for (final r in found.reportOnly) {
      _reporter.warn(r);
    }
    final items = found.items;
    final n = items.length;
    if (n == 0) {
      _reporter.note('None found.');
      return const CleanupOutcome('nothing to clean');
    }
    _reporter.note('Found these. They can make git or gh use an old GitHub account instead of your Gita sign-in:');
    for (final i in items) {
      _reporter.note('  - ${i.description}');
    }
    if (dryRun) {
      _reporter.note('[dry run] would ask, back up $_gitconfigLabel and remove the items above');
      return const CleanupOutcome('dry run');
    }
    if (mode == CleanupMode.ask) {
      if (!_prompter.interactive) {
        _reporter.warn(
          'No terminal to ask, so nothing was removed. Run this again in a terminal, '
          'or set "cleanup" to "yes" to remove them.',
        );
        return CleanupOutcome('kept ($n found; no terminal to ask)');
      }
      _reporter.note(
        "$_gitconfigLabel is backed up first. Gita's own sign-ins, other sites and SSH keys are not touched.",
      );
      if (!await _prompter.confirm('Remove these?', defaultYes: true)) {
        _reporter.warn("Kept. If cloning later says a project doesn't exist, run this again and answer yes.");
        return CleanupOutcome('kept ($n found)');
      }
    }

    if (!await _backupGitconfig()) {
      _reporter.warn("Couldn't back up $_gitconfigLabel, so nothing was removed.");
      return CleanupOutcome('kept ($n found; backup failed)', failed: true);
    }

    final helpers = items.any((i) => i.kind == CleanupKind.savedLogin)
        ? await _oldHelpers(await _globalConfig())
        : const <String>[];
    var done = 0;
    var ghLoggedOut = false;
    for (final i in items) {
      final ok = switch (i.kind) {
        CleanupKind.savedLogin => await _erase(helpers),
        CleanupKind.credentialManager => await _removeCmdkey(i.arg),
        CleanupKind.gitConfig => await _unset(i.arg),
        CleanupKind.ghLogin => await _ghLogout(i.arg),
        CleanupKind.userTokenVariable => await _removeUserVar(i.arg),
      };
      if (ok) {
        done++;
        if (i.kind == CleanupKind.ghLogin) ghLoggedOut = true;
      }
    }
    _reporter.note('Removed $done of $n.');
    if (ghLoggedOut) _reporter.note('GitHub CLI was signed out. Run "gh auth login" to sign it in again.');
    if (done == n) return CleanupOutcome('cleaned ($n)', ghLoggedOut: ghLoggedOut);
    return CleanupOutcome('cleaned $done of $n (some failed)', ghLoggedOut: ghLoggedOut, failed: true);
  }

  /// Copies ~/.gitconfig to a fresh `.backup-YYYYMMDD-HHMMSS` name (never
  /// over an earlier backup), readable only by the owner on macOS/Linux.
  /// True when there was nothing to back up.
  Future<bool> _backupGitconfig() async {
    final src = File(_path('.gitconfig'));
    if (!src.existsSync()) return true;
    try {
      final bytes = src.readAsBytesSync();
      final t = _now();
      String two(int v) => v.toString().padLeft(2, '0');
      final stamp = '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
      final base = '${src.path}.backup-$stamp';
      var name = base;
      for (var k = 2; FileSystemEntity.typeSync(name, followLinks: false) != FileSystemEntityType.notFound; k++) {
        name = '$base-$k';
      }
      final dst = File(name);
      // Created empty and restricted before the contents go in, so the copy
      // is never readable by others, even for a moment.
      dst.createSync(exclusive: true);
      if (!Platform.isWindows) {
        final r = await _runner.run('chmod', ['600', name]);
        if (!r.ok) {
          dst.deleteSync();
          return false;
        }
      }
      dst.writeAsBytesSync(bytes, flush: true);
      _reporter.note('Backed up $_gitconfigLabel to $name.');
      return true;
    } on Object {
      return false;
    }
  }

  /// Some helpers erase one saved login per call, so this runs three times.
  Future<bool> _erase(List<String> helpers) async {
    var ok = helpers.isNotEmpty;
    for (var t = 0; t < 3 && ok; t++) {
      ok = await _credential('reject', helpers);
    }
    if (!ok) _reporter.warn("Couldn't erase the saved github.com logins.");
    return ok;
  }

  Future<bool> _removeCmdkey(String name) async {
    if (!_safeArg(name)) {
      _reporter.warn("Couldn't remove the Credential Manager entry ${redact(name)}. Remove it in Credential Manager.");
      return false;
    }
    var r = await _runner.run('cmdkey', ['/delete:LegacyGeneric:target=$name']);
    if (!r.ok) r = await _runner.run('cmdkey', ['/delete:$name']);
    if (r.ok) return true;
    // Already gone (erased by the reject above) counts as done.
    final list = await _runner.run('cmdkey', ['/list']);
    if (list.ok && !_cmdkeyEntries(list.stdout).contains(name)) return true;
    _reporter.warn("Couldn't remove the Credential Manager entry ${redact(name)}.");
    return false;
  }

  Future<bool> _unset(String key) async {
    if (_safeArg(key) && (await _gitRun(['config', '--global', '--unset-all', key])).ok) return true;
    _reporter.warn("Couldn't remove the git setting ${redact(key)}. Remove it from $_gitconfigLabel yourself.");
    return false;
  }

  Future<bool> _ghLogout(String login) async {
    final r = await _runner.run(_gh, [
      'auth',
      'logout',
      '--hostname',
      'github.com',
      '--user',
      login,
    ], environment: _noTokens);
    if (r.ok) return true;
    // Older gh has no --user: let it ask which account, but only when someone
    // is there to answer.
    if (_prompter.interactive) {
      final t = await _runner.run(
        _gh,
        ['auth', 'logout', '--hostname', 'github.com'],
        io: CommandIo.terminal,
        environment: _noTokens,
        timeout: const Duration(minutes: 5),
      );
      if (t.ok) return true;
    }
    _reporter.warn('Couldn\'t sign GitHub CLI out of @$login. Run "gh auth logout" yourself.');
    return false;
  }

  Future<bool> _removeUserVar(String name) async {
    final r = await _runner.run('reg', ['delete', _userEnvKey, '/v', name, '/f'], timeout: const Duration(seconds: 30));
    if (r.ok) {
      // reg doesn't tell running programs; new ones started after sign-in see
      // the change for sure.
      _reporter.note('Removed $name. Open a new terminal (or sign out and back in) so programs stop seeing it.');
      return true;
    }
    _reporter.warn("Couldn't remove the environment variable $name. Remove it in System Properties yourself.");
    return false;
  }
}
