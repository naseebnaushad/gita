import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../core/models/doctor_issue.dart';
import '../core/models/mismatch_report.dart';
import '../core/models/profile.dart';
import '../core/models/repo_rule.dart';
import '../core/services/clone_service.dart';
import '../core/services/company_setup.dart';
import '../core/services/git_config_sync.dart';
import '../core/services/git_service.dart';
import '../core/services/github_device_flow.dart';
import '../core/services/github_oauth_config.dart';
import '../core/services/hook_service.dart';
import '../core/services/identity_doctor_service.dart';
import '../core/services/machine_scanner.dart';
import '../core/services/mismatch_detector.dart';
import '../core/services/path_resolver.dart';
import '../core/services/path_setup.dart';
import '../core/services/platform_paths.dart';
import '../core/services/push_guard.dart';
import '../core/services/setup_service.dart';
import '../core/services/ssh_config_service.dart';
import '../core/services/token_store.dart';
import '../core/storage/repositories.dart';
import 'mcp_server.dart';

part 'gh_command.dart';
part 'manage_commands.dart';

/// Exit codes shared by every command, so hooks and agent integrations can
/// branch on them without parsing output.
abstract final class ExitCodes {
  /// Everything is fine (warnings may still have been printed).
  static const ok = 0;

  /// Gita found a problem that would make a commit or push use the wrong
  /// account, or a setup issue that will make one fail.
  static const problem = 1;

  /// The command couldn't run: bad arguments, or not inside a git project.
  static const usage = 2;
}

/// Runs another program and waits for it.
typedef ProcessRunner = Future<ProcessResult> Function(String executable, List<String> arguments);

/// Headless entry point to Gita's core services.
///
/// This is pure Dart (no Flutter imports) so it can be compiled with
/// `dart compile exe` and called by git hooks, credential helpers and AI
/// agent integrations, none of which can drive the desktop app.
///
/// Human-readable output is written for people who don't know git: it says
/// what's wrong and what to do next, without git jargon. `--json` gives a
/// stable machine-readable shape instead.
class GitaCli {
  GitaCli({
    required this.out,
    required this.err,
    this.paths = const PlatformPaths(),
    this.gitService = const GitService(),
    IdentityDoctorService? doctorService,
    TokenStore? tokenStore,
    this.input,
    this.cwd = '.',
    this.deviceFlow,
    Future<bool> Function(Uri url)? openBrowser,
    ProcessRunner? runProcess,
    InteractiveRunner? runInteractive,
    Map<String, String>? environment,
    PathSetup? pathSetup,
  })  : runProcess = runProcess ?? _defaultRunProcess,
        runInteractive = runInteractive ?? _defaultRunInteractive,
        environment = environment ?? Platform.environment,
        pathSetup = pathSetup ?? PathSetup(paths: paths),
        tokenStore = tokenStore ?? TokenStore(),
        openBrowser = openBrowser ?? defaultOpenBrowser {
    this.doctorService = doctorService ??
        IdentityDoctorService(paths: paths, tokenStore: this.tokenStore);
  }

  final StringSink out;
  final StringSink err;

  /// Puts the command on PATH for new terminals (`gita path`).
  final PathSetup pathSetup;
  final PlatformPaths paths;
  final GitService gitService;
  late final IdentityDoctorService doctorService;
  final TokenStore tokenStore;

  /// What git writes to the credential helper. Defaults to stdin.
  final Stream<List<int>>? input;

  /// The folder commands without a folder argument work on (hooks run in
  /// the project folder).
  final String cwd;

  /// GitHub sign-in for `gita sign-in`. Defaults to Gita's OAuth app.
  final GitHubDeviceFlow? deviceFlow;

  /// Opens the GitHub sign-in page for `gita sign-in`.
  final Future<bool> Function(Uri url) openBrowser;

  /// Runs other programs (`gita mcp add-to-claude` runs `claude`).
  final ProcessRunner runProcess;

  /// Runs `gh` for `gita gh`, attached to the terminal.
  final InteractiveRunner runInteractive;

  /// Environment `gita gh` starts `gh` with (plus `GH_TOKEN`) and searches
  /// PATH in. Defaults to Gita's own.
  final Map<String, String> environment;

  static Future<ProcessResult> _defaultRunProcess(String executable, List<String> arguments) =>
      Process.run(executable, arguments, runInShell: Platform.isWindows);

  static const version = '1.0.3';

  ArgParser _buildParser() {
    ArgParser command() => ArgParser()
      ..addFlag('json', negatable: false)
      ..addFlag('help', abbr: 'h', negatable: false);
    return ArgParser()
      ..addFlag('help', abbr: 'h', negatable: false)
      ..addFlag('version', negatable: false)
      ..addCommand('which', command())
      ..addCommand('check', command())
      ..addCommand(
        'doctor',
        command()..addFlag('fix', negatable: false, help: 'Fix what can be fixed without you.'),
      )
      ..addCommand('guard', command())
      ..addCommand('path', command())
      ..addCommand('profiles', command())
      ..addCommand('scan', command())
      ..addCommand(
        'setup',
        command()
          ..addMultiOption('only', help: 'Only set up the account with this email.')
          ..addFlag('no-track', negatable: false, help: "Don't add the safety check to the projects."),
      )
      ..addCommand(
        'profile',
        command()
          ..addOption('name', help: 'Name to commit with.')
          ..addOption('email', help: 'Email to commit with.')
          ..addOption('label', help: 'Short name for the profile, like "Work".')
          ..addOption('github-login', help: 'GitHub account name.')
          ..addMultiOption('folder', help: 'Folder whose projects use this profile.'),
      )
      ..addCommand(
        'rule',
        command()
          ..addOption('profile', help: 'Name or id of the profile.')
          ..addOption('folder', help: 'Folder whose projects use the profile.')
          ..addOption('owner', help: 'GitHub account or organization whose projects use the profile.')
          ..addOption('host', help: 'Git host for --owner (default github.com).'),
      )
      ..addCommand(
        'clone',
        command()
          ..addOption('profile', help: 'Name or id of the profile to clone as.')
          ..addFlag('no-track', negatable: false, help: "Don't add the safety check."),
      )
      ..addCommand(
        'company',
        command()
          ..addOption('profile', help: 'Name or id of the work profile.'),
      )
      ..addCommand(
        'sign-in',
        command()
          ..addOption('profile', help: 'Name or id of the profile to sign in.')
          ..addFlag('with-token', negatable: false, help: 'Read a token from stdin.')
          ..addFlag('no-browser', negatable: false, help: "Don't open the browser.")
          // Used by `gita mcp`: print the code and finish in the background.
          ..addFlag('no-wait', negatable: false, hide: true),
      )
      ..addCommand('mcp', command())
      ..addCommand('hook', ArgParser(allowTrailingOptions: false))
      ..addCommand(
        'credential',
        ArgParser()
          ..addOption('profile', help: 'Profile id whose token to use.')
          ..addFlag('help', abbr: 'h', negatable: false),
      );
  }

  Future<int> run(List<String> arguments) async {
    // Before parsing: everything after `gh` belongs to the GitHub CLI,
    // including its own --json and --help.
    if (arguments.isNotEmpty && arguments.first == 'gh') {
      return _gh(arguments.sublist(1));
    }
    final parser = _buildParser();
    final ArgResults results;
    try {
      results = parser.parse(arguments);
    } on FormatException catch (e) {
      err
        ..writeln(e.message)
        ..writeln()
        ..write(_usage());
      return ExitCodes.usage;
    }

    if (results['version'] as bool) {
      out.writeln('gita $version');
      return ExitCodes.ok;
    }

    final command = results.command;
    final wantsHelp =
        results['help'] as bool || (command != null && command.options.contains('help') && command['help'] as bool);
    if (wantsHelp) {
      out.write(_usage());
      return ExitCodes.ok;
    }
    if (command == null) {
      if (results.rest.isNotEmpty) {
        err
          ..writeln('Unknown command: ${results.rest.first}')
          ..writeln();
      }
      err.write(_usage());
      return ExitCodes.usage;
    }

    if (command.name == 'hook') {
      return _hook(command.rest);
    }
    if (command.name == 'credential') {
      return _credential(command['profile'] as String?, command.rest);
    }

    final json = command['json'] as bool;
    switch (command.name) {
      case 'which':
        return _which(command.rest, json: json);
      case 'check':
        return _check(command.rest, json: json);
      case 'doctor':
        return _doctor(json: json, fix: command['fix'] as bool);
      case 'setup':
        return _setup(command, json: json);
      case 'profile':
        return _profile(command, json: json);
      case 'rule':
        return _rule(command, json: json);
      case 'guard':
        return _guard(command.rest, json: json);
      case 'path':
        return _path(command.rest, json: json);
      case 'profiles':
        return _profiles(json: json);
      case 'scan':
        return _scan(command.rest, json: json);
      case 'clone':
        return _clone(command, json: json);
      case 'sign-in':
        return _signIn(command, json: json);
      case 'company':
        return _company(command, json: json);
      case 'mcp':
        return _mcp(command.rest, json: json);
    }
    return ExitCodes.usage;
  }

  String _usage() => '''
Gita keeps each project on the right GitHub account.

Usage: gita <command> [folder] [--json]

Commands:
  which [folder]   Show which account this project should use, and which
                   one it is using right now.
  check [folder]   Same as "which", but exits with an error if the project
                   would commit or push with the wrong account.
  doctor           Look for setup problems (missing keys, broken rules)
                   before they cause a failed commit or push.
                   --fix also fixes what can be fixed without you.
  setup [folder...] [--only <email>]...
                   Look through this computer's projects (like "scan"),
                   then set up what was found: a profile per account,
                   folder rules, SSH keys and the safety check. --only
                   sets up just those accounts; --no-track skips the
                   safety check.
  profile add --name <name> --email <email> [--label <label>]
              [--github-login <account>] [--folder <folder>]...
                   Add a profile by hand. Projects in each --folder
                   use it.
  profile edit <name or id> [--name ...] [--email ...] [--label ...]
              [--github-login ...]
                   Change a profile.
  rule list        Show which folders and GitHub accounts use which
                   profile.
  rule add --profile <name or id> --folder <folder>
  rule add --profile <name or id> --owner <account or organization>
                   Make projects in a folder, or from a GitHub account
                   or organization (wherever they are), use a profile.
  rule remove <rule id, folder, or host/owner>
                   Take a rule out again.
  guard install [folder]
                   Add Gita's safety check to a project, so a commit or
                   push with the wrong account is stopped before it
                   happens. (Gita does this for projects you add in the app.)
  guard remove [folder]
                   Take the safety check out again.
  guard status [folder]
                   Say whether the safety check is in place.
  path [status]    Say whether new terminals find the gita command.
  path add         Make new terminals find it: adds ~/.gita/bin to PATH in
                   your shell's startup files (zsh, bash, fish; macOS and
                   Linux). The app does this once by itself.
  path remove      Take that out again.
  profiles         List your profiles: email, GitHub account, sign-in,
                   SSH key and folders.
  scan [folder...] Look through this computer's projects for the accounts
                   they commit with, and suggest profiles and folders.
                   Only looks; changes nothing. Without a folder it looks
                   in the usual places (Projects, source/repos, ...).
  clone <address> [folder] [--profile <name or id>]
                   Download a project with the right account's sign-in
                   and SSH key, then make sure it keeps using that
                   account (adds a folder rule if needed, and the safety
                   check). Without --profile, Gita picks the profile whose
                   GitHub account owns the project, or whose folder it
                   goes in. Without a folder, it goes in the profile's
                   folder.
  company import <file> [--profile <name or id>]
                   Read your company's setup file and make every project
                   from its GitHub organizations use your work profile,
                   wherever it is on this computer. Without --profile,
                   Gita picks the profile with a company email.
  company list     Show the company setups on this computer.
  mcp add-to-claude
                   Let Claude Code (the AI coding tool) ask Gita which
                   account to use before it commits, pushes or clones.
                   Run once; needs Claude Code installed.
  mcp              Run Gita for AI tools (MCP). AI tools start this by
                   themselves; you don't need to run it.
  sign-in --profile <name or id>
                   Sign a profile in to GitHub (shows a code to enter on
                   github.com), so HTTPS pushes use that account.
                   --with-token reads a token from stdin instead;
                   --no-browser doesn't open the browser.
  gh [--profile <name or id>] <gh command...>
                   Run the GitHub CLI (gh) as the account this project
                   belongs to, for example: gita gh pr create --fill
                   Gita gives gh that profile's GitHub sign-in for this
                   one command; gh's own login isn't used or changed.
                   Everything after "gh" goes to gh, including --json.
                   Exit code is gh's.

[folder] defaults to the current folder.

Git also runs "gita credential --profile <id> get" by itself to sign in
when you push over HTTPS. You don't need to run it.

Options:
  --json           Print machine-readable JSON (for scripts and AI tools).
  -h, --help       Show this help.
  --version        Show the Gita version.

Exit codes: 0 = all good, 1 = problem found, 2 = couldn't run.
''';

  // ------------------------------------------------------------------ mcp

  Future<int> _mcp(List<String> rest, {required bool json}) async {
    if (rest.isEmpty) {
      final server = GitaMcpServer(
        version: version,
        output: out,
        run: (args) async {
          final o = StringBuffer();
          final e = StringBuffer();
          final code = await GitaCli(
            out: o,
            err: e,
            paths: paths,
            gitService: gitService,
            doctorService: doctorService,
            tokenStore: tokenStore,
            cwd: cwd,
            deviceFlow: deviceFlow,
            openBrowser: openBrowser,
            runProcess: runProcess,
            // Tools must never wait for typing: stdin carries MCP messages.
            input: const Stream<List<int>>.empty(),
          ).run(args);
          return (exitCode: code, out: o.toString(), err: e.toString());
        },
      );
      await server.serve(
        (input ?? stdin).transform(utf8.decoder).transform(const LineSplitter()),
      );
      return ExitCodes.ok;
    }
    if (rest.length == 1 && rest.first == 'add-to-claude') {
      return _mcpAddToClaude(json: json);
    }
    err
      ..writeln('Unknown: gita mcp ${rest.join(' ')}')
      ..writeln('Use "gita mcp add-to-claude" to connect Claude Code to Gita.');
    return ExitCodes.usage;
  }

  Future<int> _mcpAddToClaude({required bool json}) async {
    final exe = File(paths.cliPath).existsSync() ? paths.cliPath : Platform.resolvedExecutable;
    final name = p.basenameWithoutExtension(exe).toLowerCase();
    if (name != 'gita') {
      // Running from source (`dart run`): there's no gita program to point at.
      err.writeln("Couldn't find the installed gita program. Open the Gita app once "
          '(it installs it), then try again.');
      return ExitCodes.usage;
    }
    final args = ['mcp', 'add', '--transport', 'stdio', '--scope', 'user', 'gita', '--', exe, 'mcp'];
    final manual = 'claude ${args.map(_quoteArg).join(' ')}';

    ProcessResult? result;
    try {
      // Replace an older entry (e.g. one pointing at a previous location).
      await runProcess('claude', ['mcp', 'remove', '--scope', 'user', 'gita']);
      result = await runProcess('claude', args);
    } on ProcessException {
      result = null;
    }
    if (result != null && result.exitCode != 0) {
      final text = '${result.stderr} ${result.stdout}'.toLowerCase();
      if (result.exitCode == 127 || text.contains('not recognized') || text.contains('not found')) {
        result = null; // The shell couldn't find claude.
      }
    }
    final ok = result != null && result.exitCode == 0;
    if (json) {
      out.writeln(jsonEncode({
        'ok': ok,
        'command': manual,
        if (result != null && !ok) 'error': '${result.stderr}'.trim(),
      }));
    } else if (ok) {
      out
        ..writeln('Done. Claude Code can now ask Gita which account to use.')
        ..writeln('Restart any open Claude Code sessions to pick it up.');
    } else {
      final why = result == null ? 'Claude Code (the "claude" command) isn\'t installed.' : '${result.stderr}'.trim();
      err
        ..writeln("Couldn't connect Claude Code to Gita.")
        ..writeln(why)
        ..writeln()
        ..writeln('Once Claude Code is installed, run this again, or run:')
        ..writeln('  $manual');
    }
    return ok ? ExitCodes.ok : ExitCodes.problem;
  }

  static String _quoteArg(String a) => a.contains(' ') ? '"$a"' : a;

  // ------------------------------------------------------------- profiles

  Future<int> _profiles({required bool json}) async {
    final profiles = await ProfileRepository(paths: paths).getAll();
    final rules = await RepoRuleRepository(paths: paths).getAll();
    final rows = <Map<String, Object?>>[];
    for (final p in profiles) {
      rows.add({
        'id': p.id,
        'label': p.label,
        'name': p.gitName,
        'email': p.gitEmail,
        'githubLogin': p.githubLogin,
        'signedIn': await tokenStore.hasToken(p.id),
        if (_backgroundSignIns[p.id] case final state?)
          state == 'waiting' ? 'signInWaiting' : 'signInError': state == 'waiting' ? true : state,
        'sshKey': p.sshKeyId != null,
        'folders': [
          for (final r in rules)
            if (r.profileId == p.id &&
                !r.isAccountRule &&
                r.pathPattern.isNotEmpty)
              r.pathPattern,
        ],
        'accounts': [
          for (final r in rules)
            if (r.profileId == p.id && r.isAccountRule) r.describe,
        ],
      });
    }
    if (json) {
      out.writeln(_encode({'ok': true, 'profiles': rows}));
      return ExitCodes.ok;
    }
    if (rows.isEmpty) {
      out.writeln('No profiles yet. Open Gita and add one under Profiles.');
      return ExitCodes.ok;
    }
    for (final r in rows) {
      final login = r['githubLogin'] == null ? '' : '  @${r['githubLogin']}';
      final signedIn = r['signedIn'] == true
          ? 'saved'
          : 'none (run "gita sign-in --profile ${r['id']}")';
      final folders = r['folders']! as List;
      final accounts = r['accounts']! as List;
      out
        ..writeln('${r['label']}  (id: ${r['id']})$login')
        ..writeln('  Commits as:      ${r['name']} <${r['email']}>')
        ..writeln('  GitHub sign-in:  $signedIn')
        ..writeln('  SSH key:         ${r['sshKey'] == true ? 'yes' : 'no'}')
        ..writeln(
          folders.isEmpty
              ? '  Folders:         none yet (add a rule in Gita)'
              : '  Folders:         ${folders.join(', ')}',
        )
        ..write(
          accounts.isEmpty ? '' : '  Projects from:   ${accounts.join(', ')}\n',
        )
        ..writeln();
    }
    return ExitCodes.ok;
  }

  // ----------------------------------------------------------------- scan

  Future<int> _scan(List<String> folders, {required bool json}) async {
    final missing = [for (final f in folders) if (!Directory(f).existsSync()) f];
    if (missing.isNotEmpty) {
      _fail('No such folder: ${missing.join(', ')}', json: json);
      return ExitCodes.usage;
    }
    final scanner = MachineScanner(paths: paths, git: gitService);
    final scan = await scanner.scan(
      searchFolders: folders.isEmpty ? null : [for (final f in folders) resolveRepoPath(f)],
      existingProfiles: await ProfileRepository(paths: paths).getAll(),
    );
    if (json) {
      out.writeln(_encode({'ok': true, ...scan.toJson()}));
      return ExitCodes.ok;
    }
    if (scan.searchedFolders.isEmpty) {
      out
        ..writeln("Didn't find any of the usual project folders.")
        ..writeln('Say where your projects are: gita scan <folder> [folder...]');
      return ExitCodes.ok;
    }
    out
      ..writeln('Looked in: ${scan.searchedFolders.join(', ')}')
      ..writeln('Found ${scan.repos.length} project(s) and ${scan.sshKeys.length} SSH key(s).')
      ..writeln();
    if (scan.suggestions.isEmpty) {
      out.writeln('No accounts found. Add a profile in Gita yourself.');
      return ExitCodes.ok;
    }
    for (final s in scan.suggestions) {
      final tags = [
        if (s.isGlobalDefault) 'used where no rule applies',
        if (s.existingProfileId != null) 'already a profile',
      ];
      out.writeln('${s.label}: ${s.name} <${s.email}>'
          '${tags.isEmpty ? '' : '  (${tags.join(', ')})'}');
      if (s.githubLogin != null) out.writeln('  GitHub account:  @${s.githubLogin}');
      out
        ..writeln('  Projects:        ${s.repos.length}')
        ..writeln('  SSH key:         ${s.sshKey?.privateKeyPath ?? 'none found'}');
      if (s.folders.isEmpty) {
        out.writeln('  Folders:         none');
      } else {
        out.writeln('  Folders:');
        for (final f in s.folders) {
          out.writeln('    $f');
        }
      }
      out.writeln();
    }
    if (scan.unknownRepos.isNotEmpty) {
      out
        ..writeln("${scan.unknownRepos.length} project(s) have no commits yet, so their "
            "account couldn't be told:")
        ..writeAll([for (final r in scan.unknownRepos.take(10)) '  ${r.path}\n']);
      if (scan.unknownRepos.length > 10) out.writeln('  ...');
      out.writeln();
    }
    out.writeln('Nothing was changed. To set these up, open Gita and press '
        '"Scan this computer" under Profiles.');
    return ExitCodes.ok;
  }

  // -------------------------------------------------------------- sign-in

  /// Signs a profile in to GitHub: either the device flow (show a code,
  /// open github.com/login/device, wait) or, with --with-token, a token
  /// read from stdin. Saves the token, records the account on the profile
  /// and turns on HTTPS pushes for it.
  // -------------------------------------------------------------- company

  Future<int> _company(ArgResults command, {required bool json}) async {
    final rest = command.rest;
    final service = CompanyService(paths: paths);
    if (rest.length == 1 && rest.first == 'list') {
      final setups = await service.load();
      if (json) {
        out.writeln(
          _encode({
            'ok': true,
            'companies': [for (final s in setups) s.toJson()],
          }),
        );
        return ExitCodes.ok;
      }
      if (setups.isEmpty) {
        out.writeln(
          'No company setup yet. Import one with: gita company import <file>',
        );
        return ExitCodes.ok;
      }
      final rules = await RepoRuleRepository(paths: paths).getAll();
      final profiles = {
        for (final x in await ProfileRepository(paths: paths).getAll()) x.id: x,
      };
      for (final s in setups) {
        out.writeln(
          '${s.name}  (emails: ${s.emailDomains.isEmpty ? 'any' : s.emailDomains.map((d) => '@$d').join(', ')})',
        );
        for (final owner in s.owners) {
          final rule = s.ruleFor(owner, rules);
          final profile = profiles[rule?.profileId];
          out.writeln(
            '  ${s.host}/$owner  ->  ${profile == null ? 'no profile set' : '${profile.label} <${profile.gitEmail}>'}',
          );
        }
      }
      return ExitCodes.ok;
    }
    if (rest.length != 2 || rest.first != 'import') {
      _fail(
        'Usage: gita company import <file> [--profile <name>]  or  gita company list',
        json: json,
      );
      return ExitCodes.usage;
    }

    final file = File(p.absolute(cwd, rest[1]));
    if (!file.existsSync()) {
      _fail(
        "There's no file at ${file.path}. Ask whoever sent it for the company setup file.",
        json: json,
      );
      return ExitCodes.usage;
    }
    final CompanySetup setup;
    try {
      setup = CompanySetup.parse(await file.readAsString());
    } on FormatException catch (e) {
      _fail(e.message, json: json);
      return ExitCodes.usage;
    }

    final profiles = await ProfileRepository(paths: paths).getAll();
    if (profiles.isEmpty) {
      _fail(
        'There are no profiles yet. Open Gita and add your work profile first (or press "Scan this computer").',
        json: json,
      );
      return ExitCodes.usage;
    }
    final wanted = command['profile'] as String?;
    Profile? profile;
    if (wanted != null) {
      profile = _findProfile(profiles, wanted);
      if (profile == null) {
        final names = profiles.map((x) => '"${x.label}" (${x.id})').join(', ');
        _fail(
          'There is no profile called "$wanted". Profiles: $names',
          json: json,
        );
        return ExitCodes.usage;
      }
    } else {
      profile = CompanyService.pickProfile(setup, profiles);
      if (profile == null) {
        final company = setup.companyProfiles(profiles);
        final names = (company.isEmpty ? profiles : company)
            .map((x) => x.label)
            .join(', ');
        final domains = setup.emailDomains.map((d) => '@$d').join(' or ');
        _fail(
          company.isEmpty
              ? 'No profile commits with a ${setup.name} email${domains.isEmpty ? '' : ' ($domains)'}. '
                    'Say which profile is your work one: gita company import ${rest[1]} --profile <name>  (profiles: $names)'
              : 'More than one profile has a ${setup.name} email. Say which: '
                    'gita company import ${rest[1]} --profile <name>  (profiles: $names)',
          json: json,
        );
        return ExitCodes.usage;
      }
    }

    final result = await service.import(
      setup,
      profile,
      hasToken: tokenStore.hasToken,
    );
    var message = result.message(setup);
    if (setup.emailDomains.isNotEmpty &&
        !setup.isCompanyEmail(profile.gitEmail)) {
      message +=
          ' Note: "${profile.label}" commits as ${profile.gitEmail}, which is not a '
          '${setup.name} email, so "gita doctor" will warn about it.';
    }
    if (json) {
      out.writeln(
        _encode({
          'ok': true,
          'company': setup.name,
          ...result.toJson(),
          'message': message,
        }),
      );
    } else {
      out.writeln(message);
    }
    return ExitCodes.ok;
  }

  Future<int> _clone(ArgResults command, {required bool json}) async {
    if (command.rest.isEmpty || command.rest.length > 2) {
      _fail(
        'Say what to clone: gita clone <address> [folder] [--profile <name>]. '
        "The address is on the project's GitHub page, under the green Code button.",
        json: json,
      );
      return ExitCodes.usage;
    }
    final url = command.rest.first;
    if (!CloneService.looksLikeGitUrl(url)) {
      _fail(
        "\"$url\" doesn't look like a project address. Copy it from the green "
        'Code button on GitHub, e.g. https://github.com/acme/api.git',
        json: json,
      );
      return ExitCodes.usage;
    }
    final service = CloneService(paths: paths, git: gitService);
    final profiles = await ProfileRepository(paths: paths).getAll();
    final rules = await RepoRuleRepository(paths: paths).getAll();
    if (profiles.isEmpty) {
      _fail('There are no profiles yet. Open Gita and add one (or press "Scan this computer").', json: json);
      return ExitCodes.usage;
    }

    final name = CloneService.repoNameFromUrl(url) ?? 'project';
    String? destination = command.rest.length == 2 ? resolveRepoPath(p.normalize(p.absolute(cwd, command.rest[1]))) : null;

    final wanted = command['profile'] as String?;
    Profile? profile;
    if (wanted != null) {
      profile = _findProfile(profiles, wanted);
      if (profile == null) {
        final names = profiles.map((x) => '"${x.label}" (${x.id})').join(', ');
        _fail('There is no profile called "$wanted". Profiles: $names', json: json);
        return ExitCodes.usage;
      }
    } else {
      profile = CloneService.suggestProfile(url, profiles, rules: rules);
      if (profile == null && destination != null) {
        final rule = RepoRule.bestMatchFor(destination, rules);
        profile = profiles.where((x) => x.id == rule?.profileId).firstOrNull;
      }
      if (profile == null) {
        final names = profiles.map((x) => x.label).join(', ');
        _fail(
          "Gita can't tell which account this project belongs to. Say which "
          'with --profile, for example: gita clone $url --profile ${profiles.first.label}  '
          '(profiles: $names)',
          json: json,
        );
        return ExitCodes.usage;
      }
    }
    destination ??= p.posix.join(service.parentFolderFor(profile, rules), name);

    if (!json) out.writeln('Cloning as ${profile.label} <${profile.gitEmail}> into $destination ...');
    final outcome = await service.clone(
      url: url,
      destination: destination,
      profile: profile,
      hasToken: tokenStore.hasToken,
      track: !(command['no-track'] as bool),
    );
    if (json) {
      out.writeln(_encode({...outcome.toJson(), 'profile': profile.id}));
    } else if (outcome.ok) {
      out.writeln(outcome.message);
      if (outcome.addedRule) out.writeln('Added a rule so this folder always uses ${profile.label}.');
      if (outcome.guardAdded) out.writeln('Added the safety check.');
      if (outcome.guardProblem != null) out.writeln('Safety check not added: ${outcome.guardProblem}');
    } else {
      err.writeln(outcome.message);
      switch (outcome.problem) {
        case CloneProblem.signIn:
          err.writeln('To sign in: gita sign-in --profile "${profile.label}"');
        case CloneProblem.helper:
          err.writeln('To reinstall it: open the Gita app (it installs the gita command when '
              'it starts), or run "gita doctor".');
        case CloneProblem.sshKey || null:
          break;
      }
      if (outcome.gitDetail != null) err.writeln('git said: ${outcome.gitDetail}');
    }
    return outcome.ok ? ExitCodes.ok : ExitCodes.problem;
  }

  Future<int> _signIn(ArgResults command, {required bool json}) async {
    final wanted = command['profile'] as String?;
    if (wanted == null || wanted.trim().isEmpty) {
      _fail('Say which profile to sign in: gita sign-in --profile <name or id>', json: json);
      return ExitCodes.usage;
    }
    final repo = ProfileRepository(paths: paths);
    final profiles = await repo.getAll();
    final profile = _findProfile(profiles, wanted);
    if (profile == null) {
      final names = profiles.map((p) => '"${p.label}" (${p.id})').join(', ');
      _fail(
        'There is no profile called "$wanted".'
        '${names.isEmpty ? ' Add one in Gita first.' : ' Profiles: $names'}',
        json: json,
      );
      return ExitCodes.usage;
    }

    final flow = deviceFlow ?? _defaultDeviceFlow();
    final String token;
    final GitHubAccount account;
    try {
      if (command['with-token'] as bool) {
        token = (await (input ?? stdin).transform(utf8.decoder).join()).trim();
        if (token.isEmpty) {
          _fail(
            'No token was given. Pipe it in, for example: '
            'echo <token> | gita sign-in --profile ${profile.id} --with-token',
            json: json,
          );
          return ExitCodes.usage;
        }
        // Only the GitHub API is used here; the client ID doesn't matter.
        account = await (flow ?? GitHubDeviceFlow(clientId: '')).fetchAccount(token);
      } else {
        if (flow == null) {
          _fail(
            'This copy of Gita has no GitHub sign-in app set up. Create a token '
            'on github.com and pipe it in with --with-token instead.',
            json: json,
          );
          return ExitCodes.problem;
        }
        final code = await flow.start();
        if (command['no-wait'] as bool) {
          return _signInInBackground(flow, code, profile,
              json: json, openTheBrowser: !(command['no-browser'] as bool));
        }
        if (json) {
          out.writeln(jsonEncode({
            'step': 'enter-code',
            'code': code.userCode,
            'url': code.verificationUri.toString(),
          }));
        } else {
          out
            ..writeln('Signing "${profile.label}" in to GitHub.')
            ..writeln()
            ..writeln('  1. Open ${code.verificationUri}')
            ..writeln('  2. Sign in as the GitHub account for "${profile.label}".')
            ..writeln('  3. Enter this code: ${code.userCode}')
            ..writeln('  4. Press Authorize.')
            ..writeln()
            ..writeln('Waiting for GitHub...');
        }
        if (!(command['no-browser'] as bool)) await openBrowser(code.verificationUri);
        token = await flow.waitForToken(code);
        account = await flow.fetchAccount(token);
      }
    } on DeviceFlowException catch (e) {
      _fail(e.message, json: json);
      return ExitCodes.problem;
    }

    final (:emailNote, :switched, :previous) = await _saveSignIn(profile, token, account);
    if (json) {
      out.writeln(_encode({
        'ok': true,
        'profile': profile.id,
        'githubLogin': account.login,
        'previousLogin': ?(switched == null ? null : previous),
        'note': ?emailNote,
      }));
    } else {
      out
        ..writeln()
        ..writeln('Done: "${profile.label}" is signed in as @${account.login}. '
            'Pushes over HTTPS in its folders now use this account.');
      if (switched != null) out.writeln(switched);
      if (emailNote != null) out.writeln(emailNote);
    }
    return ExitCodes.ok;
  }

  /// Saves a finished sign-in: the token, the GitHub account on the
  /// profile, and git's settings.
  Future<({String? emailNote, String? switched, String? previous})> _saveSignIn(
    Profile signedIn,
    String token,
    GitHubAccount account,
  ) async {
    final repo = ProfileRepository(paths: paths);
    final profiles = await repo.getAll();
    // Read it again: it may have changed while the person was on GitHub.
    final profile = profiles.where((p) => p.id == signedIn.id).firstOrNull ?? signedIn;
    await tokenStore.saveToken(profile.id, token);
    final updated = profile.copyWith(githubLogin: account.login);
    await repo.upsert(updated);
    await syncGitConfig(
      paths: paths,
      hasToken: tokenStore.hasToken,
      profiles: [
        for (final p in profiles) p.id == updated.id ? updated : p,
        if (!profiles.any((p) => p.id == updated.id)) updated,
      ],
    );

    final email = account.email;
    final emailNote = email != null && email.toLowerCase() != profile.gitEmail.toLowerCase()
        ? "Note: this GitHub account's main email is $email, but "
            '"${profile.label}" commits as ${profile.gitEmail}. That is fine if '
            '${profile.gitEmail} is also added to the account on GitHub.'
        : null;
    final previous = profile.githubLogin;
    final switched = previous != null && previous.toLowerCase() != account.login.toLowerCase()
        ? '"${profile.label}" was signed in as @$previous before; it now uses @${account.login}.'
        : null;
    return (emailNote: emailNote, switched: switched, previous: previous);
  }

  /// `gita sign-in --no-wait`: prints the code and returns at once; the
  /// sign-in finishes in the background once the person enters the code.
  /// For `gita mcp`, which keeps running, so an AI tool can show the person
  /// the code without its tool call waiting minutes. The token never
  /// reaches the AI tool.
  Future<int> _signInInBackground(
    GitHubDeviceFlow flow,
    DeviceCode code,
    Profile profile, {
    required bool json,
    required bool openTheBrowser,
  }) async {
    final opened = openTheBrowser && await openBrowser(code.verificationUri);
    final message = 'Ask the person to open ${code.verificationUri}'
        '${opened ? ' (it was just opened in their browser)' : ''}, sign in as the '
        'GitHub account for "${profile.label}", enter the code ${code.userCode} and '
        'press Authorize. Gita finishes the sign-in by itself; check with '
        'gita_profiles (signedIn becomes true).';
    _backgroundSignIns[profile.id] = 'waiting';
    unawaited(() async {
      try {
        final token = await flow.waitForToken(code);
        final account = await flow.fetchAccount(token);
        await _saveSignIn(profile, token, account);
        _backgroundSignIns.remove(profile.id);
      } on DeviceFlowException catch (e) {
        _backgroundSignIns[profile.id] = e.message;
      } catch (e) {
        _backgroundSignIns[profile.id] = 'Sign-in failed: $e';
      }
    }());
    if (json) {
      out.writeln(_encode({
        'ok': true,
        'step': 'enter-code',
        'profile': profile.id,
        'code': code.userCode,
        'url': code.verificationUri.toString(),
        'browserOpened': opened,
        'message': message,
      }));
    } else {
      out
        ..writeln('Signing "${profile.label}" in to GitHub.')
        ..writeln('Open ${code.verificationUri}, sign in as its GitHub account, '
            'enter ${code.userCode} and press Authorize.');
    }
    return ExitCodes.ok;
  }

  static Profile? _findProfile(List<Profile> profiles, String wanted) {
    final w = wanted.trim().toLowerCase();
    return profiles.where((p) => p.id.toLowerCase() == w).firstOrNull ??
        profiles.where((p) => p.label.toLowerCase() == w).firstOrNull;
  }

  static GitHubDeviceFlow? _defaultDeviceFlow() {
    final clientId = resolveGitHubClientId();
    return clientId == null ? null : GitHubDeviceFlow(clientId: clientId);
  }

  /// Opens [url] in the default browser. Failing is fine: the printed
  /// steps say where to go.
  static Future<bool> defaultOpenBrowser(Uri url) async {
    try {
      final ProcessResult result;
      if (Platform.isWindows) {
        result = await Process.run('rundll32', ['url.dll,FileProtocolHandler', url.toString()]);
      } else if (Platform.isMacOS) {
        result = await Process.run('open', [url.toString()]);
      } else {
        result = await Process.run('xdg-open', [url.toString()]);
      }
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  // ---------------------------------------------------------------- which

  Future<int> _which(List<String> rest, {required bool json}) async {
    final status = await _repoStatus(rest, json: json);
    if (status == null) return ExitCodes.usage;
    if (json) {
      out.writeln(_encode(status.toJson()));
    } else {
      _printRepoSummary(status);
    }
    return ExitCodes.ok;
  }

  // ---------------------------------------------------------------- check

  Future<int> _check(List<String> rest, {required bool json}) async {
    final status = await _repoStatus(rest, json: json);
    if (status == null) return ExitCodes.usage;
    final blocking = status.report?.severity == Severity.blocking;

    if (json) {
      out.writeln(_encode(status.toJson()));
    } else {
      _printRepoSummary(status);
      out.writeln();
      final report = status.report;
      if (report == null) {
        out.writeln('All good: this project is using the right account.');
      } else {
        out
          ..writeln(blocking ? 'PROBLEM: ${report.detail}' : 'Heads up: ${report.detail}')
          ..writeln()
          ..writeln('What to do:');
        for (final step in _stepsFor(report.type)) {
          out.writeln('  - $step');
        }
      }
    }
    return blocking ? ExitCodes.problem : ExitCodes.ok;
  }

  List<String> _stepsFor(MismatchType type) => switch (type) {
        MismatchType.noRuleMatched => [
            'Open Gita and go to Rules.',
            'Add a rule for the folder this project is in, and pick the '
                'account it belongs to.',
          ],
        MismatchType.identityMismatch => [
            'Open Gita and go to the Dashboard to see which account this '
                'project should use.',
            'If the account shown there is right, this project has its own '
                'name/email setting that is overriding Gita. Ask your team '
                'lead or the Gita maintainer to remove it.',
          ],
        MismatchType.sshKeyMismatch => [
            'Open Gita and go to Doctor.',
            'Follow the steps shown for this project\'s SSH key.',
          ],
        MismatchType.hookMissing => [
            'Run "gita guard install" in this project, or open Gita and go '
                'to Doctor to add the safety check.',
          ],
      };

  void _printRepoSummary(_RepoStatus status) {
    final profile = status.expectedProfile;
    out
      ..writeln('Project:      ${status.repoPath}')
      ..writeln('Should use:   ${profile == null ? 'unknown (no Gita rule covers this folder)' : '${profile.label} <${profile.gitEmail}>'}')
      ..writeln('Commits as:   ${status.actualEmail ?? 'nobody (no email is set)'}');
  }

  // --------------------------------------------------------------- doctor

  Future<List<DoctorIssue>> _runDoctor() async => doctorService.run(
        profiles: await ProfileRepository(paths: paths).getAll(),
        rules: await RepoRuleRepository(paths: paths).getAll(),
        sshKeys: await SshKeyRepository(paths: paths).getAll(),
      );

  Future<int> _doctor({required bool json, bool fix = false}) async {
    var issues = await _runDoctor();
    final fixed = <String>[];
    if (fix && issues.isNotEmpty) {
      fixed.addAll(await _applyDoctorFixes(issues));
      if (fixed.isNotEmpty) issues = await _runDoctor();
    }
    final profiles = await ProfileRepository(paths: paths).getAll();
    final blocking = issues.any((i) => i.severity == Severity.blocking);

    if (json) {
      out.writeln(_encode({
        'ok': !blocking,
        'configured': profiles.isNotEmpty,
        if (fix) 'fixed': fixed,
        'issues': issues.map(_issueToJson).toList(),
      }));
      return blocking ? ExitCodes.problem : ExitCodes.ok;
    }
    for (final f in fixed) {
      out.writeln('Fixed: $f');
    }
    if (fixed.isNotEmpty) out.writeln();
    if (profiles.isEmpty) {
      out
        ..writeln('Gita isn\'t set up on this computer yet.')
        ..writeln()
        ..writeln('What to do:')
        ..writeln('  - Run "gita setup", or open the Gita app and add your accounts under Profiles.');
    } else if (issues.isEmpty) {
      out.writeln('All good: no setup problems found.');
    } else {
      out
        ..writeln('Found ${issues.length} '
            '${issues.length == 1 ? 'problem' : 'problems'}:')
        ..writeln();
      for (final issue in issues) {
        final tag = issue.severity == Severity.blocking ? 'PROBLEM' : 'Heads up';
        out.writeln('  - $tag: ${issue.message}');
      }
      out
        ..writeln()
        ..writeln(fix
            ? 'Open Gita and go to Doctor for help fixing the rest.'
            : 'Run "gita doctor --fix" to fix what can be fixed by itself, or '
                'open Gita and go to Doctor for help.');
    }
    return blocking ? ExitCodes.problem : ExitCodes.ok;
  }

  Map<String, Object?> _issueToJson(DoctorIssue issue) => {
        'category': issue.category.name,
        'severity': issue.severity.name,
        'message': issue.message,
        'profileId': issue.profileId,
        'ruleId': issue.ruleId,
        'sshKeyId': issue.sshKeyId,
        'githubOwner': ?issue.githubOwner,
        'host': ?issue.host,
      };

  // ---------------------------------------------------------------- guard

  Future<int> _path(List<String> rest, {required bool json}) async {
    const actions = ['status', 'add', 'remove'];
    if (rest.length > 1 || (rest.isNotEmpty && !actions.contains(rest.first))) {
      _fail('Usage: gita path [status|add|remove]', json: json);
      return ExitCodes.usage;
    }
    final action = rest.isEmpty ? 'status' : rest.first;
    final home = paths.homeDir();
    String tilde(List<String> files) => [
          for (final f in files) p.isWithin(home, f) ? '~/${p.relative(f, from: home)}' : f,
        ].join(', ');
    final before = pathSetup.status();
    if (action == 'status' || before.state == PathSetupState.unsupported ||
        before.state == PathSetupState.providedElsewhere) {
      final ok = before.state != PathSetupState.notAdded;
      if (json) {
        out.writeln(_encode({'ok': ok, ...before.toJson(), 'command': paths.cliPath}));
      } else {
        out.writeln(switch (before.state) {
          PathSetupState.added => 'New terminals find gita (set up in ${tilde(before.files)}).',
          PathSetupState.notAdded =>
            'New terminals don\'t find gita yet. Run "${paths.cliPath} path add" to fix that.',
          _ => before.note!,
        });
      }
      return action == 'status' && !ok ? ExitCodes.problem : ExitCodes.ok;
    }

    final result = action == 'add' ? await pathSetup.add() : await pathSetup.remove();
    if (json) {
      out.writeln(_encode({
        'ok': result.ok,
        'changed': result.changed,
        'files': result.files,
        if (result.error != null) 'error': result.error,
        'state': pathSetup.status().state.name,
      }));
    } else {
      if (action == 'add') {
        out.writeln(result.changed.isEmpty
            ? 'Already done: new terminals find gita.'
            : 'Done: added ~/.gita/bin to PATH in ${tilde(result.changed)}.\n'
                'Open a new terminal window to use "gita".');
      } else {
        out.writeln(result.changed.isEmpty
            ? 'Nothing to take out: Gita had not added itself to PATH.'
            : 'Done: took Gita out of ${tilde(result.changed)}. '
                "The app won't add it back.");
      }
      if (result.error != null) err.writeln(result.error);
    }
    return result.ok ? ExitCodes.ok : ExitCodes.problem;
  }

  Future<int> _guard(List<String> rest, {required bool json}) async {
    const actions = ['install', 'remove', 'status'];
    if (rest.isEmpty || !actions.contains(rest.first) || rest.length > 2) {
      _fail('Usage: gita guard <install|remove|status> [folder]', json: json);
      return ExitCodes.usage;
    }
    final action = rest.first;
    final folder = rest.length == 2 ? rest[1] : cwd;
    final hooks = HookService(paths: paths, git: gitService);
    final result = switch (action) {
      'install' => await hooks.install(folder),
      'remove' => await hooks.uninstall(folder),
      _ => await hooks.status(folder),
    };
    if (result.state == GuardState.notARepo) {
      _fail(
        "This folder isn't a git project: $folder\n"
        'Run this from inside a project folder, or pass the project folder.',
        json: json,
      );
      return ExitCodes.usage;
    }
    final ok = action == 'remove'
        ? result.state == GuardState.missing
        : result.state == GuardState.installed;
    if (json) {
      out.writeln(_encode({'ok': ok, 'state': result.state.name, 'message': result.message}));
      return ok ? ExitCodes.ok : ExitCodes.problem;
    }
    final line = switch ((action, result.state)) {
      ('install', GuardState.installed) =>
        'Done: commits and pushes in this project are now checked for the right account.',
      ('remove', GuardState.missing) => "Done: Gita's safety check is no longer in this project.",
      ('status', GuardState.installed) => "Gita's safety check is in place.",
      ('status', GuardState.outdated) =>
        'The safety check is from an older Gita. Run "gita guard install" to update it.',
      ('status', GuardState.missing) =>
        'This project has no safety check yet. Run "gita guard install" to add it.',
      _ => result.message ?? 'Something went wrong.',
    };
    out.writeln(line);
    if (result.message != null && line != result.message) out.writeln(result.message);
    return ok ? ExitCodes.ok : ExitCodes.problem;
  }

  // ----------------------------------------------------------------- hook

  /// Run by the hooks `gita guard install` adds. Exit 0 lets git go on,
  /// 1 stops the commit or push. Messages go to stderr, which git shows.
  Future<int> _hook(List<String> rest) async {
    if (rest.isEmpty || !HookService.hookNames.contains(rest.first)) {
      err.writeln('Usage: gita hook <pre-commit|pre-push>');
      return ExitCodes.usage;
    }
    final profiles = await ProfileRepository(paths: paths).getAll();
    final rules = await RepoRuleRepository(paths: paths).getAll();
    final guard = PushGuard(git: gitService);

    if (rest.first == 'pre-commit') {
      final verdict = await guard.checkCommit(cwd, profiles, rules);
      if (verdict.allowed) return ExitCodes.ok;
      final profile = verdict.profile!;
      err
        ..writeln()
        ..writeln('Gita stopped this commit: it would be made as '
            '${verdict.configuredEmail}, but this project belongs to '
            '"${profile.label}" (${profile.gitEmail}).')
        ..writeln()
        ..writeln('What to do:')
        ..writeln('  - Open Gita and go to Doctor. It can fix this project for you.')
        ..writeln('  - If this project really belongs to another account, change '
            'its rule in Gita under Rules.')
        ..writeln()
        ..writeln('To commit anyway, just this once: git commit --no-verify')
        ..writeln();
      return ExitCodes.problem;
    }

    final refs = await (input ?? stdin).transform(utf8.decoder).join();
    final verdict = await guard.checkPush(cwd, profiles, rules, refs);
    if (verdict.allowed) return ExitCodes.ok;
    final profile = verdict.profile!;
    final wrong = verdict.wrongCommits;
    final count = wrong.length == 1 ? '1 commit was' : '${wrong.length} commits were';
    err
      ..writeln()
      ..writeln('Gita stopped this push: $count made with another email, but this '
          'project belongs to "${profile.label}" (${profile.gitEmail}).')
      ..writeln();
    for (final c in wrong.take(10)) {
      err.writeln('  ${c.sha.substring(0, 7)}  ${c.email}  ${c.subject}');
    }
    if (wrong.length > 10) err.writeln('  ... and ${wrong.length - 10} more');
    final configuredRight = verdict.configuredEmail != null &&
        verdict.configuredEmail!.toLowerCase() == profile.gitEmail.toLowerCase();
    err
      ..writeln()
      ..writeln('What to do:');
    var step = 1;
    if (!configuredRight) {
      err.writeln('  ${step++}. Open Gita and go to Doctor, so new commits here '
          'use ${profile.gitEmail}.');
    }
    final amendIsEnough = wrong.length == 1 && _isTip(wrong.single, refs);
    final fix = amendIsEnough
        ? 'git commit --amend --no-edit --reset-author'
        : 'git rebase --rebase-merges ${verdict.rebaseBase ?? '--root'} '
            '--exec "git commit --amend --no-edit --reset-author"';
    err
      ..writeln('  ${step++}. Re-make the ${wrong.length == 1 ? 'commit' : 'commits'} '
          'with the right email by running:')
      ..writeln('       $fix')
      ..writeln('  ${step++}. Push again.')
      ..writeln()
      ..writeln('To push anyway, just this once: git push --no-verify')
      ..writeln();
    return ExitCodes.problem;
  }

  /// Whether [commit] is the tip of a ref being pushed, so amending it is
  /// enough to fix it.
  bool _isTip(WrongCommit commit, String refs) => refs
      .split('\n')
      .any((l) => l.trim().split(RegExp(r'\s+')).elementAtOrNull(1) == commit.sha);

  // ----------------------------------------------------------- credential

  /// Git credential helper (https://git-scm.com/docs/gitcredentials).
  ///
  /// Gita's include file for a profile points git here for its folders, so
  /// a push from a project authenticates with that project's account
  /// rather than whichever single login the machine remembers. stdout is
  /// read by git, so anything meant for the person goes to stderr, which
  /// git shows in their terminal.
  Future<int> _credential(String? profileId, List<String> rest) async {
    if (profileId == null || rest.length != 1) {
      err.writeln('Usage: gita credential --profile <id> <get|store|erase>');
      return ExitCodes.usage;
    }
    final request = await _readCredentialRequest();
    final profile = (await ProfileRepository(paths: paths).getAll())
        .where((p) => p.id == profileId)
        .firstOrNull;
    final name = profile == null ? 'this account' : '"${profile.label}"';

    switch (rest.single) {
      case 'get':
        final String? token;
        try {
          token = await tokenStore.readToken(profileId);
        } catch (e) {
          err
            ..writeln("Gita: couldn't open this computer's password store "
                'to sign in to GitHub.')
            ..writeln('Gita: $e');
          out.writeln('quit=1');
          return ExitCodes.ok;
        }
        if (token == null) {
          err
            ..writeln('Gita: there is no GitHub sign-in saved for $name, so '
                "this push can't sign in.")
            ..writeln('Gita: open the Gita app, go to Profiles, edit $name '
                'and press "Sign in with GitHub". Then push again.');
          // Stop git from trying other ways to sign in (such as a login
          // remembered for a different account) or prompting for a password.
          out.writeln('quit=1');
          return ExitCodes.ok;
        }
        // GitHub ignores the username when the password is a token; keep
        // the one git sent (from the remote URL) so git doesn't complain.
        out
          ..writeln('username=${request['username'] ?? 'x-access-token'}')
          ..writeln('password=$token');
        return ExitCodes.ok;
      case 'store':
        // Tokens are saved in the Gita app, not by git.
        return ExitCodes.ok;
      case 'erase':
        // Git says GitHub rejected the token. Leave it in place (deleting
        // would hide what happened) and tell the person how to fix it.
        err
          ..writeln('Gita: GitHub did not accept the sign-in saved for '
              '$name. It may have expired, or it may not have access to '
              'this project.')
          ..writeln('Gita: open the Gita app, go to Profiles, edit $name, '
              'paste a new access token and press Save. Then push again.');
        return ExitCodes.ok;
      default:
        err.writeln('Unknown credential action: ${rest.single}');
        return ExitCodes.usage;
    }
  }

  Future<Map<String, String>> _readCredentialRequest() async {
    final text = await (input ?? stdin).transform(utf8.decoder).join();
    final fields = <String, String>{};
    for (final line in const LineSplitter().convert(text)) {
      if (line.isEmpty) break;
      final eq = line.indexOf('=');
      if (eq > 0) fields[line.substring(0, eq)] = line.substring(eq + 1);
    }
    return fields;
  }

  // -------------------------------------------------------------- helpers

  /// Resolves the target folder to its repo root and evaluates it against
  /// the stored rules. Returns null (after printing why) when the folder
  /// isn't inside a git project.
  Future<_RepoStatus?> _repoStatus(List<String> rest, {required bool json}) async {
    if (rest.length > 1) {
      _fail('Give at most one folder.', json: json);
      return null;
    }
    final target = rest.isEmpty ? '.' : rest.single;
    final top = await gitService.topLevel(target);
    if (top == null) {
      _fail(
        'This folder isn\'t a git project: $target\n'
        'Run this from inside a project folder, or pass the project folder.',
        json: json,
      );
      return null;
    }
    final repoPath = resolveRepoPath(top);

    final profiles = await ProfileRepository(paths: paths).getAll();
    final rules = await RepoRuleRepository(paths: paths).getAll();
    final sshKeys = await SshKeyRepository(paths: paths).getAll();
    final profilesById = {for (final p in profiles) p.id: p};

    final detector = MismatchDetector(
      gitService: gitService,
      sshConfigService: SshConfigService(paths: paths),
      hookService: HookService(paths: paths, git: gitService),
    );
    final report = await detector.check(
      repoPath: repoPath,
      rules: rules,
      profilesById: profilesById,
      sshKeysById: {for (final k in sshKeys) k.id: k},
    );

    // Same lookup MismatchDetector uses, so `which` can show the expected
    // profile even when the repo is consistent (report == null).
    final rule = await gitService.ruleFor(repoPath, rules);
    return _RepoStatus(
      repoPath: repoPath,
      expectedProfile: rule == null ? null : profilesById[rule.profileId],
      actualEmail: await gitService.getConfigValue(repoPath, 'user.email'),
      report: report,
    );
  }

  void _fail(String message, {required bool json}) {
    if (json) {
      out.writeln(_encode({'ok': false, 'error': message}));
    } else {
      err.writeln(message);
    }
  }

  String _encode(Object value) =>
      const JsonEncoder.withIndent('  ').convert(value);
}

class _RepoStatus {
  _RepoStatus({
    required this.repoPath,
    required this.expectedProfile,
    required this.actualEmail,
    required this.report,
  });

  final String repoPath;
  final Profile? expectedProfile;
  final String? actualEmail;
  final MismatchReport? report;

  Map<String, Object?> toJson() => {
        'ok': report?.severity != Severity.blocking,
        'repo': repoPath,
        'expectedProfile': expectedProfile == null
            ? null
            : {
                'id': expectedProfile!.id,
                'label': expectedProfile!.label,
                'email': expectedProfile!.gitEmail,
              },
        'actualEmail': actualEmail,
        'issue': report == null
            ? null
            : {
                'type': report!.type.name,
                'severity': report!.severity.name,
                'detail': report!.detail,
              },
      };
}
