import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gita/core/models/profile.dart';
import 'package:gita/core/providers.dart';
import 'package:gita/core/services/machine_scanner.dart';
import 'package:gita/core/services/platform_paths.dart';
import 'package:gita/core/storage/repositories.dart';
import 'package:gita/features/setup/setup_wizard.dart';

const _work = ScannedRepo(path: 'C:/code/work/api', usedEmail: 'dev@acme.com', usedName: 'Dev');
const _work2 = ScannedRepo(path: 'C:/code/work/web', usedEmail: 'dev@acme.com', usedName: 'Dev');
const _home = ScannedRepo(path: 'C:/code/me/blog', usedEmail: 'me@gmail.com', usedName: 'Me');
const _key = FoundSshKey(
  privateKeyPath: 'C:/Users/me/.ssh/id_work',
  publicKeyPath: 'C:/Users/me/.ssh/id_work.pub',
  comment: 'dev@acme.com',
);

MachineScan? scanResult;
List<String>? searched;
List<SetupChoice>? applied;
bool? trackedProjects;
int markedDone = 0;

class _FakeScanner extends MachineScanner {
  _FakeScanner() : super(paths: const PlatformPaths());

  @override
  List<String> defaultSearchFolders() => ['C:/code'];

  @override
  Future<MachineScan> scan({
    List<String>? searchFolders,
    List<Profile> existingProfiles = const [],
  }) async {
    searched = searchFolders;
    return scanResult!;
  }
}

class _FakeActions extends SetupActions {
  _FakeActions(super.ref);

  @override
  Future<void> markSetupDone() async => markedDone++;

  @override
  Future<SetupResult> apply(
    List<SetupChoice> choices, {
    required List<int> palette,
    bool trackProjects = true,
  }) async {
    applied = choices;
    trackedProjects = trackProjects;
    markedDone++;
    final profiles = [
      for (final (i, c) in choices.indexed)
        Profile(
          id: 'p$i',
          label: c.label,
          gitName: c.name,
          gitEmail: c.email,
          colorArgb: palette[i],
          createdAt: DateTime(2026),
        ),
    ];
    return SetupResult(
      profiles: profiles,
      newProfiles: profiles.length,
      rules: choices.fold(0, (n, c) => n + c.folders.length),
      sshKeys: choices.where((c) => c.sshKey != null).length,
      projects: choices.fold(0, (n, c) => n + c.projects.length),
    );
  }
}

class _NoProfiles extends ProfileRepository {
  @override
  Future<List<Profile>> getAll() async => const [];
}

void main() {
  setUp(() {
    searched = null;
    applied = null;
    trackedProjects = null;
    markedDone = 0;
    scanResult = MachineScan(
      searchedFolders: const ['C:/code'],
      repos: const [_work, _work2, _home],
      sshKeys: const [_key],
      suggestions: [
        ProfileSuggestion(
          email: 'me@gmail.com',
          name: 'Me',
          label: 'Personal',
          repos: const [_home],
          folders: const ['C:/code/me'],
          isGlobalDefault: true,
        ),
        ProfileSuggestion(
          email: 'dev@acme.com',
          name: 'Dev',
          label: 'Acme',
          repos: const [_work, _work2],
          folders: const ['C:/code/work'],
          sshKey: _key,
          githubLogin: null,
        ),
      ],
    );
  });

  Future<bool?> open(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    bool? result;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        machineScannerProvider.overrideWithValue(_FakeScanner()),
        setupActionsProvider.overrideWith(_FakeActions.new),
        profileRepositoryProvider.overrideWithValue(_NoProfiles()),
        gitHubDeviceFlowProvider.overrideWithValue(null),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await showSetupWizard(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('scans, shows suggestions and applies the ticked ones', (tester) async {
    await open(tester);
    expect(find.text('Set up Gita'), findsOneWidget);
    expect(find.text('C:/code'), findsOneWidget);

    await tester.tap(find.text('Look for my accounts'));
    await tester.pumpAndSettle();
    expect(searched, ['C:/code']);
    expect(find.text('Here is what Gita found'), findsOneWidget);
    expect(find.textContaining('dev@acme.com  ·  2 project(s)'), findsOneWidget);
    expect(find.textContaining('me@gmail.com  ·  1 project(s)'), findsOneWidget);
    expect(find.text('used everywhere else'), findsOneWidget);

    // Rename the work profile and untick the personal one.
    await tester.enterText(find.widgetWithText(TextField, 'Acme'), 'Work');
    final personalBox = find.descendant(
      of: find.ancestor(of: find.textContaining('me@gmail.com'), matching: find.byType(Card)),
      matching: find.byType(Checkbox),
    );
    await tester.tap(personalBox.first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Set these up'));
    await tester.pumpAndSettle();

    expect(applied, hasLength(1));
    final c = applied!.single;
    expect(c.label, 'Work');
    expect(c.email, 'dev@acme.com');
    expect(c.folders, ['C:/code/work']);
    expect(c.sshKey?.privateKeyPath, _key.privateKeyPath);
    expect(c.projects, ['C:/code/work/api', 'C:/code/work/web']);
    expect(trackedProjects, isTrue);

    expect(find.text('All set'), findsOneWidget);
    expect(find.textContaining('1 new profile(s)'), findsOneWidget);
    expect(find.textContaining('2 project(s) on the Dashboard'), findsOneWidget);
    // No OAuth app configured: no sign-in button.
    expect(find.text('Sign in with GitHub'), findsNothing);

    await tester.tap(find.text('Finish'));
    await tester.pumpAndSettle();
    expect(find.text('All set'), findsNothing);
  });

  testWidgets('unticking a folder leaves its projects out', (tester) async {
    await open(tester);
    await tester.tap(find.text('Look for my accounts'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('C:/code/work'));
    const track = 'Add these projects to the Dashboard with the safety check';
    await tester.scrollUntilVisible(find.text(track), 200,
        scrollable: find.descendant(of: find.byType(Dialog), matching: find.byType(Scrollable)).first);
    await tester.tap(find.text('Add these projects to the Dashboard with the safety check'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set these up'));
    await tester.pumpAndSettle();

    final work = applied!.firstWhere((c) => c.email == 'dev@acme.com');
    expect(work.folders, isEmpty);
    expect(work.projects, isEmpty);
    expect(trackedProjects, isFalse);
  });

  testWidgets('stops on duplicate names and empty choices', (tester) async {
    await open(tester);
    await tester.tap(find.text('Look for my accounts'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Acme'), 'personal');
    await tester.tap(find.text('Set these up'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Two profiles are called'), findsOneWidget);
    expect(applied, isNull);

    for (final box in find.byType(Checkbox).evaluate().toList().reversed) {
      final cb = box.widget as Checkbox;
      if (cb.value == true && find.ancestor(of: find.byWidget(cb), matching: find.byType(CheckboxListTile)).evaluate().isEmpty) {
        await tester.tap(find.byWidget(cb));
      }
    }
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set these up'));
    await tester.pumpAndSettle();
    expect(find.text('Tick at least one profile, or press Skip.'), findsOneWidget);
    expect(applied, isNull);
  });

  testWidgets('Skip remembers the choice and closes', (tester) async {
    await open(tester);
    await tester.tap(find.text('Skip for now'));
    await tester.pumpAndSettle();
    expect(markedDone, 1);
    expect(find.text('Set up Gita'), findsNothing);
    expect(searched, isNull);
  });

  testWidgets('says so when nothing was found', (tester) async {
    scanResult = const MachineScan(
      searchedFolders: ['C:/code'],
      repos: [],
      sshKeys: [],
      suggestions: [],
    );
    await open(tester);
    await tester.tap(find.text('Look for my accounts'));
    await tester.pumpAndSettle();
    expect(find.textContaining('found no email'), findsOneWidget);
    final setUpButton = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Set these up'));
    expect(setUpButton.onPressed, isNull);
  });

  testWidgets('can drop a search folder before scanning', (tester) async {
    await open(tester);
    await tester.tap(find.byTooltip("Don't look here"));
    await tester.pumpAndSettle();
    expect(find.textContaining('None of the usual project folders'), findsOneWidget);
    final scan = tester.widget<ButtonStyleButton>(
      find.ancestor(of: find.text('Look for my accounts'), matching: find.bySubtype<ButtonStyleButton>()),
    );
    expect(scan.onPressed, isNull);
  });
}
