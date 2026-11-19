part of 'gita_cli.dart';

/// Thrown by a step that can't go on; the run stops and prints the summary.
class _Stop implements Exception {
  _Stop(this.message, [this.hints = const []]);
  final String message;
  final List<String> hints;
}

/// [Reporter] that prints the plain text people see during `gita onboard`.
class _TextReporter implements Reporter {
  _TextReporter(this.sink);
  final StringSink sink;
  @override
  void say(String text) => sink.writeln('==> $text');
  @override
  void note(String text) => sink.writeln('    $text');
  @override
  void warn(String text) => sink.writeln('    ! $text');
}

/// One row of the end summary.
class _Row {
  _Row(this.step, this.result, {this.attention = false});
  final String step;
  final String result;
  final bool attention;
}

/// Options for one `gita onboard` run.
class OnboardOptions {
  const OnboardOptions({
    this.dryRun = false,
    this.yes = false,
    this.clean = false,
    this.name,
    this.emails = const {},
    this.skipSignIn = false,
    this.skipRepos = false,
  });

  /// Show what would change; change nothing.
  final bool dryRun;

  /// Answer every question with yes (cleanup, running repo scripts).
  final bool yes;

  /// Remove old GitHub sign-ins without asking.
  final bool clean;

  /// Name to commit with; asked (default: git's user.name) when missing.
  final String? name;

  /// Email per account id; asked when missing.
  final Map<String, String> emails;

  /// Skip GitHub sign-in (testing / CI).
  final bool skipSignIn;

  /// Skip repo, companyFile and repoScript steps (testing / CI).
  final bool skipRepos;
}

/// `gita onboard <file>`: sets a developer's machine up from an onboarding file.
extension _OnboardCommand on GitaCli {
  Future<int> _onboardCommand(ArgResults command) async {
    if (command.rest.length != 1) {
      err.writeln(
        'Usage: gita onboard <onboarding file> [--dry-run] [--yes] [--clean] '
        '[--name <name>] [--email <account>=<email>]... [--skip-sign-in] [--skip-repos]',
      );
      return ExitCodes.usage;
    }
    final emails = <String, String>{};
    for (final e in command['email'] as List<String>) {
      final i = e.indexOf('=');
      if (i <= 0) {
        err.writeln('--email takes <account id>=<email>, for example --email work=jane@example.com');
        return ExitCodes.usage;
      }
      emails[e.substring(0, i).trim()] = e.substring(i + 1).trim();
    }
    final file = File(p.absolute(cwd, command.rest.single));
    final OnboardingFile onboarding;
    try {
      if (!file.existsSync()) throw FormatException('There is no onboarding file at ${file.path}.');
      if (file.lengthSync() > OnboardingFile.maxBytes) {
        throw const FormatException('The onboarding file is larger than 64 KB.');
      }
      onboarding = OnboardingFile.parse(await file.readAsString());
    } on FormatException catch (e) {
      err.writeln('Setup stopped: ${e.message}');
      return ExitCodes.usage;
    } on FileSystemException catch (e) {
      err.writeln("Setup stopped: couldn't read ${file.path}: ${e.message}");
      return ExitCodes.usage;
    }
    for (final id in emails.keys) {
      if (!onboarding.accounts.any((a) => a.id == id)) {
        err.writeln(
          '--email $id=...: "$id" is not an account in the onboarding file '
          '(accounts: ${onboarding.accounts.map((a) => a.id).join(', ')}).',
        );
        return ExitCodes.usage;
      }
    }
    return onboard(
      onboarding,
      OnboardOptions(
        dryRun: command['dry-run'] as bool,
        yes: command['yes'] as bool,
        clean: command['clean'] as bool,
        name: command['name'] as String?,
        emails: emails,
        skipSignIn: command['skip-sign-in'] as bool,
        skipRepos: command['skip-repos'] as bool,
      ),
    );
  }

  /// A second CLI with the same machine access, for running Gita's own
  /// commands (profile add, sign-in, clone, company import, doctor) as steps.
  GitaCli _child({StringSink? out, StringSink? err}) => GitaCli(
    out: out ?? this.out,
    err: err ?? this.err,
    paths: paths,
    gitService: gitService,
    doctorService: doctorService,
    tokenStore: tokenStore,
    input: input,
    cwd: cwd,
    deviceFlow: deviceFlow,
    openBrowser: openBrowser,
    runProcess: runProcess,
    signInChecker: signInChecker,
    runInteractive: runInteractive,
    environment: environment,
    pathSetup: pathSetup,
    commandRunner: commandRunner,
    prompter: prompter,
    hostOs: hostOs,
  );

  /// Runs every step of [onboarding]. Returns 0, or 1 when a step stopped the run.
  Future<int> onboard(OnboardingFile onboarding, OnboardOptions options) async {
    final r = _TextReporter(out);
    final ask = prompter ?? TerminalPrompter(out: out);
    final rows = <_Row>[];
    var current = '';
    void row(String result, {bool attention = false}) => rows.add(_Row(current, result, attention: attention));
    void step(String name) => current = name;
    final dry = options.dryRun;
    String home(String dir) => p.joinAll([paths.homeDir(), ...dir.split('/').skip(1)]);
    final os = hostOs ?? _currentOs();
    final tools = ToolInstaller(
      runner: commandRunner,
      reporter: r,
      prompter: ask,
      os: os,
      homeDir: paths.homeDir(),
      dryRun: dry,
    );
    var ghLoggedOut = false;
    _Stop? stopped;

    r.say('Setting up this computer for ${onboarding.name}${dry ? ' (dry run: nothing will be changed)' : ''}');
    try {
      // ---- Tools ----
      r.say('Checking tools');
      final needs = {
        ...onboarding.tools,
        // Gita keeps sign-ins with secret-tool on Linux.
        if (os == HostOs.linux) 'secret-tool': ToolNeed.required,
      };
      for (final tool in ['git', 'gh', 'claude', 'secret-tool']) {
        final need = needs[tool] ?? ToolNeed.skip;
        if (need == ToolNeed.skip) continue;
        step(switch (tool) {
          'git' => 'Git',
          'gh' => 'GitHub CLI',
          'claude' => 'Claude Code',
          _ => 'secret-tool',
        });
        final outcome = await tools.ensure(tool, need);
        if (outcome.failed) throw _Stop('$current could not be set up.', [?outcome.hint]);
        row(outcome.summary, attention: outcome.hint != null);
        if (outcome.hint != null && !outcome.failed) r.note(outcome.hint!);
      }

      // ---- Old GitHub sign-ins ----
      if (onboarding.cleanup != CleanupMode.skip) {
        step('Clean-up of old GitHub sign-ins');
        final cleanup = GitHubCleanup(
          runner: commandRunner,
          reporter: r,
          prompter: ask,
          isWindows: os == HostOs.windows,
          homeDir: paths.homeDir(),
          gitExecutable: tools.commandFor('git'),
          ghExecutable: tools.commandFor('gh'),
        );
        final mode = options.clean || options.yes ? CleanupMode.yes : onboarding.cleanup;
        final outcome = await cleanup.run(mode, dryRun: dry);
        ghLoggedOut = outcome.ghLoggedOut;
        row(outcome.summary, attention: outcome.failed);
      }

      // ---- Old backups from earlier runs (.gitconfig ones may hold old tokens) ----
      step('Old setup backups');
      final backups = await OldBackups(reporter: r, prompter: ask).run(
        [paths.gitConfigPath, for (final s in onboarding.steps.whereType<RepoStep>()) home(s.dir)],
        dryRun: dry,
        yes: options.yes,
      );
      if (backups != 'none') row(backups, attention: backups.startsWith('kept') || backups.contains('failed'));

      // ---- Accounts ----
      r.say('Your GitHub accounts');
      step('Gita profiles');
      final defaultName = (await commandRunner.run(tools.commandFor('git'), [
        'config',
        '--global',
        'user.name',
      ])).stdout.trim();
      var name = options.name?.trim() ?? '';
      if (name.isEmpty) name = (await ask.ask('Your full name (shown on commits)', defaultValue: defaultName)).trim();
      if (name.isEmpty) throw _Stop('A name is needed.', ['Pass it with --name "Your Name".']);
      final profileIds = <String, String>{};
      final emails = <String, String>{};
      for (final account in onboarding.accounts) {
        var email = options.emails[account.id]?.trim() ?? '';
        if (email.isNotEmpty && !account.acceptsEmail(email)) {
          throw _Stop('$email is not an @${account.emailDomain} address.');
        }
        while (email.isEmpty) {
          if (!ask.interactive) {
            throw _Stop('No terminal to ask for your @${account.emailDomain} email.', [
              'Pass it with --email ${account.id}=<email>.',
            ]);
          }
          final answer = (await ask.ask(account.emailQuestion)).trim();
          if (account.acceptsEmail(answer)) {
            email = answer;
          } else {
            r.warn('That is not an @${account.emailDomain} address. Try again.');
          }
        }
        emails[account.id] = email;
        profileIds[account.id] = await _ensureProfile(r, name, email, account.label, dry: dry);
      }
      await _showProfiles(r, profileIds.values.toSet());
      row(dry ? 'ready (dry run)' : 'ready');

      // ---- Steps ----
      final knownLogins = <String, String?>{};
      String? lastCloneProblem;
      Future<Profile?> profileOf(String accountId) async =>
          (await ProfileRepository(paths: paths).getAll()).where((x) => x.id == profileIds[accountId]).firstOrNull;

      for (final s in onboarding.steps) {
        switch (s) {
          case SignInStep(:final account):
            final a = onboarding.account(account);
            step('Sign-in ${emails[account]}');
            if (options.skipSignIn) {
              r.warn('Skipping GitHub sign-in for ${emails[account]}.');
              row('skipped (--skip-sign-in)');
              continue;
            }
            final others = {
              for (final o in onboarding.accounts)
                if (o.id != account) o.id: (await profileOf(o.id))?.githubLogin,
            };
            final login = await _ensureSignIn(
              r,
              ask,
              profileIds[account]!,
              a.label,
              emails[account]!,
              others.values.whereType<String>().map((x) => x.toLowerCase()).toSet(),
              dry: dry,
              yes: options.yes,
            );
            knownLogins[account] = login;
            row(dry ? 'dry run' : 'signed in as @$login');
          case RepoStep():
            step(s.name);
            if (options.skipRepos) {
              r.warn('Skipping ${s.name}.');
              row('skipped (--skip-repos)');
              continue;
            }
            final a = onboarding.account(s.account);
            final profile = await profileOf(s.account);
            final dir = home(s.dir);
            // Files later steps take from this copy: one missing means an old or
            // incomplete copy, which the repo step replaces (so a rerun repairs it).
            bool inside(String? rel) => rel != null && _insideFolder(p.joinAll([dir, ...rel.split('/')]), dir);
            final needs = <String>[
              for (final o in onboarding.steps)
                if (o is CompanyFileStep && home(o.repoDir) == dir && inside(o.path))
                  o.path
                else if (o is RepoScriptStep && home(o.repoDir) == dir)
                  if (os == HostOs.windows ? o.windows : o.unix case final rel? when inside(rel)) rel,
            ];
            r.say(s.name);
            final outcome =
                await RepoEnsurer(
                  runner: commandRunner,
                  reporter: r,
                  dryRun: dry,
                  gitExecutable: tools.commandFor('git'),
                ).ensure(
                  url: s.url,
                  dir: dir,
                  name: s.name,
                  profileLabel: a.label,
                  profileLogin: profile?.githubLogin,
                  accountEmail: emails[s.account]!,
                  orgName: s.url.split('/')[3],
                  clone: () async {
                    // --json: Gita's clone says what went wrong (signIn, helper,
                    // sshKey), so the repo step can explain the right fix.
                    final buffer = StringBuffer();
                    final code = await _child(
                      out: buffer,
                      err: buffer,
                    ).run(['clone', s.url, dir, '--profile', profileIds[s.account]!, '--json']);
                    lastCloneProblem = null;
                    try {
                      final result =
                          jsonDecode(LineSplitter.split(buffer.toString().trim()).last) as Map<String, Object?>;
                      final message = result['message'] as String?;
                      if (message != null) code == ExitCodes.ok ? r.note(message) : r.warn(message);
                      final gitSaid = result['gitSaid'] as String?;
                      if (gitSaid != null && code != ExitCodes.ok) r.note('git said: $gitSaid');
                      lastCloneProblem = result['problem'] as String?;
                    } on FormatException {
                      r.note(buffer.toString().trim());
                    } on TypeError {
                      r.note(buffer.toString().trim());
                    }
                    return code == ExitCodes.ok;
                  },
                  cloneProblem: () => lastCloneProblem,
                  needs: needs,
                  offerRetry: options.skipSignIn || !ask.interactive
                      ? null
                      : () async {
                          if (!await ask.confirm('Sign "${a.label}" in to GitHub again and retry?', defaultYes: true)) {
                            return false;
                          }
                          await _signInOnce(r, profileIds[s.account]!, a.label);
                          return true;
                        },
                );
            if (outcome.failed) throw _Stop('${s.name} couldn\'t be set up.', [?outcome.hint]);
            row(outcome.summary, attention: outcome.summary.contains('failed'));
          case CompanyFileStep():
            step('Company file ${s.path}');
            if (options.skipRepos) {
              row('skipped (--skip-repos)');
              continue;
            }
            final path = p.joinAll([home(s.repoDir), ...s.path.split('/')]);
            if (dry) {
              r.note('[dry run] would import $path');
              row('dry run');
              continue;
            }
            if (!_insideFolder(path, home(s.repoDir))) {
              throw _Stop('${s.path} is outside ${s.repoDir}.', ['Tell whoever wrote the onboarding file.']);
            }
            if (!File(path).existsSync()) {
              throw _Stop('${s.repoDir} has no ${s.path}.', [
                'It may be an old copy. Run "git -C ${home(s.repoDir)} pull", then run this again.',
              ]);
            }
            final buffer = StringBuffer();
            final code = await _child(
              out: buffer,
              err: buffer,
            ).run(['company', 'import', path, '--profile', profileIds[s.account]!]);
            r.note(buffer.toString().trim());
            if (code != ExitCodes.ok) {
              throw _Stop("Gita couldn't import ${s.path} (the message above says why).", [
                'Run this again; if it repeats, send the output to whoever looks after your setup.',
              ]);
            }
            row('imported');
          case RepoScriptStep():
            step(s.title);
            if (options.skipRepos) {
              row('skipped (--skip-repos)');
              continue;
            }
            final rel = os == HostOs.windows ? s.windows : s.unix;
            if (rel == null) {
              row('not needed on this system');
              continue;
            }
            final repo = home(s.repoDir);
            final script = p.joinAll([repo, ...rel.split('/')]);
            r.say('Running $rel from ${s.repoDir}');
            if (dry) {
              r.note('[dry run] would run $script');
              row('dry run');
              continue;
            }
            if (!_insideFolder(script, repo) || !File(script).existsSync()) {
              throw _Stop('${s.repoDir} has no $rel.', [
                'It may be an old or incomplete copy. Move the folder away and run this again.',
              ]);
            }
            r.note('This runs $script, which comes from the repository you just downloaded.');
            if (!options.yes && !await ask.confirm('Run it now?', defaultYes: true)) {
              r.warn('Not run. Run it yourself later: $script');
              row('not run (you said no)', attention: true);
              continue;
            }
            // No terminal input: the scripts ask nothing, and some tools they
            // start crash when their input is a terminal they can't use.
            final result = await commandRunner.run(
              os == HostOs.windows ? 'powershell' : 'bash',
              [
                if (os == HostOs.windows) ...['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File'],
                script,
              ],
              io: CommandIo.show,
              environment: os == HostOs.windows ? windowsPowerShellEnvironment : const {},
              workingDirectory: repo,
              timeout: const Duration(minutes: 15),
            );
            if (!result.ok) {
              throw _Stop('The setup script failed (its messages are above).', [
                'Fix what it says, then run this again. Finished steps are skipped.',
              ]);
            }
            row('done');
          case ClaudeCodeStep():
            step('Gita in Claude Code');
            if (dry) {
              r.note('[dry run] would connect Gita to Claude Code');
              row('dry run');
              continue;
            }
            final buffer = StringBuffer();
            final code = await _child(out: buffer, err: buffer).run(['mcp', 'add-to-claude']);
            if (code == ExitCodes.ok) {
              row('connected');
            } else {
              r.warn("Couldn't connect Gita to Claude Code. Open a new terminal and run \"gita mcp add-to-claude\".");
              row("couldn't connect (run gita mcp add-to-claude)", attention: true);
            }
          case DoctorStep():
            step('Gita doctor');
            r.say('Checking the setup');
            if (dry) {
              r.note('[dry run] would run gita doctor');
              row('dry run');
              continue;
            }
            final buffer = StringBuffer();
            final code = await _child(out: buffer, err: buffer).run(['doctor']);
            out.write(buffer);
            if (code == ExitCodes.ok) {
              row(buffer.toString().contains('Heads up') ? 'ok, with notes (above)' : 'all good');
            } else if (code == ExitCodes.problem) {
              row('problems found (run gita doctor --fix)', attention: true);
            } else {
              row("couldn't run (exit $code)", attention: true);
            }
        }
      }
    } on _Stop catch (e) {
      stopped = e;
      rows.add(_Row(current, 'failed', attention: true));
      out
        ..writeln()
        ..writeln('Setup stopped: ${e.message}');
      for (final h in e.hints) {
        out.writeln('    $h');
      }
    }

    out
      ..writeln()
      ..writeln('==> Summary');
    final width = rows.fold<int>(0, (w, x) => x.step.length > w ? x.step.length : w) + 2;
    for (final x in rows) {
      out.writeln('    ${x.step.padRight(width)}${x.result}');
    }
    out.writeln();
    if (stopped != null) {
      out.writeln('    Fix the problem above and run the same command again. Finished steps are skipped.');
      return ExitCodes.problem;
    }
    if (dry) {
      out.writeln('==> Dry run finished. Nothing was changed.');
    } else if (rows.any((x) => x.attention)) {
      out.writeln('==> Finished, but some steps need attention (marked above).');
    } else {
      out.writeln('==> Done.');
    }
    out
      ..writeln('    Next:')
      ..writeln('      1. Open a new terminal (so PATH changes apply).')
      ..writeln('      2. Clone projects with "gita clone <address>", so each uses the right account.')
      ..writeln('      3. Use "gita gh <command>" for the GitHub CLI, so it uses the right account too.');
    if (ghLoggedOut) {
      out.writeln(
        '      4. GitHub CLI was signed out. "gita gh" signs it in per project; '
        'for plain "gh", run "gh auth login" with the right account.',
      );
    }
    return ExitCodes.ok;
  }

  /// Finds the profile for [email] or adds it. Returns its id.
  Future<String> _ensureProfile(Reporter r, String name, String email, String label, {required bool dry}) async {
    final profiles = await ProfileRepository(paths: paths).getAll();
    final found = profiles.where((x) => x.gitEmail.toLowerCase() == email.toLowerCase()).toList();
    if (found.isNotEmpty) {
      r.note('Profile for $email already exists ("${found.first.label}").');
      return found.first.id;
    }
    if (dry) {
      r.note('[dry run] would add the Gita profile "$label" for $email');
      return label;
    }
    var useLabel = label;
    if (profiles.any((x) => x.label.toLowerCase() == label.toLowerCase())) {
      useLabel = '$label ($email)';
      r.warn('There is already a profile called "$label" with another email, so this one is "$useLabel".');
    }
    final buffer = StringBuffer();
    final code = await _child(
      out: buffer,
      err: buffer,
    ).run(['profile', 'add', '--name', name, '--email', email, '--label', useLabel, '--json']);
    if (code != ExitCodes.ok) {
      throw _Stop("Couldn't add the Gita profile for $email.", [buffer.toString().trim()]);
    }
    final id =
        ((jsonDecode(buffer.toString()) as Map<String, Object?>)['profile'] as Map<String, Object?>)['id'] as String;
    r.note('Added the profile "$useLabel" for $email.');
    return id;
  }

  Future<void> _showProfiles(Reporter r, Set<String> ids) async {
    for (final x in await ProfileRepository(paths: paths).getAll()) {
      if (!ids.contains(x.id)) continue;
      final signedIn = await tokenStore.hasToken(x.id);
      r.note(
        '${x.label}: ${x.gitEmail}, '
        '${signedIn ? 'signed in${x.githubLogin == null ? '' : ' as @${x.githubLogin}'}' : 'not signed in yet'}',
      );
    }
  }

  /// Makes sure profile [id] is signed in as the person's own account for
  /// [email], and not as an account another profile already uses
  /// ([otherLogins], lower-case). Returns the GitHub login.
  Future<String?> _ensureSignIn(
    Reporter r,
    Prompter ask,
    String id,
    String label,
    String email,
    Set<String> otherLogins, {
    required bool dry,
    required bool yes,
  }) async {
    Future<Profile?> load() async =>
        (await ProfileRepository(paths: paths).getAll()).where((x) => x.id == id).firstOrNull;
    final profile = await load();
    final login = profile?.githubLogin;
    var signedIn = !dry && profile != null && await tokenStore.hasToken(id);
    // A saved sign-in GitHub has cancelled is no sign-in: say so, then
    // sign in again below instead of failing later at the first clone.
    if (signedIn && await _signInHealth(id) == SignInHealth.rejected) {
      r.warn('"$label"\'s GitHub sign-in has stopped working (GitHub cancelled it). Signing it in again.');
      signedIn = false;
    }
    if (signedIn && login != null) {
      if (otherLogins.contains(login.toLowerCase())) {
        r.warn('"$label" is signed in as @$login, which another account also uses. Sign it in as your $email account.');
      } else if (yes ||
          !ask.interactive ||
          await ask.confirm(
            '"$label" is signed in as @$login. Is that your $email GitHub account?',
            defaultYes: true,
          )) {
        r.note('"$label" is signed in as @$login.');
        return login;
      }
    }
    if (dry) {
      r.note('[dry run] would sign "$label" in to GitHub');
      return login;
    }
    r.say('Signing "$label" in to GitHub as your $email account');
    r.note(
      'If your browser is signed in to github.com as another account, sign out there first '
      '(or use a private window).',
    );
    for (var attempt = 1; attempt <= 2; attempt++) {
      await _signInOnce(r, id, label);
      final now = (await load())?.githubLogin;
      if (now == null) continue;
      if (otherLogins.contains(now.toLowerCase())) {
        r.warn('That is @$now, which another account already uses. Sign in as your $email account instead.');
        continue;
      }
      if (yes ||
          !ask.interactive ||
          await ask.confirm('Signed in as @$now. Is that your $email account?', defaultYes: true)) {
        return now;
      }
    }
    throw _Stop('"$label" is not signed in as your $email GitHub account.', [
      'Sign out of github.com in your browser, then run: gita sign-in --profile "$label"',
    ]);
  }

  /// What GitHub says about profile [id]'s saved sign-in; unknown when
  /// there's no checker, no sign-in, or GitHub can't be asked.
  Future<SignInHealth> _signInHealth(String id) async {
    final checker = signInChecker;
    if (checker == null) return SignInHealth.unknown;
    try {
      final token = await tokenStore.readToken(id);
      if (token == null || token.isEmpty) return SignInHealth.unknown;
      return (await checker.check(token)).health;
    } catch (_) {
      return SignInHealth.unknown;
    }
  }

  // Onboard has already decided a new sign-in is needed (none, cancelled,
  // wrong account, or a retry the person asked for), so --force: the plain
  // command would skip a sign-in that still works.
  Future<void> _signInOnce(Reporter r, String id, String label) async {
    final code = await _child().run(['sign-in', '--profile', id, '--force']);
    if (code != ExitCodes.ok) r.warn('Signing "$label" in did not finish.');
  }

  static bool _insideFolder(String path, String folder) {
    final full = p.normalize(p.absolute(path));
    final root = p.normalize(p.absolute(folder));
    return p.isWithin(root, full);
  }

  static HostOs _currentOs() => Platform.isWindows
      ? HostOs.windows
      : Platform.isMacOS
      ? HostOs.macos
      : HostOs.linux;
}
