import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gita/cli/gita_cli.dart';
import 'package:gita/core/models/profile.dart';
import 'package:gita/core/models/repo_rule.dart';
import 'package:gita/core/services/git_service.dart';
import 'package:gita/core/services/hook_service.dart';
import 'package:gita/core/services/keychain_store.dart';
import 'package:gita/core/services/mismatch_detector.dart';
import 'package:gita/core/models/mismatch_report.dart';
import 'package:gita/core/services/ssh_config_service.dart';
import 'package:gita/core/services/path_resolver.dart';
import 'package:gita/core/services/platform_paths.dart';
import 'package:gita/core/services/token_store.dart';
import 'package:gita/core/storage/repositories.dart';
import 'package:path/path.dart' as p;

/// The safety check: hook install/remove, and the commit and push checks,
/// against real git repos in a temp home.
void main() {
  late Directory home;
  late Directory workspace;
  late String repo;
  late String remote;
  late PlatformPaths paths;
  late Map<String, String> env;
  late GitService git;
  late HookService hooks;
  late StringBuffer out;
  late StringBuffer err;

  final work = Profile(
    id: 'work',
    label: 'Work',
    gitName: 'Dev',
    gitEmail: 'dev@work.example.com',
    colorArgb: 0xFF0000AA,
    createdAt: DateTime(2026),
  );

  Future<ProcessResult> gitIn(String dir, List<String> args, {String? stdin}) async {
    if (stdin == null) {
      return Process.run('git', args, workingDirectory: dir, environment: env);
    }
    final process = await Process.start('git', args, workingDirectory: dir, environment: env);
    process.stdin.write(stdin);
    await process.stdin.close();
    final o = await process.stdout.transform(utf8.decoder).join();
    final e = await process.stderr.transform(utf8.decoder).join();
    return ProcessResult(process.pid, await process.exitCode, o, e);
  }

  Future<String> commit(String email, String message) async {
    File(p.join(repo, '$message.txt')).writeAsStringSync(message);
    await gitIn(repo, ['add', '.']);
    final r = await gitIn(repo, [
      '-c', 'user.name=T', '-c', 'user.email=$email',
      'commit', '--no-verify', '-qm', message,
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    return ((await gitIn(repo, ['rev-parse', 'HEAD'])).stdout as String).trim();
  }

  Future<int> cli(List<String> args, {String stdin = ''}) => GitaCli(
        out: out,
        err: err,
        paths: paths,
        gitService: git,
        tokenStore: TokenStore(keychain: InMemoryKeychainStore()),
        input: Stream.value(utf8.encode(stdin)),
        cwd: repo,
      ).run(args);

  setUp(() async {
    home = Directory.systemTemp.createTempSync('gita_guard_home_');
    workspace = Directory.systemTemp.createTempSync('gita_guard_ws_');
    paths = PlatformPaths(overrideHomeDir: home.path);
    env = {
      'GIT_CONFIG_GLOBAL': paths.gitConfigPath,
      'GIT_CONFIG_SYSTEM': p.join(home.path, 'gitconfig_system'),
    };
    File(paths.gitConfigPath).writeAsStringSync('[init]\n\tdefaultBranch = main\n');
    git = GitService(environmentOverride: env);
    hooks = HookService(paths: paths, git: git);
    repo = p.join(workspace.path, 'project');
    remote = p.join(workspace.path, 'remote.git');
    Directory(repo).createSync();
    expect((await gitIn(workspace.path, ['init', '-q', '--bare', remote])).exitCode, 0);
    expect((await gitIn(repo, ['init', '-q'])).exitCode, 0);
    await gitIn(repo, ['remote', 'add', 'origin', remote]);
    out = StringBuffer();
    err = StringBuffer();

    await ProfileRepository(paths: paths).upsert(work);
    await RepoRuleRepository(paths: paths).upsert(
      RepoRule(id: 'r', pathPattern: resolveRepoPath(workspace.path), profileId: 'work'),
    );
  });

  tearDown(() {
    for (final dir in [home, workspace]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  String hookPath(String name) => p.join(repo, '.git', 'hooks', name);

  group('HookService', () {
    test('installs both hooks and reports them installed', () async {
      expect((await hooks.status(repo)).state, GuardState.missing);

      final result = await hooks.install(repo);

      expect(result.state, GuardState.installed);
      expect((await hooks.status(repo)).state, GuardState.installed);
      final script = File(hookPath('pre-push')).readAsStringSync();
      expect(script, startsWith('#!/bin/sh\n'));
      expect(script, contains(HookService.marker));
      expect(script, contains(paths.cliPath.replaceAll(r'\', '/')));
      expect(script, contains('--no-verify'));
    });

    test("keeps the project's own hook and puts it back on remove", () async {
      Directory(p.dirname(hookPath('pre-commit'))).createSync(recursive: true);
      File(hookPath('pre-commit')).writeAsStringSync('#!/bin/sh\necho mine\n');

      await hooks.install(repo);
      expect(File(hookPath('pre-commit.local')).readAsStringSync(), contains('echo mine'));

      await hooks.uninstall(repo);
      expect(File(hookPath('pre-commit')).readAsStringSync(), contains('echo mine'));
      expect(File(hookPath('pre-commit.local')).existsSync(), isFalse);
      expect(File(hookPath('pre-push')).existsSync(), isFalse);
    });

    test('installing twice updates in place without losing the local hook', () async {
      Directory(p.dirname(hookPath('pre-push'))).createSync(recursive: true);
      File(hookPath('pre-push')).writeAsStringSync('#!/bin/sh\necho mine\n');

      await hooks.install(repo);
      final again = await hooks.install(repo);

      expect(again.state, GuardState.installed);
      expect(File(hookPath('pre-push.local')).readAsStringSync(), contains('echo mine'));
    });

    test('an older Gita hook shows as outdated', () async {
      await hooks.install(repo);
      final file = File(hookPath('pre-push'));
      file.writeAsStringSync(file.readAsStringSync().replaceAll(HookService.marker, '# Installed by Gita (gita-guard v0)'));

      expect((await hooks.status(repo)).state, GuardState.outdated);
    });

    test('leaves a project with its own hooks folder alone', () async {
      await gitIn(repo, ['config', 'core.hooksPath', '.husky']);

      final result = await hooks.install(repo);

      expect(result.state, GuardState.customHooksPath);
      expect(result.message, contains('.husky'));
      expect(Directory(p.join(repo, '.husky')).existsSync(), isFalse);
    });

    test('says when a folder is not a git project', () async {
      expect((await hooks.install(home.path)).state, GuardState.notARepo);
    });
  });

  group('gita hook pre-commit', () {
    test('lets a commit with the right email through', () async {
      await gitIn(repo, ['config', 'user.email', work.gitEmail]);

      expect(await cli(['hook', 'pre-commit']), ExitCodes.ok);
      expect(err.toString(), isEmpty);
    });

    test('stops a commit with the wrong email and says what to do', () async {
      await gitIn(repo, ['config', 'user.email', 'me@personal.example.com']);

      expect(await cli(['hook', 'pre-commit']), ExitCodes.problem);
      expect(err.toString(), contains('me@personal.example.com'));
      expect(err.toString(), contains('"Work" (dev@work.example.com)'));
      expect(err.toString(), contains('git commit --no-verify'));
    });

    test('compares emails without caring about capitals', () async {
      await gitIn(repo, ['config', 'user.email', 'Dev@Work.Example.com']);

      expect(await cli(['hook', 'pre-commit']), ExitCodes.ok);
    });

    test('never blocks a project no rule covers', () async {
      await RepoRuleRepository(paths: paths).delete('r');
      await gitIn(repo, ['config', 'user.email', 'me@personal.example.com']);

      expect(await cli(['hook', 'pre-commit']), ExitCodes.ok);
    });
  });

  group('gita hook pre-push', () {
    const zero = '0000000000000000000000000000000000000000';

    test('lets new commits with the right email through', () async {
      final sha = await commit(work.gitEmail, 'one');

      final code = await cli(['hook', 'pre-push', 'origin', remote],
          stdin: 'refs/heads/main $sha refs/heads/main $zero\n');

      expect(code, ExitCodes.ok, reason: '$err');
    });

    test('stops a commit made with another email and offers the fix', () async {
      await gitIn(repo, ['config', 'user.email', work.gitEmail]);
      final sha = await commit('me@personal.example.com', 'oops');

      final code = await cli(['hook', 'pre-push'],
          stdin: 'refs/heads/main $sha refs/heads/main $zero\n');

      expect(code, ExitCodes.problem);
      expect(err.toString(), contains('1 commit was made with another email'));
      expect(err.toString(), contains(sha.substring(0, 7)));
      expect(err.toString(), contains('git commit --amend --no-edit --reset-author'));
      expect(err.toString(), isNot(contains('go to Doctor')),
          reason: 'the email is already right for new commits');
    });

    test('only counts commits the remote does not have yet', () async {
      final old = await commit('someone@else.example.com', 'teammate');
      expect((await gitIn(repo, ['push', '-q', '--no-verify', 'origin', 'main'])).exitCode, 0);
      final mine = await commit(work.gitEmail, 'mine');

      final code = await cli(['hook', 'pre-push'],
          stdin: 'refs/heads/main $mine refs/heads/main $old\n');

      expect(code, ExitCodes.ok, reason: '$err');
    });

    test('several wrong commits get a rebase that fixes them all', () async {
      final base = await commit(work.gitEmail, 'base');
      await gitIn(repo, ['push', '-q', '--no-verify', 'origin', 'main']);
      await commit('me@personal.example.com', 'a');
      final tip = await commit('me@personal.example.com', 'b');

      final code = await cli(['hook', 'pre-push'],
          stdin: 'refs/heads/main $tip refs/heads/main $base\n');

      expect(code, ExitCodes.problem);
      expect(err.toString(), contains('2 commits were'));
      expect(err.toString(), contains('git rebase --rebase-merges $base --exec'));
      expect(err.toString(), contains('go to Doctor'),
          reason: 'user.email is not set to the work email yet');
    });

    test('deleting a branch is never blocked', () async {
      final code = await cli(['hook', 'pre-push'],
          stdin: '(delete) $zero refs/heads/old ${'1' * 40}\n');

      expect(code, ExitCodes.ok);
    });
  });

  group('installed hooks run by real git', () {
    late Directory bin;

    setUp(() async {
      // A stand-in for the gita command: records what it was given and
      // exits with the code in ~/.gita/bin/exit_code.
      bin = Directory(p.dirname(paths.cliPath))..createSync(recursive: true);
      final log = p.join(bin.path, 'log').replaceAll(r'\', '/');
      final code = p.join(bin.path, 'exit_code').replaceAll(r'\', '/');
      File(code).writeAsStringSync('0');
      File(paths.cliPath).writeAsStringSync(
        '#!/bin/sh\n'
        'echo "args: \$*" >> "$log"\n'
        'if [ "\$2" = "pre-push" ]; then sed "s/^/stdin: /" >> "$log"; fi\n'
        'exit \$(cat "$code")\n',
      );
      if (!Platform.isWindows) await Process.run('chmod', ['+x', paths.cliPath]);
      await gitIn(repo, ['config', 'user.email', work.gitEmail]);
      await gitIn(repo, ['config', 'user.name', 'Dev']);
      await hooks.install(repo);
    });

    String log() => File(p.join(bin.path, 'log')).readAsStringSync();
    void exitWith(int code) => File(p.join(bin.path, 'exit_code')).writeAsStringSync('$code');

    test('a commit runs the check, and a failing check stops it', () async {
      File(p.join(repo, 'a.txt')).writeAsStringSync('a');
      await gitIn(repo, ['add', '.']);

      expect((await gitIn(repo, ['commit', '-qm', 'a'])).exitCode, 0);
      expect(log(), contains('args: hook pre-commit'));

      exitWith(1);
      File(p.join(repo, 'b.txt')).writeAsStringSync('b');
      await gitIn(repo, ['add', '.']);
      expect((await gitIn(repo, ['commit', '-qm', 'b'])).exitCode, isNot(0));
      expect((await gitIn(repo, ['commit', '--no-verify', '-qm', 'b'])).exitCode, 0);
    });

    test('a push hands the refs to the check and can be stopped', () async {
      final sha = await commit(work.gitEmail, 'x');

      expect((await gitIn(repo, ['push', '-q', 'origin', 'main'])).exitCode, 0);
      expect(log(), contains('args: hook pre-push origin '));
      expect(log(), contains('stdin: refs/heads/main $sha refs/heads/main'));

      exitWith(1);
      await commit(work.gitEmail, 'y');
      final blocked = await gitIn(repo, ['push', '-q', 'origin', 'main']);
      expect(blocked.exitCode, isNot(0));
    });

    test("the project's own hook still runs after Gita's check", () async {
      await hooks.uninstall(repo);
      final marker = p.join(workspace.path, 'local_ran').replaceAll(r'\', '/');
      File(hookPath('pre-commit')).writeAsStringSync('#!/bin/sh\ntouch "$marker"\n');
      if (!Platform.isWindows) await Process.run('chmod', ['+x', hookPath('pre-commit')]);
      await hooks.install(repo);

      File(p.join(repo, 'c.txt')).writeAsStringSync('c');
      await gitIn(repo, ['add', '.']);
      expect((await gitIn(repo, ['commit', '-qm', 'c'])).exitCode, 0);

      expect(File(marker).existsSync(), isTrue);
      expect(log(), contains('hook pre-commit'));
    });

    test('with no gita command at all, commits still work', () async {
      File(paths.cliPath).deleteSync();
      File(p.join(repo, 'd.txt')).writeAsStringSync('d');
      await gitIn(repo, ['add', '.']);

      final result = await gitIn(repo, ['commit', '-qm', 'd']);

      expect(result.exitCode, 0, reason: '${result.stderr}');
    });
  });

  group('dashboard and gita check', () {
    Future<MismatchReport?> report() => MismatchDetector(
          gitService: git,
          sshConfigService: SshConfigService(paths: paths),
          hookService: hooks,
        ).check(
          repoPath: resolveRepoPath(repo),
          rules: [RepoRule(id: 'r', pathPattern: resolveRepoPath(workspace.path), profileId: 'work')],
          profilesById: {'work': work},
          sshKeysById: const {},
        );

    test('warn when the safety check is missing, and stop once it is added', () async {
      await gitIn(repo, ['config', 'user.email', work.gitEmail]);

      final before = await report();
      expect(before?.type, MismatchType.hookMissing);
      expect(before?.severity, Severity.warning);

      await hooks.install(repo);
      expect(await report(), isNull);
    });

    test('a wrong email is still the problem shown first', () async {
      await gitIn(repo, ['config', 'user.email', 'me@personal.example.com']);

      expect((await report())?.type, MismatchType.identityMismatch);
    });
  });

  group('gita guard', () {
    test('install, status and remove from the command line', () async {
      expect(await cli(['guard', 'status', repo]), ExitCodes.problem);
      expect(out.toString(), contains('no safety check yet'));

      expect(await cli(['guard', 'install', repo]), ExitCodes.ok);
      expect(out.toString(), contains('Done: commits and pushes'));

      expect(await cli(['guard', 'status', '--json', repo]), ExitCodes.ok);
      expect(out.toString(), contains('"state": "installed"'));

      expect(await cli(['guard', 'remove']), ExitCodes.ok);
      expect(File(hookPath('pre-push')).existsSync(), isFalse);
    });

    test('a bad action is a usage error', () async {
      expect(await cli(['guard', 'explode']), ExitCodes.usage);
    });
  });
}
