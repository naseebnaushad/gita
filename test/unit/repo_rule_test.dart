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

  group('a second account in one organization', () {
    final org = RepoRule.account(id: 'org', owner: 'acme', profileId: 'main');
    const url = 'https://github.com/acme/api.git';

    test('an organization rule beats an ordinary folder rule', () {
      final folder = RepoRule(id: 'f', pathPattern: '/w/acme', profileId: 'other');
      final m = RepoRule.bestMatchFor('/w/acme/api', [org, folder], remoteUrls: [url]);
      expect(m?.id, 'org');
    });

    test('a folder rule marked to override beats the organization rule', () {
      final folder = RepoRule(
        id: 'f',
        pathPattern: '/w/acme',
        profileId: 'other',
        overridesAccountRules: true,
      );
      final m = RepoRule.bestMatchFor('/w/acme/api', [org, folder], remoteUrls: [url]);
      expect(m?.id, 'f');
      // Outside the folder the organization rule is still the default.
      final outside = RepoRule.bestMatchFor('/w/else/api', [org, folder], remoteUrls: [url]);
      expect(outside?.id, 'org');
    });

    test('is written after account rules, before single-project rules', () {
      final folder = RepoRule(
        id: 'f', pathPattern: '/w/acme', profileId: 'other', overridesAccountRules: true);
      final plain = RepoRule(id: 'p', pathPattern: '/w', profileId: 'main');
      final ids = RepoRule.inEmitOrder([folder, org, plain]).map((r) => r.id).toList();
      expect(ids, ['p', 'org', 'f']);
    });

    test('survives a save and load', () {
      final folder = RepoRule(
        id: 'f', pathPattern: '/w/acme', profileId: 'other', overridesAccountRules: true);
      expect(RepoRule.fromJson(folder.toJson()).overridesAccountRules, isTrue);
      expect(RepoRule.fromJson(plainJson).overridesAccountRules, isFalse);
    });
  });
}

final plainJson = {'id': 'x', 'pathPattern': '/w', 'profileId': 'p'};
