import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gita/core/models/profile.dart';
import 'package:gita/core/models/repo_rule.dart';
import 'package:gita/core/providers.dart';
import 'package:gita/core/services/clone_service.dart';
import 'package:gita/core/services/github_device_flow.dart';
import 'package:gita/core/services/keychain_store.dart';
import 'package:gita/core/services/legacy_tokens.dart';
import 'package:gita/core/services/platform_paths.dart';
import 'package:gita/core/services/secure_token_service.dart';
import 'package:gita/core/services/token_store.dart';
import 'package:gita/core/storage/repositories.dart';
import 'package:gita/features/dashboard/clone_dialog.dart';

import '../support/fake_github.dart';

final _work = Profile(
  id: 'work',
  label: 'Work',
  gitName: 'Dev',
  gitEmail: 'dev@acme.com',
  githubLogin: 'acme-dev',
  colorArgb: 0xFF0000AA,
  createdAt: DateTime(2026),
);
final _me = Profile(
  id: 'me',
  label: 'Personal',
  gitName: 'Me',
  gitEmail: 'me@gmail.com',
  githubLogin: 'me-on-github',
  sshKeyId: 'key-1',
  colorArgb: 0xFF00AA00,
  createdAt: DateTime(2026),
);

List<Profile> profiles = [];
({String url, String destination, String profileId})? cloned;
CloneOutcome nextOutcome = const CloneOutcome(ok: true, path: '', message: '');

class _Profiles extends ProfileRepository {
  @override
  Future<List<Profile>> getAll() async => profiles;
}

class _Rules extends RepoRuleRepository {
  @override
  Future<List<RepoRule>> getAll() async => const [];
}

class _NoLegacy implements LegacyTokens {
  @override
  Future<int> migrateAll(TokenStore store, Iterable<String> profileIds) async => 0;

  @override
  Future<void> forget(String profileId) async {}
}

class _Service extends CloneService {
  _Service() : super(paths: const PlatformPaths());

  @override
  String parentFolderFor(Profile? profile, List<RepoRule> rules) =>
      profile?.id == 'me' ? 'C:/code/me' : 'C:/code/work';
}

final signIns = <(String, String, String)>[];
var cliInstalls = 0;

class _Doctor extends DoctorActions {
  _Doctor(super.ref);

  @override
  Future<String> saveSignIn(String profileId, {required String token, required String login}) async {
    signIns.add((profileId, token, login));
    return 'Signed in.';
  }

  @override
  Future<String> installCli() async {
    cliInstalls++;
    return 'The gita command is installed.';
  }
}

class _Actions extends CloneActions {
  _Actions(super.ref);

  @override
  Future<CloneOutcome> clone({
    required String url,
    required String destination,
    required Profile profile,
    void Function(String line)? onProgress,
  }) async {
    cloned = (url: url, destination: destination, profileId: profile.id);
    onProgress?.call('Receiving objects: 50%');
    return nextOutcome;
  }
}

void main() {
  setUp(() {
    profiles = [_work, _me];
    cloned = null;
    signIns.clear();
    cliInstalls = 0;
    nextOutcome = const CloneOutcome(ok: true, path: 'C:/code/work/api', message: 'Cloned.');
  });

  Future<void> open(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final keychain = InMemoryKeychainStore();
    await tester.runAsync(() => TokenStore(keychain: keychain).saveToken('me', 'token'));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        profileRepositoryProvider.overrideWithValue(_Profiles()),
        repoRuleRepositoryProvider.overrideWithValue(_Rules()),
        secureTokenServiceProvider.overrideWithValue(
          SecureTokenService(store: TokenStore(keychain: keychain), legacy: _NoLegacy()),
        ),
        cloneServiceProvider.overrideWithValue(_Service()),
        cloneActionsProvider.overrideWith(_Actions.new),
        doctorActionsProvider.overrideWith(_Doctor.new),
        gitHubDeviceFlowProvider.overrideWithValue(GitHubDeviceFlow(
          clientId: 'x',
          http: FakeGitHub(
            tokenAnswers: [
              {'access_token': 'gho_new'},
            ],
            user: {'login': 'acme-dev', 'name': 'Dev'},
          ),
          delay: (_) async {},
        )),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showCloneDialog(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('picks the account from the address and clones into its folder', (tester) async {
    await open(tester);
    expect(find.text('Clone a project'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'https://github.com/acme-dev/api.git');
    await tester.pumpAndSettle();
    expect(find.text('Work  <dev@acme.com>'), findsOneWidget);
    expect(find.text('C:/code/work/api'), findsOneWidget);
    // Work isn't signed in: say only public projects will download.
    expect(find.textContaining('only public'), findsOneWidget);

    await tester.tap(find.text('Clone'));
    await tester.pumpAndSettle();
    expect(cloned, (url: 'https://github.com/acme-dev/api.git', destination: 'C:/code/work/api', profileId: 'work'));
    expect(find.text('Clone a project'), findsNothing);
  });

  testWidgets('switching the account moves the folder and keeps the choice', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'https://github.com/acme-dev/blog');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Work  <dev@acme.com>'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Personal  <me@gmail.com>').last);
    await tester.pumpAndSettle();
    expect(find.text('C:/code/me/blog'), findsOneWidget);
    // Personal is signed in, so no warning.
    expect(find.textContaining('only public'), findsNothing);

    // Typing more of the address doesn't undo the person's choice.
    await tester.enterText(find.byType(TextField), 'https://github.com/acme-dev/blog.git');
    await tester.pumpAndSettle();
    expect(find.text('Personal  <me@gmail.com>'), findsOneWidget);

    await tester.tap(find.text('Clone'));
    await tester.pumpAndSettle();
    expect(cloned?.profileId, 'me');
    expect(cloned?.destination, 'C:/code/me/blog');
  });

  testWidgets('explains bad input and failures without closing', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'acme/api');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clone'));
    await tester.pumpAndSettle();
    expect(find.textContaining("doesn't look like a project address"), findsOneWidget);
    expect(cloned, isNull);

    // Owner matches no profile: ask which account.
    await tester.enterText(find.byType(TextField), 'https://github.com/stranger/api');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clone'));
    await tester.pumpAndSettle();
    expect(find.text('Pick which account this project belongs to.'), findsOneWidget);

    // SSH address for a profile without a key.
    await tester.enterText(find.byType(TextField), 'git@github.com:acme-dev/api.git');
    await tester.pumpAndSettle();
    expect(find.textContaining('has no SSH key yet'), findsOneWidget);

    nextOutcome = const CloneOutcome(ok: false, path: 'x', message: 'GitHub refused it.');
    await tester.tap(find.text('Clone'));
    await tester.pumpAndSettle();
    expect(find.text('GitHub refused it.'), findsOneWidget);
    expect(find.text('Clone a project'), findsOneWidget);
    final clone = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Clone'));
    expect(clone.onPressed, isNotNull);
  });

  testWidgets('with no profiles, says to add one first', (tester) async {
    profiles = [];
    await open(tester);
    expect(find.textContaining('Add a profile first'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Clone'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Clone a project'), findsNothing);
  });

  Future<void> failClone(WidgetTester tester, CloneOutcome outcome) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'https://github.com/acme-dev/api.git');
    await tester.pumpAndSettle();
    nextOutcome = outcome;
    await tester.tap(find.text('Clone'));
    await tester.pumpAndSettle();
  }

  testWidgets('a sign-in failure offers "Sign in with GitHub" right there', (tester) async {
    await failClone(
      tester,
      const CloneOutcome(
        ok: false,
        path: 'x',
        message: "GitHub didn't accept Work's saved sign-in.",
        problem: CloneProblem.signIn,
        gitDetail: "fatal: Authentication failed for 'https://github.com/acme-dev/api.git/'",
      ),
    );
    expect(find.text("GitHub didn't accept Work's saved sign-in."), findsOneWidget);
    expect(find.textContaining('git said: fatal: Authentication failed'), findsOneWidget);

    await tester.tap(find.text('Sign in with GitHub'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use this account'));
    await tester.pumpAndSettle();

    expect(signIns, [('work', 'gho_new', 'acme-dev')]);
    expect(find.text('Signed in as @acme-dev. Press Clone to try again.'), findsOneWidget);
    expect(find.text("GitHub didn't accept Work's saved sign-in."), findsNothing);
    expect(find.text('Clone a project'), findsOneWidget);

    // Trying again clones.
    nextOutcome = const CloneOutcome(ok: true, path: 'C:/code/work/api', message: 'Cloned.');
    await tester.tap(find.text('Clone'));
    await tester.pumpAndSettle();
    expect(find.text('Clone a project'), findsNothing);
  });

  testWidgets('a helper failure offers to reinstall the gita command, not a sign-in', (tester) async {
    await failClone(
      tester,
      const CloneOutcome(
        ok: false,
        path: 'x',
        message: "Work is signed in, but git didn't get the sign-in from Gita's helper.",
        problem: CloneProblem.helper,
      ),
    );
    expect(find.text('Sign in with GitHub'), findsNothing);

    await tester.tap(find.text('Reinstall the gita command'));
    await tester.pumpAndSettle();
    expect(cliInstalls, 1);
    expect(signIns, isEmpty);
    expect(find.text('The gita command is installed. Press Clone to try again.'), findsOneWidget);
  });

  testWidgets('a failure with nothing to fix shows no button', (tester) async {
    await failClone(tester, const CloneOutcome(ok: false, path: 'x', message: 'No internet.'));
    expect(find.text('No internet.'), findsOneWidget);
    expect(find.text('Sign in with GitHub'), findsNothing);
    expect(find.text('Reinstall the gita command'), findsNothing);
    expect(find.textContaining('git said'), findsNothing);
  });
}
