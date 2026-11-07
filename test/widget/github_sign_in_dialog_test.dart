import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gita/core/services/github_device_flow.dart';
import 'package:gita/features/profiles/github_sign_in_dialog.dart';

import '../support/fake_github.dart';

void main() {
  String? clipboard;
  final opened = <Uri>[];

  setUp(() {
    clipboard = null;
    opened.clear();
    TestWidgetsFlutterBinding.ensureInitialized()
        .defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
  });

  Future<GitHubSignInResult?> show(
    WidgetTester tester,
    FakeGitHub github, {
    Completer<void>? approve,
    String? expectedLogin,
  }) async {
    GitHubSignInResult? result;
    final flow = GitHubDeviceFlow(
      clientId: 'x',
      http: github,
      delay: (_) => approve?.future ?? Future<void>.value(),
    );
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await showDialog<GitHubSignInResult>(
              context: context,
              builder: (_) => GitHubSignInDialog(
                flow: flow,
                expectedLogin: expectedLogin,
                openBrowser: (uri) async {
                  opened.add(uri);
                  return true;
                },
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump();
    return result;
  }

  FakeGitHub github({String login = 'dev-ai'}) => FakeGitHub(
        tokenAnswers: [
          {'access_token': 'gho_abc'},
        ],
        user: {'login': login, 'name': 'Dev AI'},
      );

  testWidgets('shows the code, copies it and opens GitHub', (tester) async {
    final approve = Completer<void>();
    await show(tester, github(), approve: approve);

    expect(find.text('WDJB-MJHT'), findsOneWidget);
    await tester.tap(find.text('Copy code and open GitHub'));
    await tester.pump();

    expect(clipboard, 'WDJB-MJHT');
    expect(opened.single.toString(), 'https://github.com/login/device');
    expect(find.text('Waiting for GitHub…'), findsOneWidget);
  });

  testWidgets('returns the token once the account is confirmed', (tester) async {
    GitHubSignInResult? result;
    final gh = github();
    final flow = GitHubDeviceFlow(clientId: 'x', http: gh, delay: (_) async {});
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await showDialog<GitHubSignInResult>(
              context: context,
              builder: (_) => GitHubSignInDialog(flow: flow, expectedLogin: 'old-account'),
            );
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Signed in as @dev-ai'), findsOneWidget);
    expect(find.text('This profile used @old-account before.'), findsOneWidget);

    await tester.tap(find.text('Use this account'));
    await tester.pumpAndSettle();
    expect(result?.token, 'gho_abc');
    expect(result?.account.login, 'dev-ai');
  });

  testWidgets('a declined sign-in offers to try again', (tester) async {
    await show(
      tester,
      FakeGitHub(tokenAnswers: [
        {'error': 'access_denied'},
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('declined'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });
}
