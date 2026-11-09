/// The onboarding file read by `gita onboard`: which tools a developer needs,
/// which GitHub accounts they have, and which fixed steps set their machine
/// up. A company writes it once; Gita never fetches it (it is always a local
/// file) and it can't run arbitrary commands.
library;

import 'dart:convert';

/// Whether a tool must be installed.
enum ToolNeed {
  required,
  optional,
  skip;

  static ToolNeed parse(Object? v, String where) => switch (v) {
    null => ToolNeed.required,
    'required' => ToolNeed.required,
    'optional' => ToolNeed.optional,
    'skip' => ToolNeed.skip,
    _ => throw FormatException('$where must be "required", "optional" or "skip".'),
  };
}

/// What to do with old GitHub sign-ins found on the machine.
enum CleanupMode {
  /// List them and ask (keep them when there's no terminal).
  ask,

  /// List them and remove them without asking.
  yes,

  /// Don't look.
  skip;

  static CleanupMode parse(Object? v) => switch (v) {
    null => CleanupMode.ask,
    'ask' => CleanupMode.ask,
    'yes' => CleanupMode.yes,
    'skip' => CleanupMode.skip,
    _ => throw const FormatException('"cleanup" must be "ask", "yes" or "skip".'),
  };
}

/// One GitHub account a developer has, matched by email domain.
class OnboardingAccount {
  const OnboardingAccount({required this.id, required this.label, required this.emailDomain, this.question});

  /// Short key the steps refer to, e.g. `work`.
  final String id;

  /// Gita profile label, e.g. `Acme`.
  final String label;

  /// Lower-case domain the account's email must end with, e.g. `acme.com`.
  final String emailDomain;

  /// What to ask for the email; defaults to "Your @domain email".
  final String? question;

  String get emailQuestion => question ?? 'Your @$emailDomain email';

  /// Whether [email] is a valid address at this account's domain.
  bool acceptsEmail(String email) {
    final e = email.trim().toLowerCase();
    return RegExp(r'^[^@\s]+@[^@\s]+$').hasMatch(e) && e.endsWith('@$emailDomain');
  }
}

/// A fixed step type. Nothing else can appear in the file.
sealed class OnboardingStep {
  const OnboardingStep();

  /// Short text for the plan and the summary.
  String get title;
}

/// Sign the account's profile in to GitHub.
class SignInStep extends OnboardingStep {
  const SignInStep(this.account);
  final String account;
  @override
  String get title => 'Sign-in ($account)';
}

/// Clone a repository with the account's profile, or update / keep / move
/// aside an existing copy.
class RepoStep extends OnboardingStep {
  const RepoStep({required this.account, required this.url, required this.dir});
  final String account;

  /// An address like `https://github.com/owner/repo.git`.
  final String url;

  /// `~/...`: always inside the home folder.
  final String dir;

  String get name => url.split('/').last.replaceFirst(RegExp(r'\.git$'), '');
  @override
  String get title => name;
}

/// Import a Gita company file that is inside a cloned repository.
class CompanyFileStep extends OnboardingStep {
  const CompanyFileStep({required this.account, required this.repoDir, required this.path});
  final String account;
  final String repoDir;

  /// Relative to [repoDir], with `/` separators.
  final String path;
  @override
  String get title => 'Company file $path';
}

/// Run a script that is inside a cloned repository (shown first, then asked).
class RepoScriptStep extends OnboardingStep {
  const RepoScriptStep({required this.repoDir, this.windows, this.unix});
  final String repoDir;

  /// Relative path of a PowerShell script, run on Windows.
  final String? windows;

  /// Relative path of a bash script, run on macOS and Linux.
  final String? unix;
  @override
  String get title => 'Setup script in ${repoDir.split('/').last}';
}

/// Connect Gita to Claude Code (`gita mcp add-to-claude`).
class ClaudeCodeStep extends OnboardingStep {
  const ClaudeCodeStep();
  @override
  String get title => 'Gita in Claude Code';
}

/// Run `gita doctor`.
class DoctorStep extends OnboardingStep {
  const DoctorStep();
  @override
  String get title => 'Gita doctor';
}

/// A parsed, checked onboarding file.
class OnboardingFile {
  const OnboardingFile({
    required this.name,
    required this.tools,
    required this.cleanup,
    required this.accounts,
    required this.steps,
  });

  /// Largest file accepted, in bytes.
  static const maxBytes = 64 * 1024;

  static const _toolNames = {'git', 'gh', 'claude'};

  final String name;
  final Map<String, ToolNeed> tools;
  final CleanupMode cleanup;
  final List<OnboardingAccount> accounts;
  final List<OnboardingStep> steps;

  OnboardingAccount account(String id) => accounts.firstWhere((a) => a.id == id);

  /// Parses and checks [text]. Throws [FormatException] with a message a
  /// person can act on.
  static OnboardingFile parse(String text) {
    if (utf8.encode(text).length > maxBytes) {
      throw const FormatException('The onboarding file is larger than 64 KB.');
    }
    final Object? data;
    try {
      data = jsonDecode(text);
    } on FormatException catch (e) {
      throw FormatException("The onboarding file isn't valid JSON: ${e.message}");
    }
    final root = _object(data, 'The onboarding file');
    _onlyKeys(root, {'format', 'name', 'tools', 'cleanup', 'accounts', 'steps'}, 'The onboarding file');
    if (root['format'] != 1) {
      throw const FormatException('"format" must be 1. This file may be for a newer Gita: update Gita and try again.');
    }
    final name = _string(root['name'], '"name"', max: 64);

    final tools = <String, ToolNeed>{for (final t in _toolNames) t: ToolNeed.skip};
    if (root.containsKey('tools')) {
      final t = _object(root['tools'], '"tools"');
      _onlyKeys(t, _toolNames, '"tools"');
      for (final e in t.entries) {
        tools[e.key] = ToolNeed.parse(e.value, '"tools.${e.key}"');
      }
    }

    final accountList = _list(root['accounts'], '"accounts"', min: 1, max: 10);
    final accounts = <OnboardingAccount>[];
    for (var i = 0; i < accountList.length; i++) {
      final where = '"accounts[$i]"';
      final a = _object(accountList[i], where);
      _onlyKeys(a, {'id', 'label', 'emailDomain', 'question'}, where);
      final id = _string(a['id'], '$where.id', max: 32);
      if (!RegExp(r'^[a-z0-9][a-z0-9-]*$').hasMatch(id)) {
        throw FormatException('$where.id must use only a-z, 0-9 and "-".');
      }
      final domain = _string(a['emailDomain'], '$where.emailDomain', max: 253).toLowerCase().replaceFirst('@', '');
      if (!RegExp(r'^[a-z0-9-]+(\.[a-z0-9-]+)+$').hasMatch(domain)) {
        throw FormatException('$where.emailDomain "$domain" is not a domain like example.com.');
      }
      final account = OnboardingAccount(
        id: id,
        label: _string(a['label'], '$where.label', max: 64),
        emailDomain: domain,
        question: a.containsKey('question') ? _string(a['question'], '$where.question', max: 200) : null,
      );
      if (accounts.any((x) => x.id == account.id)) throw FormatException('Account id "$id" is used twice.');
      if (accounts.any((x) => x.label.toLowerCase() == account.label.toLowerCase())) {
        throw FormatException('Account label "${account.label}" is used twice.');
      }
      if (accounts.any((x) => x.emailDomain == account.emailDomain)) {
        throw FormatException('Email domain "$domain" is used by two accounts.');
      }
      accounts.add(account);
    }

    final stepList = _list(root['steps'], '"steps"', min: 0, max: 50);
    final steps = <OnboardingStep>[];
    final repoDirs = <String>{};
    String accountRef(Map<String, Object?> s, String where) {
      final id = _string(s['account'], '$where.account', max: 32);
      if (!accounts.any((a) => a.id == id)) throw FormatException('$where.account "$id" is not one of the accounts.');
      return id;
    }

    String repoDirRef(Map<String, Object?> s, String where) {
      final dir = _homePath(s['repoDir'], '$where.repoDir');
      if (!repoDirs.contains(dir)) {
        throw FormatException('$where.repoDir "$dir" must be the "dir" of an earlier "repo" step.');
      }
      return dir;
    }

    for (var i = 0; i < stepList.length; i++) {
      final where = '"steps[$i]"';
      final s = _object(stepList[i], where);
      final type = s['type'];
      switch (type) {
        case 'signIn':
          _onlyKeys(s, {'type', 'account'}, where);
          steps.add(SignInStep(accountRef(s, where)));
        case 'repo':
          _onlyKeys(s, {'type', 'account', 'url', 'dir'}, where);
          final url = _string(s['url'], '$where.url', max: 300);
          if (!RegExp(r'^https://github\.com/[A-Za-z0-9-]+/[A-Za-z0-9._-]+?(\.git)?$').hasMatch(url) ||
              url.contains('/../') ||
              url.endsWith('/..')) {
            throw FormatException('$where.url must be a GitHub address like https://github.com/owner/repo.git.');
          }
          final dir = _homePath(s['dir'], '$where.dir');
          if (!repoDirs.add(dir)) throw FormatException('$where.dir "$dir" is used by two "repo" steps.');
          steps.add(RepoStep(account: accountRef(s, where), url: url, dir: dir));
        case 'companyFile':
          _onlyKeys(s, {'type', 'account', 'repoDir', 'path'}, where);
          steps.add(
            CompanyFileStep(
              account: accountRef(s, where),
              repoDir: repoDirRef(s, where),
              path: _relativePath(s['path'], '$where.path'),
            ),
          );
        case 'repoScript':
          _onlyKeys(s, {'type', 'repoDir', 'windows', 'unix'}, where);
          final win = s.containsKey('windows') ? _relativePath(s['windows'], '$where.windows') : null;
          final unix = s.containsKey('unix') ? _relativePath(s['unix'], '$where.unix') : null;
          if (win == null && unix == null) throw FormatException('$where needs "windows", "unix" or both.');
          if (win != null && !win.toLowerCase().endsWith('.ps1')) {
            throw FormatException('$where.windows must be a .ps1 script.');
          }
          if (unix != null && !unix.endsWith('.sh')) throw FormatException('$where.unix must be a .sh script.');
          steps.add(RepoScriptStep(repoDir: repoDirRef(s, where), windows: win, unix: unix));
        case 'claudeCode':
          _onlyKeys(s, {'type'}, where);
          steps.add(const ClaudeCodeStep());
        case 'doctor':
          _onlyKeys(s, {'type'}, where);
          steps.add(const DoctorStep());
        default:
          throw FormatException(
            '$where.type must be one of signIn, repo, companyFile, repoScript, claudeCode, doctor.',
          );
      }
    }

    return OnboardingFile(
      name: name,
      tools: tools,
      cleanup: CleanupMode.parse(root['cleanup']),
      accounts: accounts,
      steps: steps,
    );
  }

  // ---------------------------------------------------------------- helpers

  static Map<String, Object?> _object(Object? v, String where) {
    if (v is Map<String, Object?>) return v;
    throw FormatException('$where must be an object.');
  }

  static List<Object?> _list(Object? v, String where, {required int min, required int max}) {
    if (v is! List<Object?>) throw FormatException('$where must be a list.');
    if (v.length < min) throw FormatException('$where needs at least $min entr${min == 1 ? 'y' : 'ies'}.');
    if (v.length > max) throw FormatException('$where has more than $max entries.');
    return v;
  }

  static void _onlyKeys(Map<String, Object?> m, Set<String> allowed, String where) {
    final unknown = m.keys.where((k) => !allowed.contains(k)).toList();
    if (unknown.isNotEmpty) {
      throw FormatException(
        '$where has unknown field${unknown.length == 1 ? '' : 's'} '
        '${unknown.map((k) => '"$k"').join(', ')}. Allowed: ${allowed.join(', ')}.',
      );
    }
  }

  static String _string(Object? v, String where, {required int max}) {
    if (v is! String || v.trim().isEmpty) throw FormatException('$where must be a non-empty text.');
    if (v.length > max) throw FormatException('$where is longer than $max characters.');
    if (_hasControl(v)) {
      throw FormatException('$where contains control characters.');
    }
    return v.trim();
  }

  /// `~/a/b`: inside the home folder, no `..`, no empty parts.
  static String _homePath(Object? v, String where) {
    final s = _string(v, where, max: 260);
    final parts = s.split('/');
    if (parts.first != '~' ||
        parts.length < 2 ||
        parts.skip(1).any((x) => x.isEmpty || x == '.' || x == '..') ||
        s.contains(r'\')) {
      throw FormatException('$where must be a folder inside your home folder, like "~/projects/handbook".');
    }
    return s;
  }

  /// `a/b.json`: relative, `/` separators, no `..`.
  static String _relativePath(Object? v, String where) {
    final s = _string(v, where, max: 260);
    final parts = s.split('/');
    if (s.startsWith('/') ||
        s.contains(r'\') ||
        s.contains(':') ||
        parts.any((x) => x.isEmpty || x == '.' || x == '..')) {
      throw FormatException('$where must be a path inside the repository, like "gita/work.json".');
    }
    return s;
  }
}

/// Whether [v] has characters that can hide or fake text on a terminal:
/// C0/C1 control characters, zero-width marks and bidirectional overrides.
bool _hasControl(String v) => v.runes.any(
  (r) =>
      r < 0x20 ||
      (r >= 0x7f && r <= 0x9f) ||
      (r >= 0x200b && r <= 0x200f) ||
      (r >= 0x202a && r <= 0x202e) ||
      (r >= 0x2066 && r <= 0x2069),
);
