import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gita/app/app.dart';

void main() {
  testWidgets('App shell shows the Dashboard by default', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: GitaApp()));
    await tester.pump();

    expect(find.text('Dashboard'), findsWidgets);
    expect(find.text('Profiles'), findsOneWidget);
    expect(find.text('Rules'), findsOneWidget);
  });
}
