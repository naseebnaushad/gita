import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gita/core/models/profile.dart';
import 'package:gita/core/providers.dart';
import 'package:gita/core/services/github_device_flow.dart';
import 'package:gita/core/services/keychain_store.dart';
import 'package:gita/core/services/legacy_tokens.dart';
import 'package:gita/core/services/secure_token_service.dart';
import 'package:gita/core/services/sign_in_checker.dart';
import 'package:gita/core/services/token_store.dart';
import 'package:gita/core/storage/repositories.dart';
import 'package:gita/features/profiles/profiles_screen.dart';

final _work = Profile(
  id: 'work',
  label: 'Work',
  gitName: 'Dev',
  gitEmail: 'dev@acme.com',
  githubLogin: 'dev-work',
  colorArgb: 0xFF0000AA,
  createdAt: DateTime(2026),
);

class _Profiles extends ProfileRepository {
  @override
  Future<List<Profile>> getAll() async => [_work];
}

class _NoLegacy implements LegacyTokens {
  @override
  Future<int> migrateAll(TokenStore store, Iterable<String> profileIds) async => 0;
  @override
  Future<void> forget(String profileId) async {}
}

/// Saved sign-ins in a map; no OS store, no old-token move.
class _Tokens extends SecureTokenService {
  _Tokens(this.saved)
    : super(
        store: TokenStore(keychain: InMemoryKeychainStore()),
        legacy: _NoLegacy(),
      );
  final Map<String, String> saved;

  @override
  Future<String?> readToken(String profileId) async => saved[profileId];
  @override
  Future<void> saveToken(String profileId, String token) async => saved[profileId] = token;
  @override
  Future<void> deleteToken(String profileId) async => saved.remove(profileId);
}

/// Answers sign-in checks from a script, per token.
class _Checker implements SignInChecker {
  _Checker(this.answers);
  final Map<String, SignInCheck> answers;
  final asked = <String>[];

  @override
  Future<SignInCheck> check(String token) async {
    asked.add(token);
    return answers[token] ?? SignInCheck.unknown;
  }
}

void main() {
  late _Tokens tokens;

  setUp(() => tokens = _Tokens({'work': 'gho_saved'}));

  Future<void> pump(WidgetTester tester, SignInChecker? checker) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          profileRepositoryProvider.overrideWithValue(_Profiles()),
          secureTokenServiceProvider.overrideWithValue(tokens),
          signInCheckerProvider.overrideWithValue(checker),
          gitHubDeviceFlowProvider.overrideWithValue(GitHubDeviceFlow(clientId: 'Ov23liTEST')),
        ],
        child: const MaterialApp(home: Scaffold(body: ProfilesScreen())),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('profile card', () {
    testWidgets('shows when GitHub cancelled the sign-in (PROFILES-001)', (tester) async {
      await pump(tester, _Checker({'gho_saved': SignInCheck.rejected}));

      expect(find.text('Work'), findsOneWidget);
      expect(find.text('Sign-in stopped working'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });

    testWidgets('shows nothing extra for a working sign-in (PROFILES-002)', (tester) async {
      await pump(tester, _Checker({'gho_saved': const SignInCheck.working('dev-work')}));

      expect(find.text('Work'), findsOneWidget);
      expect(find.text('Sign-in stopped working'), findsNothing);
    });

    testWidgets('shows nothing when GitHub cannot be asked (PROFILES-003)', (tester) async {
      await pump(tester, _Checker({}));
      expect(find.text('Sign-in stopped working'), findsNothing);

      await pump(tester, null);
      expect(find.text('Sign-in stopped working'), findsNothing);
    });

    testWidgets('a profile without a sign-in does not ask GitHub (PROFILES-004)', (tester) async {
      tokens.saved.clear();
      final checker = _Checker({});
      await pump(tester, checker);

      expect(checker.asked, isEmpty);
      expect(find.text('Sign-in stopped working'), findsNothing);
    });
  });

  group('profile editor', () {
    testWidgets('a cancelled sign-in offers Sign in again (PROFILES-005)', (tester) async {
      await pump(tester, _Checker({'gho_saved': SignInCheck.rejected}));

      await tester.tap(find.text('Work'));
      await tester.pumpAndSettle();

      expect(find.textContaining("@dev-work's sign-in stopped working"), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Sign in again'), findsOneWidget);
      expect(find.text('Signed in as @dev-work'), findsNothing);
    });

    testWidgets('a working sign-in shows who it is signed in as (PROFILES-006)', (tester) async {
      await pump(tester, _Checker({'gho_saved': const SignInCheck.working('dev-work')}));

      await tester.tap(find.text('Work'));
      await tester.pumpAndSettle();

      expect(find.text('Signed in as @dev-work'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Sign in again'), findsOneWidget);
      expect(find.textContaining('stopped working'), findsNothing);
    });
  });
}
