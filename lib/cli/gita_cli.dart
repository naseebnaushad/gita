import 'dart:convert';

import 'package:args/args.dart';

import '../core/models/doctor_issue.dart';
import '../core/models/mismatch_report.dart';
import '../core/models/profile.dart';
import '../core/models/repo_rule.dart';
import '../core/services/git_service.dart';
import '../core/services/identity_doctor_service.dart';
import '../core/services/mismatch_detector.dart';
import '../core/services/path_resolver.dart';
import '../core/services/platform_paths.dart';
import '../core/services/ssh_config_service.dart';
import '../core/storage/repositories.dart';

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
  }) : doctorService = doctorService ?? const IdentityDoctorService();

  final StringSink out;
  final StringSink err;
  final PlatformPaths paths;
  final GitService gitService;
  final IdentityDoctorService doctorService;

  static const version = '0.1.0';

  ArgParser _buildParser() {
    ArgParser command() => ArgParser()
      ..addFlag('json', negatable: false)
      ..addFlag('help', abbr: 'h', negatable: false);
    return ArgParser()
      ..addFlag('help', abbr: 'h', negatable: false)
      ..addFlag('version', negatable: false)
      ..addCommand('which', command())
      ..addCommand('check', command())
      ..addCommand('doctor', command());
  }

  Future<int> run(List<String> arguments) async {
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
        results['help'] as bool || (command?['help'] as bool? ?? false);
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

    final json = command['json'] as bool;
    switch (command.name) {
      case 'which':
        return _which(command.rest, json: json);
      case 'check':
        return _check(command.rest, json: json);
      case 'doctor':
        return _doctor(json: json);
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

[folder] defaults to the current folder.

Options:
  --json           Print machine-readable JSON (for scripts and AI tools).
  -h, --help       Show this help.
  --version        Show the Gita version.

Exit codes: 0 = all good, 1 = problem found, 2 = couldn't run.
''';

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
            'Open Gita and go to Doctor to reinstall the safety check.',
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

  Future<int> _doctor({required bool json}) async {
    final profiles = await ProfileRepository(paths: paths).getAll();
    final rules = await RepoRuleRepository(paths: paths).getAll();
    final sshKeys = await SshKeyRepository(paths: paths).getAll();
    final issues = await doctorService.run(
      profiles: profiles,
      rules: rules,
      sshKeys: sshKeys,
    );
    final blocking = issues.any((i) => i.severity == Severity.blocking);

    if (json) {
      out.writeln(_encode({
        'ok': !blocking,
        'configured': profiles.isNotEmpty,
        'issues': issues.map(_issueToJson).toList(),
      }));
    } else if (profiles.isEmpty) {
      out
        ..writeln('Gita isn\'t set up on this computer yet.')
        ..writeln()
        ..writeln('What to do:')
        ..writeln('  - Open the Gita app and add your accounts under Profiles.');
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
        ..writeln('Open Gita and go to Doctor for help fixing these.');
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
      };

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
    );
    final report = await detector.check(
      repoPath: repoPath,
      rules: rules,
      profilesById: profilesById,
      sshKeysById: {for (final k in sshKeys) k.id: k},
    );

    // Same lookup MismatchDetector uses, so `which` can show the expected
    // profile even when the repo is consistent (report == null).
    final rule = RepoRule.bestMatchFor(repoPath, rules);
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
