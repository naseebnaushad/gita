import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gita/core/models/profile.dart';
import 'package:gita/core/models/repo_rule.dart';
import 'package:gita/core/services/gitconfig_service.dart';
import 'package:gita/core/services/path_resolver.dart';
import 'package:gita/core/services/platform_paths.dart';

/// Checks, with real git, that the credential config Gita writes sends
/// HTTPS sign-ins for a profile's folders to `gita credential --profile`,
/// and nowhere else.
///
/// The installed CLI is replaced by a small shell script that echoes the
/// profile id back as the password, so this test is about git's routing
/// (includeIf + URL scoping + helper reset), not the CLI itself, which
/// gita_cli_test.dart covers.
void main() {
  late Directory home;
  late Directory workspace;
  late Directory outside;
  late PlatformPaths paths;
  late Map<String, String> env;

  Profile profile(String id) => Profile(
        id: id,
        label: id,
        gitName: id,
        gitEmail: '$id@example.com',
        colorArgb: 0xFF000000,
        createdAt: DateTime(2026, 1, 1),
      );

  Future<Directory> initRepo(Directory parent) async {
    final repo = Directory('${parent.path}/repo')..createSync();
    final init = await Process.run('git', ['init'], workingDirectory: repo.path);
    expect(init.exitCode, 0);
    return repo;
  }

  /// Runs `git credential fill` in [repo] and returns the password git got.
  Future<String?> passwordFor(Directory repo, {String host = 'github.com'}) async {
    final process = await Process.start(
      'git',
      ['credential', 'fill'],
      workingDirectory: repo.path,
      environment: env,
    );
    process.stdin.write('protocol=https\nhost=$host\n\n');
    await process.stdin.close();
    final stdout = await process.stdout.transform(systemEncoding.decoder).join();
    await process.exitCode;
    for (final line in stdout.split('\n')) {
      if (line.startsWith('password=')) return line.substring(9).trim();
    }
    return null;
  }

  setUp(() async {
    home = await Directory.systemTemp.createTemp('gita_cred_home_');
    workspace = await Directory.systemTemp.createTemp('gita_cred_ws_');
    outside = await Directory.systemTemp.createTemp('gita_cred_out_');
    paths = PlatformPaths(overrideHomeDir: home.path);

    // Stand-in for the installed gita CLI: `credential --profile <id> get`
    // answers with password=from-gita-<id>.
    File(paths.cliPath)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('#!/bin/sh\n'
          'cat >/dev/null\n'
          'echo username=x\n'
          'echo password=from-gita-\$3\n');
    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', paths.cliPath]);
    }

    // A machine-wide helper standing in for Git Credential Manager, which
    // remembers one login per host.
    final system = File('${home.path}/gitconfig_system');
    await system.writeAsString('[credential]\n'
        '    helper = "!f() { cat >/dev/null; echo username=x; '
        'echo password=from-system; }; f"\n');

    env = {
      'GIT_CONFIG_GLOBAL': paths.gitConfigPath,
      'GIT_CONFIG_SYSTEM': system.path,
      'GIT_TERMINAL_PROMPT': '0',
    };
  });

  tearDown(() async {
    for (final dir in [home, workspace, outside]) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  Future<void> assign(Profile p, {required bool useHelper}) async {
    final service = GitConfigService(paths: paths);
    await service.writeProfileConfigFile(p, useCredentialHelper: useHelper);
    await service.syncManagedIncludeIfBlock(
      rules: [
        RepoRule(
          id: 'r',
          pathPattern: resolveRepoPath(workspace.path),
          profileId: p.id,
        ),
      ],
      profilesById: {p.id: p},
    );
  }

  test('a project in the profile folder signs in with that profile', () async {
    await assign(profile('ai'), useHelper: true);
    final repo = await initRepo(workspace);

    expect(await passwordFor(repo), 'from-gita-ai');
  });

  test('projects outside the folder keep the machine helper', () async {
    await assign(profile('ai'), useHelper: true);
    final repo = await initRepo(outside);

    expect(await passwordFor(repo), 'from-system');
  });

  test('other hosts keep the machine helper', () async {
    await assign(profile('ai'), useHelper: true);
    final repo = await initRepo(workspace);

    expect(await passwordFor(repo, host: 'gitlab.com'), 'from-system');
  });

  test('without a saved token the profile leaves sign-in alone', () async {
    await assign(profile('ai'), useHelper: false);
    final repo = await initRepo(workspace);

    expect(await passwordFor(repo), 'from-system');
  });
}
