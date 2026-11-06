import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gita/core/models/profile.dart';
import 'package:gita/core/models/repo_rule.dart';
import 'package:gita/core/services/gitconfig_service.dart';
import 'package:gita/core/services/platform_paths.dart';

void main() {
  late Directory fakeHome;
  late PlatformPaths paths;
  late GitConfigService service;

  setUp(() async {
    fakeHome = await Directory.systemTemp.createTemp('gita_home_');
    paths = PlatformPaths(overrideHomeDir: fakeHome.path);
    service = GitConfigService(paths: paths);
  });

  tearDown(() async {
    if (await fakeHome.exists()) {
      await fakeHome.delete(recursive: true);
    }
  });

  Profile makeProfile(String id, String label) => Profile(
        id: id,
        label: label,
        gitName: '$label User',
        gitEmail: '$label@example.com',
        colorArgb: 0xFF000000,
        createdAt: DateTime(2024, 1, 1),
      );

  test('writeProfileConfigFile writes [user] name/email', () async {
    final profile = makeProfile('p1', 'work');
    await service.writeProfileConfigFile(profile);

    final content = await File('${paths.profilesDir}/p1.gitconfig').readAsString();
    expect(content, contains('[user]'));
    expect(content, contains('name = work User'));
    expect(content, contains('email = work@example.com'));
  });

  test('writeProfileConfigFile includes core.sshCommand when provided', () async {
    final profile = makeProfile('p1', 'work');
    await service.writeProfileConfigFile(profile, sshCommand: 'ssh -i ~/.ssh/id_work');

    final content = await File('${paths.profilesDir}/p1.gitconfig').readAsString();
    expect(content, contains('[core]'));
    expect(content, contains('sshCommand = ssh -i ~/.ssh/id_work'));
  });

  group('HTTPS credential helper', () {
    void installCli() => File(paths.cliPath)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('');

    test('is written when the profile has a token and the CLI exists', () async {
      installCli();
      await service.writeProfileConfigFile(makeProfile('p1', 'work'),
          useCredentialHelper: true);

      final content = await File('${paths.profilesDir}/p1.gitconfig').readAsString();
      final cli = paths.toGitConfigPath(paths.cliPath);
      expect(content, contains('[credential "https://github.com"]'));
      expect(content, contains('    helper =\n'));
      expect(content,
          contains('helper = "!\\"$cli\\" credential --profile p1"'));
    });

    test('is not written without a token', () async {
      installCli();
      await service.writeProfileConfigFile(makeProfile('p1', 'work'));

      final content = await File('${paths.profilesDir}/p1.gitconfig').readAsString();
      expect(content, isNot(contains('[credential')));
    });

    test('is not written while the CLI is missing', () async {
      await service.writeProfileConfigFile(makeProfile('p1', 'work'),
          useCredentialHelper: true);

      final content = await File('${paths.profilesDir}/p1.gitconfig').readAsString();
      expect(content, isNot(contains('[credential')));
    });
  });

  test('syncManagedIncludeIfBlock appends markers to a fresh gitconfig', () async {
    final profile = makeProfile('p1', 'work');
    await service.writeProfileConfigFile(profile);

    final rule = RepoRule(id: 'r1', pathPattern: '/Users/me/work', profileId: 'p1');
    await service.syncManagedIncludeIfBlock(
      rules: [rule],
      profilesById: {'p1': profile},
    );

    final content = await File(paths.gitConfigPath).readAsString();
    expect(content, contains('# >>> Gita managed rules'));
    expect(content, contains('# <<< Gita managed rules'));
    expect(content, contains('[includeIf "gitdir/i:/Users/me/work/"]'));
    expect(content, contains('path = ${paths.profilesDir}/p1.gitconfig'));
  });

  test('syncManagedIncludeIfBlock never touches content outside the markers', () async {
    final gitConfig = File(paths.gitConfigPath);
    await gitConfig.parent.create(recursive: true);
    await gitConfig.writeAsString(
      '[user]\n    name = Existing User\n    email = existing@example.com\n'
      '[alias]\n    st = status\n',
    );

    final profile = makeProfile('p1', 'work');
    await service.writeProfileConfigFile(profile);
    final rule = RepoRule(id: 'r1', pathPattern: '/Users/me/work', profileId: 'p1');
    await service.syncManagedIncludeIfBlock(
      rules: [rule],
      profilesById: {'p1': profile},
    );

    final content = await gitConfig.readAsString();
    expect(content, contains('name = Existing User'));
    expect(content, contains('st = status'));
    expect(content, contains('# >>> Gita managed rules'));
  });

  test('syncManagedIncludeIfBlock replaces a previously written block on re-sync', () async {
    final profileA = makeProfile('p1', 'work');
    final profileB = makeProfile('p2', 'personal');
    await service.writeProfileConfigFile(profileA);
    await service.writeProfileConfigFile(profileB);

    await service.syncManagedIncludeIfBlock(
      rules: [RepoRule(id: 'r1', pathPattern: '/Users/me/work', profileId: 'p1')],
      profilesById: {'p1': profileA},
    );
    await service.syncManagedIncludeIfBlock(
      rules: [RepoRule(id: 'r2', pathPattern: '/Users/me/personal', profileId: 'p2')],
      profilesById: {'p2': profileB},
    );

    final content = await File(paths.gitConfigPath).readAsString();
    expect(content, isNot(contains('/Users/me/work')));
    expect(content, contains('/Users/me/personal'));
    // Exactly one pair of markers after re-sync, not accumulated duplicates.
    expect('# >>> Gita managed rules — do not edit below by hand >>>'
            .allMatches(content)
            .length,
        1);
  });

  test('more specific path rule is emitted after (so it wins over) a broader one', () async {
    final parentProfile = makeProfile('p1', 'parent');
    final childProfile = makeProfile('p2', 'child');
    await service.writeProfileConfigFile(parentProfile);
    await service.writeProfileConfigFile(childProfile);

    await service.syncManagedIncludeIfBlock(
      rules: [
        RepoRule(id: 'r1', pathPattern: '/Users/me', profileId: 'p1'),
        RepoRule(id: 'r2', pathPattern: '/Users/me/work/special', profileId: 'p2'),
      ],
      profilesById: {'p1': parentProfile, 'p2': childProfile},
    );

    final content = await File(paths.gitConfigPath).readAsString();
    final parentIdx = content.indexOf('/Users/me/"');
    final childIdx = content.indexOf('/Users/me/work/special/"');
    expect(parentIdx, greaterThanOrEqualTo(0));
    expect(childIdx, greaterThan(parentIdx));
  });
}
