part of 'gita_cli.dart';

/// Starts a program with the terminal's stdin, stdout and stderr, waits for
/// it and returns its exit code.
typedef InteractiveRunner = Future<int> Function(
  String executable,
  List<String> arguments, {
  required Map<String, String> environment,
  required String workingDirectory,
});

/// `gita gh`: runs the GitHub CLI as the profile that owns the project.
///
/// `gh` has one global login, so in a project that belongs to another of
/// the person's GitHub accounts it would act as the wrong one. Git pushes
/// already avoid that through `gita credential`; this does the same for
/// `gh` by giving it `GH_TOKEN` from the profile's saved sign-in. The token
/// is only put in `gh`'s own environment: never printed or saved.
extension _GhCommand on GitaCli {
  static const _installHint =
      'Install it from https://cli.github.com (for example: brew install gh, '
      'winget install --id GitHub.cli, or your Linux package manager), then '
      'run this again. You don\'t need to sign in to gh: Gita gives it the '
      'sign-in.';

  Future<int> _gh(List<String> arguments) async {
    // Only a leading --profile belongs to Gita; everything else, including
    // gh's own --json and --help, goes to gh untouched.
    String? wanted;
    var i = 0;
    while (i < arguments.length) {
      final a = arguments[i];
      if (a == '--profile') {
        if (i + 1 >= arguments.length || arguments[i + 1].trim().isEmpty) {
          err.writeln('Say which profile after --profile: gita gh --profile <name or id> <gh command>');
          return ExitCodes.usage;
        }
        wanted = arguments[i + 1];
        i += 2;
      } else if (a.startsWith('--profile=')) {
        wanted = a.substring('--profile='.length);
        if (wanted.trim().isEmpty) {
          err.writeln('Say which profile after --profile: gita gh --profile <name or id> <gh command>');
          return ExitCodes.usage;
        }
        i += 1;
      } else if (a == '--') {
        i += 1;
        break;
      } else {
        break;
      }
    }
    final ghArgs = arguments.sublist(i);

    final refusal = _ghPrintsToken(ghArgs);
    if (refusal != null) {
      err.writeln(refusal);
      return ExitCodes.usage;
    }

    final profiles = await ProfileRepository(paths: paths).getAll();
    if (profiles.isEmpty) {
      err.writeln('There are no profiles yet. Open Gita and add one (or press "Scan this computer").');
      return ExitCodes.usage;
    }
    final example = 'gita gh --profile ${GitaCli._quoteArg(profiles.first.label)} '
        '${ghArgs.isEmpty ? 'pr list' : ghArgs.map(GitaCli._quoteArg).join(' ')}';

    Profile? profile;
    if (wanted != null) {
      profile = GitaCli._findProfile(profiles, wanted);
      if (profile == null) {
        final names = profiles.map((x) => '"${x.label}" (${x.id})').join(', ');
        err.writeln('There is no profile called "$wanted". Profiles: $names');
        return ExitCodes.usage;
      }
    } else {
      final top = await gitService.topLevel(cwd);
      if (top == null) {
        err.writeln(
          "This folder isn't a git project, so Gita can't tell which GitHub "
          'account gh should use. Run it from inside a project, or say which '
          'with --profile, for example: $example',
        );
        return ExitCodes.usage;
      }
      final rules = await RepoRuleRepository(paths: paths).getAll();
      final rule = await gitService.ruleFor(resolveRepoPath(top), rules);
      profile = profiles.where((x) => x.id == rule?.profileId).firstOrNull;
      if (profile == null) {
        final names = profiles.map((x) => x.label).join(', ');
        err.writeln(
          "Gita can't tell which account this project belongs to: no folder "
          'or GitHub account rule covers it. Say which with --profile, for '
          'example: $example  (profiles: $names). To make it stick, add a '
          'rule: gita rule add --profile <name> --folder <folder>',
        );
        return ExitCodes.usage;
      }
    }

    final String? token;
    try {
      token = await tokenStore.readToken(profile.id);
    } catch (_) {
      err.writeln("Couldn't open this computer's password store to read the "
          'GitHub sign-in for "${profile.label}". Run gita doctor to see why.');
      return ExitCodes.problem;
    }
    if (token == null || token.isEmpty) {
      err.writeln(
        'There is no GitHub sign-in saved for "${profile.label}", so gh can\'t '
        'act as its account. Sign it in first: '
        'gita sign-in --profile ${GitaCli._quoteArg(profile.label)}',
      );
      return ExitCodes.problem;
    }

    final executable = findExecutable('gh', environment);
    if (executable == null) {
      err.writeln("The GitHub CLI (gh) isn't installed, or isn't on PATH. $_installHint");
      return ExitCodes.problem;
    }

    // GH_TOKEN wins over gh's own login. GITHUB_TOKEN is dropped so a token
    // for another account can't leak in through gh extensions that read it.
    final env = <String, String>{
      for (final e in environment.entries)
        if (!_isTokenVariable(e.key)) e.key: e.value,
      'GH_TOKEN': token,
    };
    try {
      final code = await runInteractive(executable, ghArgs, environment: env, workingDirectory: cwd);
      // gh only says "Bad credentials"; say why, and the one step that fixes it.
      if (code != 0 && signInChecker != null && (await signInChecker!.check(token)).health == SignInHealth.rejected) {
        err.writeln(
          'Gita: "${profile.label}"\'s GitHub sign-in has stopped working: GitHub '
          'no longer accepts it (it may have been cancelled on GitHub). Sign it in '
          'again once: gita sign-in --profile ${GitaCli._quoteArg(profile.label)}',
        );
      }
      return code;
    } on ProcessException catch (e) {
      err.writeln("Couldn't start gh ($executable): ${e.message}. $_installHint");
      return ExitCodes.problem;
    }
  }

  static bool _isTokenVariable(String name) {
    final n = name.toUpperCase();
    return n == 'GH_TOKEN' || n == 'GITHUB_TOKEN';
  }

  /// gh commands that would print the token Gita hands it. Gita never shows
  /// the token (AI agents run this command too), so these are refused.
  static String? _ghPrintsToken(List<String> args) {
    if (args.length < 2 || args[0] != 'auth') return null;
    final sub = args[1];
    final showsToken = sub == 'token' ||
        (sub == 'status' && args.skip(2).any((a) => a == '-t' || a.startsWith('--show-token')));
    if (!showsToken) return null;
    return "Gita doesn't show GitHub sign-ins, so it won't run "
        '"gh ${args.take(2).join(' ')}${sub == 'status' ? ' --show-token' : ''}". '
        'To see which account gh uses here, run: gita gh auth status';
  }
}

/// Finds [name] on the PATH in [environment], the way a shell would.
/// Returns the full path, or null when it isn't installed.
String? findExecutable(String name, Map<String, String> environment) {
  final path = environment['PATH'] ?? environment['Path'] ?? environment['path'] ?? '';
  final windows = Platform.isWindows;
  for (final dir in path.split(windows ? ';' : ':')) {
    if (dir.trim().isEmpty) continue;
    final candidate = p.join(dir, windows ? '$name.exe' : name);
    final stat = FileStat.statSync(candidate);
    if (stat.type != FileSystemEntityType.file) continue;
    // Owner, group or other execute bit.
    if (!windows && stat.mode & 0x49 == 0) continue;
    return candidate;
  }
  return null;
}

Future<int> _defaultRunInteractive(
  String executable,
  List<String> arguments, {
  required Map<String, String> environment,
  required String workingDirectory,
}) async {
  // No shell, so gh's arguments are never interpreted by one (cmd.exe on
  // Windows would run anything after an "&").
  final process = await Process.start(
    executable,
    arguments,
    environment: environment,
    includeParentEnvironment: false,
    workingDirectory: workingDirectory,
    mode: ProcessStartMode.inheritStdio,
  );
  return process.exitCode;
}
