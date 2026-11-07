import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gita/core/models/profile.dart';
import 'package:gita/core/models/repo_rule.dart';
import 'package:gita/core/providers.dart';
import 'package:gita/core/services/company_setup.dart';
import 'package:gita/core/services/gitconfig_service.dart';
import 'package:gita/core/storage/repositories.dart';
import 'package:gita/features/rules/rules_screen.dart';

final _work = Profile(
  id: 'work',
  label: 'Work',
  gitName: 'Dev',
  gitEmail: 'dev@acme.com',
  colorArgb: 0xFF0000AA,
  createdAt: DateTime(2026),
);
final _me = Profile(
  id: 'me',
  label: 'Personal',
  gitName: 'Me',
  gitEmail: 'me@gmail.com',
  colorArgb: 0xFF00AA00,
  createdAt: DateTime(2026),
);

List<Profile> profiles = [];
List<RepoRule> rules = [];
({CompanySetup setup, String profileId})? imported;

class _Profiles extends ProfileRepository {
  @override
  Future<List<Profile>> getAll() async => profiles;
}

class _Rules extends RepoRuleRepository {
  @override
  Future<List<RepoRule>> getAll() async => [...rules];

  @override
  Future<void> upsert(RepoRule rule) async {
    rules = [
      for (final r in rules)
        if (r.id != rule.id) r,
      rule,
    ];
  }

  @override
  Future<void> delete(String id) async {
    rules = [
      for (final r in rules)
        if (r.id != id) r,
    ];
  }
}

/// Never touches the real ~/.gitconfig.
class _NoSync extends GitConfigService {
  @override
  Future<void> syncManagedIncludeIfBlock({
    required List<RepoRule> rules,
    required Map<String, Profile> profilesById,
  }) async {}
}

class _Company extends CompanyActions {
  _Company(super.ref);

  @override
  Future<CompanyImportResult> import(
    CompanySetup setup,
    Profile profile,
  ) async {
    imported = (setup: setup, profileId: profile.id);
    return CompanyImportResult(
      profile: profile,
      added: setup.owners,
      moved: const [],
      unchanged: const [],
    );
  }
}

final _acme = CompanySetup.parse(
  '{"name": "Acme", "emailDomains": ["acme.com"], "github": {"owners": ["acme", "acme-labs"]}}',
);

void main() {
  setUp(() {
    profiles = [_work, _me];
    rules = [];
    imported = null;
  });

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          profileRepositoryProvider.overrideWithValue(_Profiles()),
          repoRuleRepositoryProvider.overrideWithValue(_Rules()),
          gitConfigServiceProvider.overrideWithValue(_NoSync()),
          companyActionsProvider.overrideWith(_Company.new),
        ],
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists organization rules first, in words', (tester) async {
    rules = [
      const RepoRule(id: 'f', pathPattern: 'C:/code/personal', profileId: 'me'),
      RepoRule.account(id: 'a', owner: 'acme', profileId: 'work'),
    ];
    await pump(tester, const RulesScreen());
    expect(find.text('Import company setup'), findsOneWidget);
    expect(find.text('C:/code/personal'), findsOneWidget);
    final org = find.textContaining(
      'Projects from github.com/acme',
      findRichText: true,
    );
    expect(org, findsOneWidget);
    expect(
      tester.getTopLeft(org).dy,
      lessThan(tester.getTopLeft(find.text('C:/code/personal')).dy),
    );
    expect(
      find.byIcon(Icons.business_outlined),
      findsNWidgets(2),
    ); // header button + card
  });

  testWidgets('adds an organization rule from a pasted project address', (
    tester,
  ) async {
    await pump(tester, const RulesScreen());
    await tester.tap(find.text('New rule').first);
    await tester.pumpAndSettle();
    expect(find.text('Folder path'), findsOneWidget);

    await tester.tap(find.text('A GitHub organization'));
    await tester.pumpAndSettle();
    expect(find.text('Folder path'), findsNothing);
    expect(find.textContaining('Priority'), findsNothing);

    final owner = find.widgetWithText(
      TextFormField,
      'GitHub organization or account',
    );
    await tester.enterText(owner, 'not valid!');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Type the name from the project address'),
      findsOneWidget,
    );
    expect(rules, isEmpty);

    await tester.enterText(owner, 'https://github.com/Acme/api.git');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(rules, hasLength(1));
    expect(rules.single.isAccountRule, isTrue);
    expect(rules.single.githubOwner, 'Acme');
    expect(rules.single.host, 'github.com');
    expect(rules.single.profileId, 'work');
    expect(
      find.textContaining('Projects from github.com/Acme', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('editing an organization rule keeps its kind and id', (
    tester,
  ) async {
    rules = [
      RepoRule.account(
        id: 'a',
        owner: 'team',
        host: 'ghe.corp.example',
        profileId: 'work',
      ),
    ];
    await pump(tester, const RulesScreen());
    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();
    expect(
      find.text('A folder'),
      findsNothing,
      reason: 'kind is fixed when editing',
    );
    expect(find.text('ghe.corp.example/team'), findsOneWidget);

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Personal').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(rules.single.id, 'a');
    expect(rules.single.host, 'ghe.corp.example');
    expect(rules.single.githubOwner, 'team');
    expect(rules.single.profileId, 'me');
  });

  testWidgets('company import preselects the work profile', (tester) async {
    String? result;
    await pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async =>
              result = await showCompanyImportDialog(context, _acme),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Set up Acme'), findsOneWidget);
    expect(find.text('github.com/acme'), findsOneWidget);
    expect(find.text('github.com/acme-labs'), findsOneWidget);
    expect(find.text('Work  <dev@acme.com>'), findsOneWidget);
    expect(find.textContaining('may not accept'), findsNothing);

    await tester.tap(find.text('Set it up'));
    await tester.pumpAndSettle();
    expect(imported?.profileId, 'work');
    expect(result, contains('now use "Work"'));
    expect(find.text('Set up Acme'), findsNothing);
  });

  testWidgets(
    'company import warns when the picked profile has no company email',
    (tester) async {
      profiles = [_me];
      await pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showCompanyImportDialog(context, _acme),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('None of your profiles uses a @acme.com email'),
        findsOneWidget,
      );
      final setUp = find.widgetWithText(FilledButton, 'Set it up');
      expect(
        tester.widget<FilledButton>(setUp).onPressed,
        isNull,
        reason: 'nothing picked yet',
      );

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Personal  <me@gmail.com>').last);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Acme may not accept those commits'),
        findsOneWidget,
      );

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(imported, isNull);
    },
  );
}
