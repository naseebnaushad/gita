import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gita/core/models/ssh_key.dart';
import 'package:gita/core/services/github_device_flow.dart';
import 'package:gita/core/services/github_ssh_keys.dart';
import 'package:gita/core/services/platform_paths.dart';
import 'package:gita/core/services/ssh_key_service.dart';
import 'package:path/path.dart' as p;

import '../support/fake_github.dart';

void main() {
  late Directory home;
  late PlatformPaths paths;
  late List<(String, List<String>)> calls;

  setUp(() {
    home = Directory.systemTemp.createTempSync('gita_ssh_');
    paths = PlatformPaths(overrideHomeDir: home.path);
    calls = [];
  });

  tearDown(() => home.deleteSync(recursive: true));

  /// Plays ssh-keygen and ssh. [sshOutput] is what `ssh -T` prints.
  SshKeyService service({String sshOutput = '', bool knowsGitHub = false}) =>
      SshKeyService(
        paths: paths,
        run: (exe, args) async {
          calls.add((exe, args));
          final tool = p.basenameWithoutExtension(exe);
          if (tool == 'git') return ProcessResult(0, 1, '', 'no git here');
          if (tool == 'ssh-keygen' && args.first == '-t') {
            final path = args[args.indexOf('-f') + 1];
            File(path).writeAsStringSync('PRIVATE');
            File('$path.pub').writeAsStringSync('ssh-ed25519 AAAAkey ${args[args.indexOf('-C') + 1]}\n');
            return ProcessResult(0, 0, '', '');
          }
          if (tool == 'ssh-keygen' && args.first == '-F') {
            return knowsGitHub
                ? ProcessResult(0, 0, '# Host github.com found\ngithub.com ssh-ed25519 X', '')
                : ProcessResult(0, 1, '', '');
          }
          if (tool == 'ssh') return ProcessResult(0, 1, '', sshOutput);
          throw ProcessException(exe, args);
        },
      );

  SshKey keyAt(String name) {
    final path = p.join(home.path, '.ssh', name);
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('PRIVATE');
    return SshKey(
      id: 'k',
      label: 'Work',
      privateKeyPath: path,
      publicKeyPath: '$path.pub',
      hostAlias: 'github.com',
      realHost: 'github.com',
      createdAt: DateTime(2026),
    );
  }

  group('generate', () {
    test('makes a passphrase-less ed25519 key named after the profile', () async {
      final key = await service().generate(profileLabel: 'ThoughtBox Work', email: 'me@tb.io');

      expect(key.privateKeyPath, p.join(home.path, '.ssh', 'gita_thoughtbox_work'));
      expect(key.publicKeyPath, '${key.privateKeyPath}.pub');
      expect(key.realHost, 'github.com');
      final args = calls.firstWhere((c) => c.$2.first == '-t').$2;
      expect(args, containsAllInOrder(['-t', 'ed25519']));
      expect(args[args.indexOf('-N') + 1], '');
      expect(args[args.indexOf('-C') + 1], 'me@tb.io');
    });

    test('never overwrites an existing key file', () async {
      final ssh = Directory(p.join(home.path, '.ssh'))..createSync();
      File(p.join(ssh.path, 'gita_work')).writeAsStringSync('mine');

      final key = await service().generate(profileLabel: 'Work', email: 'a@b.c');

      expect(key.privateKeyPath, p.join(ssh.path, 'gita_work_2'));
      expect(File(p.join(ssh.path, 'gita_work')).readAsStringSync(), 'mine');
    });

    test('reports a plain message when ssh-keygen fails', () async {
      final failing = SshKeyService(
        paths: paths,
        run: (exe, args) async => ProcessResult(0, 1, '', 'Saving key failed'),
      );

      await expectLater(
        failing.generate(profileLabel: 'Work', email: 'a@b.c'),
        throwsA(isA<SshKeyException>()
            .having((e) => e.message, 'message', contains('Saving key failed'))),
      );
    });

    test('says to install Git when no ssh-keygen exists', () async {
      final missing = SshKeyService(
        paths: paths,
        run: (exe, args) async => throw ProcessException(exe, args),
      );

      await expectLater(
        missing.generate(profileLabel: 'Work', email: 'a@b.c'),
        throwsA(isA<SshKeyException>().having((e) => e.message, 'message', contains('Install Git'))),
      );
    });
  });

  test('sshCommandFor uses only the profile key, with a forward-slash path', () {
    final key = keyAt('gita_work');
    final command = service().sshCommandFor(key);

    expect(command, startsWith('ssh -i "'));
    expect(command, contains(key.privateKeyPath.replaceAll(r'\', '/')));
    expect(command, isNot(contains(r'\')));
    expect(command, endsWith('-o IdentitiesOnly=yes'));
  });

  group('check', () {
    test("reads the account from GitHub's greeting", () async {
      final result = await service(
        sshOutput: "Hi tbaiadmin! You've successfully authenticated, but GitHub "
            'does not provide shell access.',
      ).check(keyAt('gita_work'));

      expect(result.works, isTrue);
      expect(result.login, 'tbaiadmin');
      final args = calls.firstWhere((c) => p.basenameWithoutExtension(c.$1) == 'ssh').$2;
      expect(args, containsAllInOrder(['-F', 'none']));
      expect(args, contains('IdentitiesOnly=yes'));
      expect(args, contains('BatchMode=yes'));
      expect(args, contains(startsWith('UserKnownHostsFile="')));
      expect(args.last, 'git@github.com');
    });

    test('an unknown key says to add it to GitHub', () async {
      final result = await service(sshOutput: 'git@github.com: Permission denied (publickey).')
          .check(keyAt('gita_work'));

      expect(result.works, isFalse);
      expect(result.message, contains('Add it to the GitHub account'));
    });

    test('a missing key file is reported without running ssh', () async {
      final key = keyAt('gita_work');
      File(key.privateKeyPath).deleteSync();

      final result = await service().check(key);

      expect(result.works, isFalse);
      expect(result.message, contains('missing'));
      expect(calls, isEmpty);
    });
  });

  group('trustGitHub', () {
    test("adds GitHub's published host keys to known_hosts", () async {
      final s = service();
      File(s.knownHostsPath)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('example.com ssh-ed25519 OTHER');

      await s.trustGitHub(() async => ['ssh-ed25519 AAAAgh', 'ecdsa-sha2-nistp256 AAAAec']);

      expect(File(s.knownHostsPath).readAsLinesSync(), [
        'example.com ssh-ed25519 OTHER',
        'github.com ssh-ed25519 AAAAgh',
        'github.com ecdsa-sha2-nistp256 AAAAec',
      ]);
    });

    test('leaves known_hosts alone when GitHub is already there', () async {
      final s = service(knowsGitHub: true);
      File(s.knownHostsPath)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('github.com ssh-ed25519 X\n');
      var fetched = false;

      await s.trustGitHub(() async {
        fetched = true;
        return ['ssh-ed25519 NEW'];
      });

      expect(fetched, isFalse);
      expect(File(s.knownHostsPath).readAsStringSync(), 'github.com ssh-ed25519 X\n');
    });
  });

  group('GitHubSshKeys', () {
    test('adds the key to the signed-in account', () async {
      final github = FakeGitHub();
      final result = await GitHubSshKeys(http: github)
          .add(token: 'gho_x', title: 'Gita: Work', publicKey: 'ssh-ed25519 AAAA');

      expect(result.outcome, AddSshKeyOutcome.added);
      expect(result.onGitHub, isTrue);
      final (uri, token, body) = github.jsonPosts.single;
      expect(uri.toString(), 'https://api.github.com/user/keys');
      expect(token, 'gho_x');
      expect(body, {'title': 'Gita: Work', 'key': 'ssh-ed25519 AAAA'});
    });

    test('a key GitHub already has counts as on GitHub', () async {
      final github = FakeGitHub(
        addKeyAnswer: GitHubResponse(422, jsonEncode({
          'message': 'Validation Failed',
          'errors': [{'resource': 'PublicKey', 'field': 'key', 'message': 'key is already in use'}],
        })),
      );

      final result = await GitHubSshKeys(http: github)
          .add(token: 't', title: 't', publicKey: 'k');

      expect(result.outcome, AddSshKeyOutcome.alreadyAdded);
    });

    test('a token without the key permission asks to sign in again', () async {
      final github = FakeGitHub(addKeyAnswer: const GitHubResponse(404, '{"message":"Not Found"}'));

      final result = await GitHubSshKeys(http: github)
          .add(token: 't', title: 't', publicKey: 'k');

      expect(result.outcome, AddSshKeyOutcome.needsPermission);
      expect(result.onGitHub, isFalse);
    });

    test('hostKeys reads ssh_keys from /meta without a token', () async {
      final github = FakeGitHub(meta: {
        'ssh_keys': ['ssh-ed25519 AAAAgh', 'not a key'],
      });

      expect(await GitHubSshKeys(http: github).hostKeys(), ['ssh-ed25519 AAAAgh']);
      expect(github.gets.single.$2, '');
    });

    test('hostKeys is empty when GitHub is unreachable', () async {
      expect(await GitHubSshKeys(http: FakeGitHub()).hostKeys(), isEmpty);
    });
  });

  test('a real ssh-keygen makes a key git can use', () async {
    final real = SshKeyService(paths: paths);
    final SshKey key;
    try {
      key = await real.generate(profileLabel: 'Real', email: 'real@example.com');
    } on SshKeyException catch (e) {
      markTestSkipped('ssh-keygen not available: ${e.message}');
      return;
    }

    expect(File(key.privateKeyPath).existsSync(), isTrue);
    expect(await real.readPublicKey(key), allOf(startsWith('ssh-ed25519 '), endsWith('real@example.com')));
  });
}
