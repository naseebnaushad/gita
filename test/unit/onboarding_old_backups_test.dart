import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gita/core/onboarding/old_backups.dart';
import 'package:gita/core/onboarding/system.dart';
import 'package:path/path.dart' as p;

class _Reporter implements Reporter {
  final lines = <String>[];
  @override
  void say(String text) => lines.add(text);
  @override
  void note(String text) => lines.add(text);
  @override
  void warn(String text) => lines.add('! $text');
}

class _Prompter implements Prompter {
  _Prompter({required this.interactive, this.answer = true});
  @override
  final bool interactive;
  final bool answer;
  int asked = 0;
  @override
  Future<String> ask(String question, {String defaultValue = ''}) async => defaultValue;
  @override
  Future<bool> confirm(String question, {required bool defaultYes}) async {
    asked++;
    return answer;
  }
}

void main() {
  late Directory home;
  late String gitconfig;
  late String repo;
  final now = DateTime(2026, 11, 9, 12);

  File file(String name) => File(p.join(home.path, name))..writeAsStringSync('x');
  Directory folder(String name) => Directory(p.join(home.path, name))..createSync();
  bool exists(String name) =>
      FileSystemEntity.typeSync(p.join(home.path, name), followLinks: false) != FileSystemEntityType.notFound;

  OldBackups make(_Reporter r, _Prompter q) => OldBackups(reporter: r, prompter: q, now: () => now);

  setUp(() async {
    home = await Directory.systemTemp.createTemp('gita_backups_');
    gitconfig = p.join(home.path, '.gitconfig');
    repo = p.join(home.path, 'handbook');
    file('.gitconfig');
    file('.gitconfig.backup-20250101-090000');
    file('.gitconfig.backup-20260301-090000');
    file('.gitconfig.backup-20260301-090000-2');
    file('.gitconfig.backup-20261105-090000'); // younger than 30 days
    file('.gitconfig.backup-20261106-090000'); // newest
    folder('handbook');
    folder('handbook.backup-20260101-120000');
    folder('handbook.backup-20260601-120000'); // newest of the folders, old but kept
    file('.gitconfig.backup-notadate');
    file('other.backup-20200101-000000');
  });

  tearDown(() => home.delete(recursive: true));

  test('finds only old, not-newest backups of the given paths, oldest first', () {
    final old = make(_Reporter(), _Prompter(interactive: true)).find([gitconfig, repo]);
    expect(old.map((b) => p.basename(b.path)), [
      '.gitconfig.backup-20250101-090000',
      '.gitconfig.backup-20260301-090000',
      '.gitconfig.backup-20260301-090000-2',
      'handbook.backup-20260101-120000',
    ]);
    expect(old.last.isFolder, isTrue);
  });

  test('a single backup is never offered, however old', () {
    for (final f in home.listSync()) {
      if (p.basename(f.path).startsWith('.gitconfig.backup-2026')) f.deleteSync();
    }
    final old = make(_Reporter(), _Prompter(interactive: true)).find([gitconfig]);
    expect(old, isEmpty, reason: 'only .gitconfig.backup-20250101 is left, and it is the newest');
  });

  test('asked and answered yes: deletes them, keeps the newest and the young ones', () async {
    final r = _Reporter();
    final q = _Prompter(interactive: true);
    final summary = await make(r, q).run([gitconfig, repo], dryRun: false, yes: false);

    expect(summary, 'deleted 4');
    expect(q.asked, 1);
    expect(exists('.gitconfig.backup-20250101-090000'), isFalse);
    expect(exists('handbook.backup-20260101-120000'), isFalse);
    for (final kept in [
      '.gitconfig',
      '.gitconfig.backup-20261105-090000',
      '.gitconfig.backup-20261106-090000',
      'handbook',
      'handbook.backup-20260601-120000',
      '.gitconfig.backup-notadate',
      'other.backup-20200101-000000',
    ]) {
      expect(exists(kept), isTrue, reason: kept);
    }
    expect(r.lines.join('\n'), contains('can still hold GitHub tokens'));
  });

  test('no terminal: lists them and deletes nothing', () async {
    final summary = await make(
      _Reporter(),
      _Prompter(interactive: false),
    ).run([gitconfig, repo], dryRun: false, yes: false);
    expect(summary, 'kept (4; no terminal to ask)');
    expect(exists('.gitconfig.backup-20250101-090000'), isTrue);
  });

  test('answered no keeps them; --yes deletes without asking; dry run changes nothing', () async {
    expect(
      await make(_Reporter(), _Prompter(interactive: true, answer: false)).run([gitconfig], dryRun: false, yes: false),
      'kept (3)',
    );
    expect(await make(_Reporter(), _Prompter(interactive: false)).run([gitconfig], dryRun: true, yes: true), 'dry run');
    expect(exists('.gitconfig.backup-20250101-090000'), isTrue);
    final q = _Prompter(interactive: false);
    expect(await make(_Reporter(), q).run([gitconfig], dryRun: false, yes: true), 'deleted 3');
    expect(q.asked, 0);
  });

  test('nothing old gives "none"', () async {
    expect(
      await make(
        _Reporter(),
        _Prompter(interactive: true),
      ).run([p.join(home.path, 'nothing')], dryRun: false, yes: false),
      'none',
    );
  });

  test('a backup that is a link is removed as a link, never followed', () async {
    final outside = await Directory.systemTemp.createTemp('gita_backups_outside_');
    addTearDown(() => outside.delete(recursive: true));
    File(p.join(outside.path, 'keep.txt')).writeAsStringSync('keep');
    try {
      Link(p.join(home.path, 'handbook.backup-20250101-000000')).createSync(outside.path);
    } on FileSystemException {
      markTestSkipped('this system does not allow creating links');
      return;
    }

    await make(_Reporter(), _Prompter(interactive: true)).run([repo], dryRun: false, yes: true);

    expect(exists('handbook.backup-20250101-000000'), isFalse);
    expect(File(p.join(outside.path, 'keep.txt')).existsSync(), isTrue, reason: 'the link target is untouched');
  });
}
