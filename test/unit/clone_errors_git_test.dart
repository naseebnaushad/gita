import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gita/core/models/profile.dart';
import 'package:gita/core/services/clone_service.dart';
import 'package:path/path.dart' as p;

/// Checks the clone error explanations against what real git prints, using
/// a local server that asks for a login on every request (as GitHub does
/// for a private project) and a credential helper set up the way Gita's
/// git settings set it up.
void main() {
  late HttpServer server;
  late Directory home;
  late String url;
  final authorizations = <String?>[];

  final work = Profile(
    id: 'work',
    label: 'Work',
    gitName: 'Dev',
    gitEmail: 'dev@acme.com',
    githubLogin: 'acme-dev',
    colorArgb: 0xFF0000AA,
    createdAt: DateTime(2026),
  );

  setUp(() async {
    authorizations.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      authorizations.add(request.headers.value('authorization'));
      request.response
        ..statusCode = HttpStatus.unauthorized
        ..headers.set('WWW-Authenticate', 'Basic realm="GitHub"')
        ..close();
    });
    url = 'http://127.0.0.1:${server.port}/acme/api.git';
    home = await Directory.systemTemp.createTemp('gita_clone_err_');
  });

  tearDown(() async {
    await server.close(force: true);
    if (await home.exists()) await home.delete(recursive: true);
  });

  /// Clones [url] with [helper] as the only credential helper for the
  /// server, the way Gita's profile settings do for github.com, and
  /// returns git's error output.
  Future<String> cloneWith(String helper) async {
    final config = File(p.join(home.path, 'gitconfig'))
      ..writeAsStringSync('[credential]\n'
          // Clear helpers git has built in (osxkeychain on macOS, the
          // Credential Manager on Windows), so nothing real is read.
          '\thelper =\n'
          '[credential "http://127.0.0.1:${server.port}"]\n'
          '\thelper =\n'
          '\thelper = $helper\n');
    final r = await Process.run(
      'git',
      ['clone', url, p.join(home.path, 'api')],
      environment: {
        'GIT_CONFIG_GLOBAL': config.path,
        'GIT_CONFIG_SYSTEM': p.join(home.path, 'nosystem'),
        'GIT_CONFIG_NOSYSTEM': '1',
        'GIT_TERMINAL_PROMPT': '0',
        'GCM_INTERACTIVE': 'never',
      },
    );
    expect(r.exitCode, isNot(0));
    return r.stderr as String;
  }

  String script(String name, String body) {
    final file = File(p.join(home.path, name))..writeAsStringSync('#!/bin/sh\ncat >/dev/null\n$body');
    Process.runSync('chmod', ['+x', file.path]);
    return '!"${file.path.replaceAll(r'\', '/')}" credential --profile work';
  }

  CloneError classify(String stderr, {bool helperInstalled = true}) => CloneService.classifyCloneError(
        stderr,
        profile: work,
        url: 'https://github.com/acme/api.git',
        signedIn: true,
        helperInstalled: helperInstalled,
      );

  test('the helper is missing: git asks for a login, and Gita says to fix the helper', () async {
    final missing = p.join(home.path, '.gita', 'bin', 'gita').replaceAll(r'\', '/');
    final stderr = await cloneWith('!"$missing" credential --profile work');

    expect(authorizations.whereType<String>(), isEmpty, reason: 'no sign-in ever reached the server');
    final e = classify(stderr, helperInstalled: false);
    expect(e.problem, CloneProblem.helper, reason: stderr);
    expect(e.message, contains("isn't installed"));
    expect(classify(stderr).problem, CloneProblem.helper, reason: stderr);
  });

  test('the helper gives a token the server turns down: sign in again', () async {
    final stderr = await cloneWith(script('gita', 'echo username=x\necho password=gho_revoked\n'));

    expect(authorizations.whereType<String>(), isNotEmpty, reason: 'the token was sent');
    final e = classify(stderr);
    expect(e.problem, CloneProblem.signIn, reason: stderr);
    expect(e.message, contains('Sign Work in with GitHub again'));
    expect(e.gitDetail, isNot(contains('gho_revoked')));
  });

  test("Gita's helper with no saved sign-in (what `gita credential` prints): sign in again",
      () async {
    final stderr = await cloneWith(script(
      'gita',
      "echo 'Gita: there is no GitHub sign-in saved for \"Work\", so this push can'\"'\"'t sign in.' >&2\n"
          'echo quit=1\n',
    ));

    final e = classify(stderr);
    expect(e.problem, CloneProblem.signIn, reason: stderr);
    expect(e.message, contains('found no saved GitHub sign-in'));
  });

  test("Gita's helper can't open the password store: say so", () async {
    final stderr = await cloneWith(script(
      'gita',
      "echo \"Gita: couldn't open this computer's password store to sign in to GitHub.\" >&2\n"
          'echo quit=1\n',
    ));

    final e = classify(stderr);
    expect(e.problem, CloneProblem.helper, reason: stderr);
    expect(e.message, contains('password store'));
  });
}
