import 'package:flutter_test/flutter_test.dart';
import 'package:gita/core/models/repo_rule.dart';

void main() {
  test('bestMatchFor matches a forward-slash repo path against a rule', () {
    final rule = RepoRule(id: 'r1', pathPattern: 'C:/Users/me/work', profileId: 'p1');
    final match = RepoRule.bestMatchFor('C:/Users/me/work', [rule]);
    expect(match?.id, 'r1');
  });

  test(
    'bestMatchFor still matches when the stored pathPattern uses backslashes '
    '(Windows folder pickers return native separators) but the tracked repo '
    'path is forward-slash, as `git rev-parse --show-toplevel` always returns',
    () {
      final rule =
          RepoRule(id: 'r1', pathPattern: r'C:\Users\me\work', profileId: 'p1');
      final match = RepoRule.bestMatchFor('C:/Users/me/work', [rule]);
      expect(match?.id, 'r1');
    },
  );

  test('bestMatchFor returns null when no rule covers the path', () {
    final rule = RepoRule(id: 'r1', pathPattern: 'C:/Users/me/work', profileId: 'p1');
    final match = RepoRule.bestMatchFor('C:/Users/me/personal', [rule]);
    expect(match, isNull);
  });

  test('bestMatchFor picks the longest (most specific) match regardless of separator style', () {
    final rules = [
      RepoRule(id: 'parent', pathPattern: r'C:\Users\me', profileId: 'p1'),
      RepoRule(id: 'child', pathPattern: 'C:/Users/me/work/special', profileId: 'p2'),
    ];
    final match = RepoRule.bestMatchFor('C:/Users/me/work/special', rules);
    expect(match?.id, 'child');
  });
}
