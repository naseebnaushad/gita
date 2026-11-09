import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gita/core/models/profile.dart';
import 'package:gita/core/services/github_device_flow.dart';
import 'package:gita/core/services/github_oauth_config.dart';

import '../support/fake_github.dart';

void main() {
  late List<Duration> waits;

  GitHubDeviceFlow flowWith(FakeGitHub github) => GitHubDeviceFlow(
        clientId: 'Ov23liTEST',
        http: github,
        delay: (d) async => waits.add(d),
      );

  setUp(() => waits = []);

  test('start asks for the push scopes and returns the code to show', () async {
    final github = FakeGitHub(tokenAnswers: []);
    final code = await flowWith(github).start();

    expect(code.userCode, 'WDJB-MJHT');
    expect(code.verificationUri.toString(), 'https://github.com/login/device');
    expect(code.interval, const Duration(seconds: 5));
    final form = github.posts.single.$2;
    expect(form['client_id'], 'Ov23liTEST');
    expect(form['scope']!.split(' '), containsAll(['repo', 'workflow', 'write:public_key', 'read:org']));
  });

  test('waits while pending, slows down when asked, then returns the token', () async {
    final github = FakeGitHub(tokenAnswers: [
      {'error': 'authorization_pending'},
      {'error': 'slow_down', 'interval': 10},
      {'error': 'authorization_pending'},
      {'access_token': 'gho_abc', 'token_type': 'bearer', 'scope': 'repo,workflow'},
    ]);
    final flow = flowWith(github);

    final token = await flow.waitForToken(await flow.start());

    expect(token, 'gho_abc');
    expect(waits.map((d) => d.inSeconds), [5, 5, 10, 10]);
    final poll = github.posts.last.$2;
    expect(poll['device_code'], 'dev-123');
    expect(poll['grant_type'], 'urn:ietf:params:oauth:grant-type:device_code');
  });

  test('a declined sign-in becomes a plain-language error', () async {
    final github = FakeGitHub(tokenAnswers: [{'error': 'access_denied'}]);
    final flow = flowWith(github);

    await expectLater(
      flow.waitForToken(await flow.start()),
      throwsA(isA<DeviceFlowException>()
          .having((e) => e.error, 'error', DeviceFlowError.denied)
          .having((e) => e.message, 'message', contains('Authorize'))),
    );
  });

  test('device flow switched off on the OAuth app is reported as such', () async {
    final github = FakeGitHub(
      tokenAnswers: [],
      deviceAnswer: GitHubResponse(200, jsonEncode({'error': 'device_flow_disabled'})),
    );

    await expectLater(
      flowWith(github).start(),
      throwsA(isA<DeviceFlowException>()
          .having((e) => e.error, 'error', DeviceFlowError.deviceFlowDisabled)),
    );
  });

  test('an unknown client ID (404) is reported as a bad client ID', () async {
    final github = FakeGitHub(
      tokenAnswers: [],
      // What github.com really sends for an unknown client ID.
      deviceAnswer: const GitHubResponse(404, '{"error":"Not Found"}'),
    );

    await expectLater(
      flowWith(github).start(),
      throwsA(isA<DeviceFlowException>()
          .having((e) => e.error, 'error', DeviceFlowError.badClientId)),
    );
  });

  test('stops polling once cancelled', () async {
    final github = FakeGitHub(tokenAnswers: [
      for (var i = 0; i < 10; i++) {'error': 'authorization_pending'},
    ]);
    final flow = flowWith(github);
    final code = await flow.start();

    await expectLater(
      flow.waitForToken(code, isCancelled: () => github.polls >= 2),
      throwsA(isA<DeviceFlowException>()
          .having((e) => e.error, 'error', DeviceFlowError.cancelled)),
    );
    expect(github.polls, 2);
  });

  test('fetchAccount reads the login and primary verified email', () async {
    final github = FakeGitHub(
      tokenAnswers: [],
      user: {'login': 'dev-ai', 'name': 'Dev AI', 'email': null},
      emails: [
        {'email': 'old@example.com', 'primary': false, 'verified': true},
        {'email': 'dev@ai.example.com', 'primary': true, 'verified': true},
      ],
    );

    final account = await flowWith(github).fetchAccount('gho_abc');

    expect(account.login, 'dev-ai');
    expect(account.name, 'Dev AI');
    expect(account.email, 'dev@ai.example.com');
    expect(github.gets.first.$2, 'gho_abc');
  });

  test('fetchAccount still works when emails are not shared', () async {
    final github = FakeGitHub(tokenAnswers: [], user: {'login': 'dev-ai'});

    final account = await flowWith(github).fetchAccount('gho_abc');

    expect(account.login, 'dev-ai');
    expect(account.email, isNull);
  });

  test('a network failure says to check the connection', () async {
    final flow = GitHubDeviceFlow(clientId: 'x', http: _OfflineHttp());

    await expectLater(
      flow.start(),
      throwsA(isA<DeviceFlowException>()
          .having((e) => e.error, 'error', DeviceFlowError.network)
          .having((e) => e.message, 'message', contains('internet'))),
    );
  });

  group('client ID', () {
    test('the environment variable is used when set', () {
      expect(resolveGitHubClientId(environment: {'GITA_GITHUB_CLIENT_ID': ' Ov23liX '}),
          'Ov23liX');
    });

    test("defaults to Gita's own OAuth app", () {
      // Tests run without --dart-define, so the built-in default applies.
      expect(resolveGitHubClientId(environment: {}), gitaGitHubClientId);
    });

    test('is null when a build switches sign-in off', () {
      expect(resolveGitHubClientId(environment: {}, builtIn: ''), isNull);
    });
  });

  test('Profile keeps githubLogin through JSON and omits it when unset', () {
    final p = Profile(
      id: 'p',
      label: 'AI',
      gitName: 'Dev',
      gitEmail: 'dev@example.com',
      githubLogin: 'dev-ai',
      colorArgb: 0,
      createdAt: DateTime(2026),
    );
    expect(Profile.fromJson(p.toJson()).githubLogin, 'dev-ai');

    final plain = Profile.fromJson({...p.toJson()}..remove('githubLogin'));
    expect(plain.githubLogin, isNull);
    expect(plain.toJson().containsKey('githubLogin'), isFalse);
  });
}

class _OfflineHttp implements GitHubHttp {
  @override
  Future<GitHubResponse> post(Uri uri, Map<String, String> form) =>
      throw const SocketException('offline');

  @override
  Future<GitHubResponse> get(Uri uri, String token) =>
      throw const SocketException('offline');

  @override
  Future<GitHubResponse> postJson(Uri uri, String token, Map<String, Object?> body) =>
      throw const SocketException('offline');
}
