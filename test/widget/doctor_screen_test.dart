import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gita/core/models/doctor_issue.dart';
import 'package:gita/core/models/mismatch_report.dart';
import 'package:gita/core/providers.dart';
import 'package:gita/features/doctor/doctor_screen.dart';

final calls = <String>[];
Completer<String>? gate;
Object? failWith;

/// Records which fix ran instead of touching files.
class _FakeActions extends DoctorActions {
  _FakeActions(super.ref);

  Future<String> _record(String call) async {
    calls.add(call);
    if (failWith != null) throw failWith!;
    return gate?.future ?? 'Done: $call';
  }

  @override
  Future<String> turnOffSigning(String profileId) => _record('turnOffSigning $profileId');

  @override
  Future<String> unlinkSshKey(String profileId) => _record('unlinkSshKey $profileId');

  @override
  Future<String> deleteRule(String ruleId) => _record('deleteRule $ruleId');

  @override
  Future<String> installCli() => _record('installCli');
}

void main() {
  setUp(() {
    calls.clear();
    gate = null;
    failWith = null;
  });

  Future<void> pump(WidgetTester tester, List<DoctorIssue> issues) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        doctorIssuesProvider.overrideWith((ref) async => issues),
        doctorActionsProvider.overrideWith(_FakeActions.new),
      ],
      child: const MaterialApp(home: Scaffold(body: DoctorScreen())),
    ));
    await tester.pumpAndSettle();
  }

  const signing = DoctorIssue(
    category: DoctorCategory.missingSigningKey,
    severity: Severity.blocking,
    message: 'Work signs commits, but its key is gone.',
    profileId: 'work',
  );
  const sshGone = DoctorIssue(
    category: DoctorCategory.missingSshKeyFile,
    severity: Severity.warning,
    message: "Work's SSH key file is missing.",
    profileId: 'work',
  );
  const rule = DoctorIssue(
    category: DoctorCategory.orphanedRuleProfile,
    severity: Severity.warning,
    message: 'A folder rule points at a deleted profile.',
    ruleId: 'rule-1',
  );
  const keychain = DoctorIssue(
    category: DoctorCategory.keychainUnavailable,
    severity: Severity.warning,
    message: "Couldn't read the keychain.",
  );

  testWidgets('each issue shows its fix buttons', (tester) async {
    await pump(tester, [signing, sshGone, rule, keychain]);

    expect(find.widgetWithText(FilledButton, 'Turn off signing'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Set up a new key'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Stop using this key'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Delete this rule'), findsOneWidget);
    expect(find.text("Couldn't read the keychain."), findsOneWidget);
    expect(find.byType(FilledButton), findsNWidgets(3), reason: 'no button for the keychain');
  });

  testWidgets('a fix runs, shows a spinner, then says what happened', (tester) async {
    await pump(tester, [signing]);
    gate = Completer();

    await tester.tap(find.text('Turn off signing'));
    await tester.pump();
    expect(calls, ['turnOffSigning work']);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    gate!.complete('Commit signing is off for "Work".');
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Commit signing is off for "Work".'), findsOneWidget);
  });

  testWidgets('the rule and key fixes pass the right ids', (tester) async {
    await pump(tester, [sshGone, rule]);

    await tester.tap(find.text('Stop using this key'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete this rule'));
    await tester.pumpAndSettle();

    expect(calls, ['unlinkSshKey work', 'deleteRule rule-1']);
  });

  testWidgets('a fix that fails says so plainly', (tester) async {
    await pump(tester, [signing]);
    failWith = StateError('That profile no longer exists.');

    await tester.tap(find.text('Turn off signing'));
    await tester.pumpAndSettle();

    expect(find.text("That didn't work: That profile no longer exists."), findsOneWidget);
    expect(find.text('Turn off signing'), findsOneWidget, reason: 'button is back');
  });
}
