import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gita/core/services/git_service.dart';

void main() {
  late Directory tempRepo;
  late Directory emptyConfigDir;
  late GitService git;

  setUp(() async {
    tempRepo = await Directory.systemTemp.createTemp('gita_git_service_');
    emptyConfigDir = await Directory.systemTemp.createTemp('gita_empty_config_');
    // Isolate from the real machine's global/system gitconfig so tests don't
    // pick up the developer's actual name/email.
    git = GitService(environmentOverride: {
      'GIT_CONFIG_GLOBAL': '${emptyConfigDir.path}/gitconfig',
      'GIT_CONFIG_SYSTEM': '${emptyConfigDir.path}/gitconfig_system',
    });
    final init = await Process.run('git', ['init'], workingDirectory: tempRepo.path);
    expect(init.exitCode, 0);
  });

  tearDown(() async {
    if (await tempRepo.exists()) {
      await tempRepo.delete(recursive: true);
    }
    if (await emptyConfigDir.exists()) {
      await emptyConfigDir.delete(recursive: true);
    }
  });

  test('isGitRepo is true for an initialized repo, false elsewhere', () async {
    expect(await git.isGitRepo(tempRepo.path), isTrue);

    final nonRepo = await Directory.systemTemp.createTemp('gita_not_a_repo_');
    expect(await git.isGitRepo(nonRepo.path), isFalse);
    await nonRepo.delete(recursive: true);
  });

  test('topLevel resolves to the repo root from a subdirectory', () async {
    final sub = Directory('${tempRepo.path}/sub');
    await sub.create();
    final top = await git.topLevel(sub.path);
    expect(top, isNotNull);
    expect(Directory(top!).resolveSymbolicLinksSync(),
        Directory(tempRepo.path).resolveSymbolicLinksSync());
  });

  test('getConfigValue returns null for an unset key', () async {
    final value = await git.getConfigValue(tempRepo.path, 'user.email');
    expect(value, isNull);
  });

  test('setConfigValue then getConfigValue round-trips a local value', () async {
    await git.setConfigValue(tempRepo.path, 'user.email', 'work@example.com');
    final value = await git.getConfigValue(tempRepo.path, 'user.email');
    expect(value, 'work@example.com');
  });

  test('getRemoteUrl returns null when no remote configured', () async {
    final url = await git.getRemoteUrl(tempRepo.path);
    expect(url, isNull);
  });

  test('getRemoteUrl and listRemotes reflect an added remote', () async {
    final add = await Process.run(
      'git',
      ['remote', 'add', 'origin', 'git@github.com:example/repo.git'],
      workingDirectory: tempRepo.path,
    );
    expect(add.exitCode, 0);

    expect(await git.getRemoteUrl(tempRepo.path), 'git@github.com:example/repo.git');
    expect(await git.listRemotes(tempRepo.path), ['origin']);
  });

  test('config resolves through includeIf chain from a parent gitconfig', () async {
    final includedConfig = File('${tempRepo.path}_included.gitconfig');
    await includedConfig.writeAsString('[user]\n    email = included@example.com\n');

    // gitdir matching is against the resolved (symlink-free) path, which on
    // macOS differs from the raw systemTemp path (/var is a symlink into
    // /private/var).
    final resolvedRepoPath = Directory(tempRepo.path).resolveSymbolicLinksSync();
    final localConfig = File('${tempRepo.path}/.git/config');
    final original = await localConfig.readAsString();
    await localConfig.writeAsString(
      '$original\n[includeIf "gitdir:$resolvedRepoPath/"]\n'
      '    path = ${includedConfig.path}\n',
    );

    final value = await git.getConfigValue(tempRepo.path, 'user.email');
    expect(value, 'included@example.com');

    await includedConfig.delete();
  });
}
