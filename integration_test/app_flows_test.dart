// On-device test of the real app: first-start setup, "Clone a project" (a
// real clone from GitHub) and Rules → "Import company setup".
//
// It changes git settings and ~/.gita, so it only runs in a throwaway home
// folder. Run it with tool/run_integration_test.ps1, which makes one and
// points USERPROFILE, HOME and GIT_CONFIG_GLOBAL at it.
import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gita/app/app.dart';
import 'package:gita/core/services/platform_paths.dart';
import 'package:gita/core/storage/repositories.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

/// Answers the "choose a file" window with [path] instead of opening it.
class _PickFile extends FileSelectorPlatform {
  _PickFile(this.path);
  final String path;

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async =>
      XFile(path);
}

Future<String> git(List<String> args, {String? inDir}) async {
  final r = await Process.run('git', args, workingDirectory: inDir);
  if (r.exitCode != 0) throw StateError('git ${args.join(' ')}: ${r.stderr}');
  return (r.stdout as String).trim();
}

Future<void> waitFor(WidgetTester tester, Finder finder, {int seconds = 30}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 200));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('Timed out waiting for $finder');
}

Future<void> tapText(WidgetTester tester, String text) async {
  await waitFor(tester, find.text(text));
  await tester.tap(find.text(text).last);
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final home = const PlatformPaths().homeDir();

  setUpAll(() async {
    // Never touch a real home folder.
    if (!File(p.join(home, 'gita-test-home')).existsSync()) {
      fail('$home is not a throwaway test home (no gita-test-home file). '
          'Run tool/run_integration_test.ps1.');
    }
    for (final (dir, email, remote) in [
      ('Projects/acme/api', 'dev@acme.com', 'https://github.com/acme/api.git'),
      ('Projects/personal/blog', 'me@gmail.com', 'https://github.com/me-on-github/blog.git'),
    ]) {
      final path = p.join(home, dir);
      if (Directory(path).existsSync()) continue;
      Directory(path).createSync(recursive: true);
      await git(['init', '-q'], inDir: path);
      await git(['config', 'user.email', email], inDir: path);
      await git(['config', 'user.name', email.split('@').first], inDir: path);
      await git(['remote', 'add', 'origin', remote], inDir: path);
      File(p.join(path, 'README.md')).writeAsStringSync('hi\n');
      await git(['add', '.'], inDir: path);
      await git(['commit', '-q', '-m', 'first'], inDir: path);
    }
  });

  testWidgets('set up, clone a project and import a company setup', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: GitaApp()));

    // First start: the setup wizard opens by itself.
    await tapText(tester, 'Look for my accounts');
    await waitFor(tester, find.text('Set these up'), seconds: 60);
    expect(find.textContaining('dev@acme.com'), findsWidgets);
    expect(find.textContaining('me@gmail.com'), findsWidgets);
    await tapText(tester, 'Set these up');
    await tapText(tester, 'Finish');

    final profiles = await ProfileRepository().getAll();
    final work = profiles.singleWhere((pr) => pr.gitEmail == 'dev@acme.com');
    expect(profiles.map((pr) => pr.gitEmail), containsAll(['dev@acme.com', 'me@gmail.com']));

    // Existing projects already commit as the right person.
    expect(await git(['config', 'user.email'], inDir: p.join(home, 'Projects/acme/api')), 'dev@acme.com');

    // Clone a public project nobody has a rule for, as the work account.
    await tapText(tester, 'Clone a project');
    await tester.enterText(find.byType(TextField), 'https://github.com/octocat/Hello-World.git');
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.textContaining('<dev@acme.com>').last);
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('only public'), findsOneWidget, reason: 'work is not signed in');
    await tester.tap(find.widgetWithText(FilledButton, 'Clone'));
    await tester.pump(const Duration(milliseconds: 300));
    final end = DateTime.now().add(const Duration(minutes: 2));
    while (find.text('Clone a project').evaluate().length > 1 && DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    // Only the Dashboard button is left: the dialog closed after cloning.
    expect(find.text('Clone a project'), findsOneWidget);

    final tracked = await TrackedRepoRepository().getAll();
    final cloned = tracked.singleWhere((r) => r.path.replaceAll('\\', '/').endsWith('/Hello-World'));
    expect(File(p.join(cloned.path, 'README')).existsSync(), isTrue);
    expect(await git(['config', 'user.email'], inDir: cloned.path), 'dev@acme.com');
    expect(await git(['config', 'remote.origin.url'], inDir: cloned.path),
        'https://github.com/octocat/Hello-World.git');

    // Rules → Import company setup, with a company file that also claims
    // octocat as a company organization.
    final company = File(p.join(home, 'acme-gita.json'))
      ..writeAsStringSync('{"name": "Acme", "emailDomains": ["acme.com"], '
          '"github": {"owners": ["acme", "octocat"]}}');
    FileSelectorPlatform.instance = _PickFile(company.path);
    await tapText(tester, 'Rules');
    await tapText(tester, 'Import company setup');
    await waitFor(tester, find.text('Set up Acme'));
    expect(
      find.descendant(of: find.byType(AlertDialog), matching: find.textContaining('<dev@acme.com>')),
      findsOneWidget,
      reason: 'work profile picked by email',
    );
    await tapText(tester, 'Set it up');
    await waitFor(tester, find.byType(SnackBar));
    expect(find.text('Set up Acme'), findsNothing);

    final rules = await RepoRuleRepository().getAll();
    final owners = {
      for (final r in rules)
        if (r.isAccountRule) r.githubOwner!.toLowerCase(): r.profileId,
    };
    expect(owners['acme'], work.id);
    expect(owners['octocat'], work.id);
    await waitFor(tester, find.textContaining('Projects from github.com/octocat', findRichText: true));

    // A brand-new octocat project (no folder rule) now uses the work account.
    final other = p.join(home, 'elsewhere', 'Spoon-Knife');
    Directory(other).createSync(recursive: true);
    await git(['init', '-q'], inDir: other);
    await git(['remote', 'add', 'origin', 'https://github.com/octocat/Spoon-Knife.git'], inDir: other);
    expect(await git(['config', 'user.email'], inDir: other), 'dev@acme.com');
  });
}
