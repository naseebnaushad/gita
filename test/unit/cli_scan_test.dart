import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gita/cli/gita_cli.dart';
import 'package:gita/core/models/profile.dart';
import 'package:gita/core/services/git_service.dart';
import 'package:gita/core/services/keychain_store.dart';
import 'package:gita/core/services/platform_paths.dart';
import 'package:gita/core/services/token_store.dart';
import 'package:gita/core/storage/repositories.dart';
import 'package:path/path.dart' as p;

/// `gita scan` against a temp home with a few temp projects.
void main() {
  late Directory home;
  late PlatformPaths paths;
  late GitService git;
  late StringBuffer out;
  late StringBuffer err;

  Future<int> run(List<String> args) => GitaCli(
        out: out,
        err: err,
        paths: paths,
        gitService: git,
        tokenStore: TokenStore(keychain: InMemoryKeychainStore()),
      ).run(args);

  Future<void> makeRepo(String rel, String email) async {
    final dir = Directory(p.join(home.path, rel))..createSync(recursive: true);
    for (final args in [
      ['init', '-q'],
      ['config', 'user.email', email],
      ['config', 'user.name', 'Dev'],
    ]) {
      expect((await git.raw(args, workingDir: dir.path)).exitCode, 0);
    }
  }

  setUp(() async {
    home = await Directory.systemTemp.createTemp('gita_cli_scan_');
    paths = PlatformPaths(overrideHomeDir: home.path);
    git = GitService(environmentOverride: {
      'GIT_CONFIG_GLOBAL': paths.gitConfigPath,
      'GIT_CONFIG_SYSTEM': p.join(home.path, 'gitconfig_system'),
    });
    File(paths.gitConfigPath).writeAsStringSync('[user]\n  name = Me\n  email = me@gmail.com\n');
    out = StringBuffer();
    err = StringBuffer();
  });

  tearDown(() async {
    if (home.existsSync()) await home.delete(recursive: true);
  });

  test('lists suggested profiles and changes nothing', () async {
    await makeRepo('Projects/acme/api', 'dev@acme.com');
    await makeRepo('Projects/acme/web', 'dev@acme.com');
    await makeRepo('Projects/hobby', 'me@gmail.com');
    final before = File(paths.gitConfigPath).readAsStringSync();

    expect(await run(['scan']), 0, reason: '$out$err');

    final text = out.toString();
    expect(text, contains('Found 3 project(s)'));
    expect(text, contains('Personal: Me <me@gmail.com>  (used where no rule applies)'));
    expect(text, contains('Acme: Dev <dev@acme.com>'));
    expect(text, contains('/Projects/acme'));
    expect(text, contains('Nothing was changed'));
    expect(File(paths.gitConfigPath).readAsStringSync(), before);
    expect(File(paths.profilesJsonPath).existsSync(), isFalse);
  });

  test('--json gives the suggestions', () async {
    await makeRepo('code/acme/api', 'dev@acme.com');
    expect(await run(['scan', '--json']), 0, reason: '$out$err');
    final json = jsonDecode(out.toString()) as Map<String, dynamic>;
    expect(json['ok'], isTrue);
    final profiles = (json['profiles'] as List).cast<Map<String, dynamic>>();
    expect(profiles.map((x) => x['email']), ['me@gmail.com', 'dev@acme.com']);
    expect(profiles[1]['label'], 'Acme');
    expect(profiles[1]['projects'], hasLength(1));
  });

  test('scans only the folders given', () async {
    await makeRepo('Projects/acme/api', 'dev@acme.com');
    await makeRepo('elsewhere/thing', 'x@other.com');
    expect(await run(['scan', '--json', p.join(home.path, 'elsewhere')]), 0, reason: '$out$err');
    final json = jsonDecode(out.toString()) as Map<String, dynamic>;
    final emails = (json['profiles'] as List).map((x) => (x as Map)['email']);
    expect(emails, ['me@gmail.com', 'x@other.com']);
  });

  test('marks emails that already have a profile', () async {
    await makeRepo('Projects/acme/api', 'dev@acme.com');
    await ProfileRepository(paths: paths).upsert(Profile(
      id: 'job',
      label: 'Job',
      gitName: 'Dev',
      gitEmail: 'dev@acme.com',
      colorArgb: 1,
      createdAt: DateTime(2026),
    ));
    expect(await run(['scan']), 0);
    expect(out.toString(), contains('Job: Dev <dev@acme.com>  (already a profile)'));
  });

  test('a folder that does not exist is a usage error', () async {
    expect(await run(['scan', p.join(home.path, 'nope')]), 2);
    expect(err.toString(), contains('No such folder'));
  });

  test('no usual folders: says how to point it at one', () async {
    expect(await run(['scan']), 0);
    expect(out.toString(), contains('gita scan <folder>'));
  });
}
