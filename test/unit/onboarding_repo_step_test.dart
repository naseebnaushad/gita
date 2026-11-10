import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gita/core/onboarding/repo_step.dart';
import 'package:gita/core/onboarding/system.dart';

const _url = 'https://github.com/acme/handbook.git';

/// Runs real programs, but git only sees the test's own global config.
class _IsolatedRunner implements CommandRunner {
  _IsolatedRunner(this.globalConfig);

  final String globalConfig;
  final calls = <List<String>>[];

  @override
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    CommandIo io = CommandIo.capture,
    Map<String, String?> environment = const {},
    String? workingDirectory,
    String? stdinText,
    Duration timeout = const Duration(minutes: 2),
  }) {
    calls.add([executable, ...arguments]);
    return const SystemCommandRunner().run(
      executable,
      arguments,
      io: io,
      environment: {
        ...environment,
        'GIT_CONFIG_GLOBAL': globalConfig,
        'GIT_CONFIG_NOSYSTEM': '1',
        'GIT_TERMINAL_PROMPT': '0',
      },
      workingDirectory: workingDirectory,
      stdinText: stdinText,
      timeout: timeout,
    );
  }
}

class _Recorder implements Reporter {
  final lines = <String>[];
  final warnings = <String>[];

  @override
  void say(String text) => lines.add('say: $text');

  @override
  void note(String text) => lines.add('note: $text');

  @override
  void warn(String text) {
    lines.add('warn: $text');
    warnings.add(text);
  }
}

void main() {
  late Directory root;
  late _IsolatedRunner runner;
  late _Recorder reporter;
  late String bare;
  late String seed;
  late String dir;
  var cloneCalls = 0;

  Future<CommandResult> git(List<String> args) async {
    final r = await runner.run('git', args);
    if (!r.ok) fail('git ${args.join(' ')} failed: ${r.stderr}');
    return r;
  }

  String p(String name) => '${root.path}${Platform.pathSeparator}$name';

  Future<void> commit(String repo, String file, String text) async {
    File('$repo${Platform.pathSeparator}$file').writeAsStringSync(text);
    await git(['-C', repo, 'add', '-A']);
    await git(['-C', repo, 'commit', '-q', '-m', 'change $file']);
  }

  Future<String> head(String repo) async => (await git(['-C', repo, 'rev-parse', 'HEAD'])).stdout.trim();

  /// Clones the bare "origin" like Gita's clone service would clone GitHub.
  Future<bool> goodClone() async {
    cloneCalls++;
    final r = await runner.run('git', ['clone', '-q', bare, dir]);
    if (!r.ok) return false;
    await git(['-C', dir, 'remote', 'set-url', 'origin', _url]);
    return true;
  }

  /// Leaves a partial folder behind and reports failure.
  Future<bool> badClone() async {
    cloneCalls++;
    Directory('$dir${Platform.pathSeparator}.git').createSync(recursive: true);
    File('$dir${Platform.pathSeparator}.git${Platform.pathSeparator}HEAD').writeAsStringSync('partial');
    return false;
  }

  RepoEnsurer ensurer({bool dryRun = false}) =>
      RepoEnsurer(runner: runner, reporter: reporter, now: () => DateTime(2026, 3, 4, 5, 6, 7), dryRun: dryRun);

  Future<RepoOutcome> ensure({
    bool dryRun = false,
    Future<bool> Function()? clone,
    Future<bool> Function()? offerRetry,
    String url = _url,
    String? problem,
    List<String> needs = const [],
  }) => ensurer(dryRun: dryRun).ensure(
    url: url,
    dir: dir,
    name: 'handbook',
    profileLabel: 'Acme',
    profileLogin: 'jdoe-acme',
    accountEmail: 'jdoe@acme.example',
    orgName: 'acme',
    clone: clone ?? goodClone,
    offerRetry: offerRetry,
    cloneProblem: () => problem,
    needs: needs,
  );

  setUp(() async {
    root = Directory.systemTemp.createTempSync('gita_repo_step_');
    final cfg = p('.gitconfig');
    File(cfg).writeAsStringSync('');
    runner = _IsolatedRunner(cfg);
    reporter = _Recorder();
    cloneCalls = 0;
    bare = p('origin.git').replaceAll('\\', '/');
    seed = p('seed');
    dir = p('handbook');
    await git(['config', '--global', 'user.name', 'Test User']);
    await git(['config', '--global', 'user.email', 'test@example.invalid']);
    await git(['config', '--global', 'init.defaultBranch', 'main']);
    await git(['config', '--global', 'url.$bare.insteadOf', _url]);
    await git(['init', '-q', '--bare', bare]);
    await git(['clone', '-q', bare, seed]);
    await commit(seed, 'README.md', 'first');
    await git(['-C', seed, 'push', '-q', 'origin', 'HEAD:main']);
  });

  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort: a virus scanner may still hold a file on Windows.
    }
  });

  List<String> backups() =>
      root
          .listSync()
          .map((e) => e.path.split(Platform.pathSeparator).last)
          .where((n) => n.contains('.backup-'))
          .toList()
        ..sort();

  group('normaliseUrl', () {
    test('treats https, ssh and scp forms of the same repo alike', () {
      const want = 'github.com/acme/handbook';
      expect(RepoEnsurer.normaliseUrl('https://github.com/acme/handbook.git'), want);
      expect(RepoEnsurer.normaliseUrl('https://github.com/Acme/Handbook/'), want);
      expect(RepoEnsurer.normaliseUrl('http://user@github.com/acme/handbook'), want);
      expect(RepoEnsurer.normaliseUrl('git@github.com:Acme/Handbook'), want);
      expect(RepoEnsurer.normaliseUrl('git@github.com:acme/handbook.git'), want);
      expect(RepoEnsurer.normaliseUrl('ssh://git@github.com/acme/handbook.git'), want);
      expect(RepoEnsurer.normaliseUrl('git://github.com/acme/handbook.git'), want);
      expect(RepoEnsurer.normaliseUrl('  https://github.com/acme/handbook.git\n'), want);
    });

    test('keeps different projects apart', () {
      expect(RepoEnsurer.normaliseUrl('https://github.com/acme/other.git'), isNot('github.com/acme/handbook'));
      expect(RepoEnsurer.normaliseUrl(''), '');
    });
  });

  test('missing folder: downloaded', () async {
    final r = await ensure();
    expect(r.summary, 'downloaded');
    expect(r.failed, isFalse);
    expect(File('$dir${Platform.pathSeparator}README.md').readAsStringSync(), 'first');
    expect(cloneCalls, 1);
  });

  test('clean copy: updated and picks up a new commit', () async {
    await goodClone();
    await commit(seed, 'NEW.md', 'second');
    await git(['-C', seed, 'push', '-q', 'origin', 'HEAD:main']);
    final r = await ensure();
    expect(r.summary, 'updated');
    expect(await head(dir), await head(seed));
    expect(reporter.warnings, isEmpty);
    expect(cloneCalls, 1);
    final pull = runner.calls.firstWhere((c) => c.contains('pull'));
    expect(pull, containsAllInOrder(['-c', 'http.lowSpeedLimit=1000', 'pull', '--ff-only', '-q']));
  });

  test('origin in SSH form counts as the same project', () async {
    await goodClone();
    await git(['-C', dir, 'remote', 'set-url', 'origin', 'git@github.com:Acme/Handbook']);
    // Point the SSH address at the local origin too, so the test stays offline.
    await git(['config', '--global', '--add', 'url.$bare.insteadOf', 'git@github.com:Acme/Handbook']);
    final r = await ensure();
    expect(r.summary, 'updated');
    expect(backups(), isEmpty);
  });

  test('local changes: kept with a warning', () async {
    await goodClone();
    File('$dir${Platform.pathSeparator}README.md').writeAsStringSync('edited');
    final r = await ensure();
    expect(r.summary, 'kept (local changes)');
    expect(reporter.warnings.single, contains('has local changes'));
    expect(File('$dir${Platform.pathSeparator}README.md').readAsStringSync(), 'edited');
  });

  test('empty folder: moved aside and downloaded', () async {
    Directory(dir).createSync();
    final r = await ensure();
    expect(r.summary, 'downloaded');
    expect(backups(), ['handbook.backup-20260304-050607']);
    expect(
      reporter.warnings.first,
      '$dir is empty. Moving it to $dir.backup-20260304-050607 and downloading a fresh copy.',
    );
  });

  test('folder that is not a git copy: moved aside with contents, unique names', () async {
    Directory('$dir.backup-20260304-050607').createSync();
    Directory(dir).createSync();
    File('$dir${Platform.pathSeparator}notes.txt').writeAsStringSync('keep me');
    final r = await ensure();
    expect(r.summary, 'downloaded');
    expect(backups(), ['handbook.backup-20260304-050607', 'handbook.backup-20260304-050607-2']);
    expect(File('$dir.backup-20260304-050607-2${Platform.pathSeparator}notes.txt').readAsStringSync(), 'keep me');
    expect(reporter.warnings.first, contains('is not a git copy'));
  });

  test('a file where the folder should be: moved aside', () async {
    File(dir).writeAsStringSync('a file');
    final r = await ensure();
    expect(r.summary, 'downloaded');
    expect(File('$dir.backup-20260304-050607').readAsStringSync(), 'a file');
    expect(reporter.warnings.first, contains('is not a folder'));
  });

  test('copy of a different project: moved aside and downloaded', () async {
    await goodClone();
    await git(['-C', dir, 'remote', 'set-url', 'origin', 'https://github.com/acme/other.git']);
    final r = await ensure();
    expect(r.summary, 'downloaded');
    expect(reporter.warnings.first, contains('is a copy of a different project'));
    final backup = '$dir.backup-20260304-050607';
    expect(File('$backup${Platform.pathSeparator}README.md').existsSync(), isTrue);
    expect((await git(['-C', dir, 'config', '--get', 'remote.origin.url'])).stdout.trim(), _url);
  });

  test('diverged copy: kept (update failed), local commit kept, no git hints', () async {
    await goodClone();
    await commit(dir, 'LOCAL.md', 'mine');
    final local = await head(dir);
    await commit(seed, 'NEW.md', 'theirs');
    await git(['-C', seed, 'push', '-q', 'origin', 'HEAD:main']);
    final r = await ensure();
    expect(r.summary, 'kept (update failed)');
    expect(r.failed, isFalse);
    expect(await head(dir), local);
    expect(reporter.warnings.last, "Couldn't update handbook (the message above says why). Using the copy you have.");
    expect(reporter.lines.where((l) => l.contains('hint:')), isEmpty);
    expect(reporter.lines.where((l) => l.startsWith('note: ')), isNotEmpty, reason: "git's reason is passed on");
  });

  test('clone fails: partial folder removed, causes in order, failed', () async {
    final r = await ensure(clone: badClone);
    expect(r.summary, 'failed');
    expect(r.failed, isTrue);
    expect(r.hint, 'Check the causes listed above, then run this again.');
    expect(FileSystemEntity.typeSync(dir), FileSystemEntityType.notFound);
    expect(reporter.warnings.last, "Couldn't download handbook. Likely causes:");
    final text = reporter.lines.join('\n');
    final i1 = text.indexOf("1. The organization acme hasn't approved the Gita app yet");
    final i2 = text.indexOf('2. The profile "Acme" is signed in as @jdoe-acme');
    final i3 = text.indexOf("3. Your account hasn't been added to acme yet");
    final i4 = text.indexOf('4. No connection to github.com.');
    expect([i1, i2, i3, i4].every((i) => i >= 0), isTrue, reason: text);
    expect(i1 < i2 && i2 < i3 && i3 < i4, isTrue);
    expect(text, contains('Authorized OAuth Apps > Gita'));
    expect(text, contains('jdoe@acme.example'));
    expect(cloneCalls, 1);
  });

  test('clone fails with no login known: says @unknown', () async {
    await ensurer().ensure(
      url: _url,
      dir: dir,
      name: 'handbook',
      profileLabel: 'Acme',
      profileLogin: null,
      accountEmail: 'jdoe@acme.example',
      orgName: 'acme',
      clone: badClone,
    );
    expect(reporter.lines.join('\n'), contains('signed in as @unknown'));
  });

  test('clone fails, retry accepted, second clone works: downloaded', () async {
    var asked = 0;
    var first = true;
    final r = await ensure(
      clone: () async {
        if (first) {
          first = false;
          return badClone();
        }
        return goodClone();
      },
      offerRetry: () async {
        asked++;
        return true;
      },
    );
    expect(r.summary, 'downloaded');
    expect(asked, 1);
    expect(cloneCalls, 2);
  });

  test('clone fails twice: retry offered only once', () async {
    var asked = 0;
    final r = await ensure(
      clone: badClone,
      offerRetry: () async {
        asked++;
        return true;
      },
    );
    expect(r.summary, 'failed');
    expect(asked, 1);
    expect(cloneCalls, 2);
    expect(FileSystemEntity.typeSync(dir), FileSystemEntityType.notFound);
  });

  test("clone fails because Gita's helper did not run: says so, no org causes, no retry offered", () async {
    var asked = 0;
    final r = await ensure(
      clone: badClone,
      problem: 'helper',
      offerRetry: () async {
        asked++;
        return true;
      },
    );
    expect(r.summary, 'failed');
    expect(asked, 0, reason: 'signing in again would not help');
    expect(cloneCalls, 1);
    final text = reporter.lines.join('\n');
    expect(text, contains('git never got a sign-in from Gita'));
    expect(text, contains('gita doctor --fix'));
    expect(text, isNot(contains('approved the Gita app')));
  });

  test('clone fails on the SSH key: says so, no retry offered', () async {
    var asked = 0;
    final r = await ensure(
      clone: badClone,
      problem: 'sshKey',
      offerRetry: () async {
        asked++;
        return true;
      },
    );
    expect(r.summary, 'failed');
    expect(asked, 0);
    expect(reporter.warnings.join('\n'), contains("didn't accept the SSH key"));
  });

  test('clone fails on the sign-in: organization approval listed, retry offered', () async {
    var asked = 0;
    await ensure(
      clone: badClone,
      problem: 'signIn',
      offerRetry: () async {
        asked++;
        return false;
      },
    );
    expect(asked, 1);
    expect(reporter.lines.join('\n'), contains("hasn't approved the Gita app"));
  });

  test('clone fails, retry declined: failed after one try', () async {
    final r = await ensure(clone: badClone, offerRetry: () async => false);
    expect(r.summary, 'failed');
    expect(cloneCalls, 1);
  });

  group('repair: a copy missing files later steps need', () {
    const needed = 'gita/acme.json';
    String sep(String rel) => rel.replaceAll('/', Platform.pathSeparator);

    /// The person's copy was made before origin got [needed].
    Future<void> oldCopy() async {
      await goodClone();
      Directory('$seed${Platform.pathSeparator}gita').createSync();
      await commit(seed, sep(needed), '{}');
      await git(['-C', seed, 'push', '-q', 'origin', 'HEAD:main']);
    }

    test('local changes and a needed file missing: moved aside, downloaded again, changes kept', () async {
      await oldCopy();
      File('$dir${Platform.pathSeparator}README.md').writeAsStringSync('edited');
      final r = await ensure(needs: [needed]);
      expect(r.summary, 'downloaded again (old copy in handbook.backup-20260304-050607)');
      expect(r.failed, isFalse);
      expect(File('$dir${Platform.pathSeparator}${sep(needed)}').existsSync(), isTrue);
      expect(File('$dir${Platform.pathSeparator}README.md').readAsStringSync(), 'first');
      final backup = '$dir.backup-20260304-050607';
      expect(File('$backup${Platform.pathSeparator}README.md').readAsStringSync(), 'edited');
      expect(
        reporter.warnings.first,
        '$dir is missing $needed, which setup needs (an old or incomplete copy). '
        'Moving it to $backup and downloading a fresh copy.',
      );
      expect(reporter.lines, contains('note: Your local changes are kept in $backup.'));
      expect(cloneCalls, 2);
    });

    test('local changes and every needed file there: kept, as before', () async {
      await goodClone();
      File('$dir${Platform.pathSeparator}README.md').writeAsStringSync('edited');
      final r = await ensure(needs: ['README.md']);
      expect(r.summary, 'kept (local changes)');
      expect(backups(), isEmpty);
      expect(cloneCalls, 1);
    });

    test('clean old copy that the update fixes: updated, not moved', () async {
      await oldCopy();
      final r = await ensure(needs: [needed]);
      expect(r.summary, 'updated');
      expect(File('$dir${Platform.pathSeparator}${sep(needed)}').existsSync(), isTrue);
      expect(backups(), isEmpty);
      expect(cloneCalls, 1);
    });

    test('diverged copy missing a needed file: moved aside with its commit, downloaded again', () async {
      await oldCopy();
      await commit(dir, 'LOCAL.md', 'mine');
      final r = await ensure(needs: [needed]);
      expect(r.summary, 'downloaded again (old copy in handbook.backup-20260304-050607)');
      expect(File('$dir${Platform.pathSeparator}${sep(needed)}').existsSync(), isTrue);
      expect(File('$dir.backup-20260304-050607${Platform.pathSeparator}LOCAL.md').existsSync(), isTrue);
      expect(reporter.lines, contains('note: Anything you changed in it is kept in $dir.backup-20260304-050607.'));
    });

    test('download fails after the move: failed, the backup stays', () async {
      await oldCopy();
      File('$dir${Platform.pathSeparator}README.md').writeAsStringSync('edited');
      final r = await ensure(needs: [needed], clone: badClone);
      expect(r.failed, isTrue);
      expect(backups(), ['handbook.backup-20260304-050607']);
      expect(FileSystemEntity.typeSync(dir), FileSystemEntityType.notFound);
    });

    test('dry run: says what it would do, changes nothing', () async {
      await oldCopy();
      File('$dir${Platform.pathSeparator}README.md').writeAsStringSync('edited');
      final calls = cloneCalls;
      final r = await ensure(needs: [needed], dryRun: true);
      expect(r.summary, 'dry run');
      expect(backups(), isEmpty);
      expect(File('$dir${Platform.pathSeparator}README.md').readAsStringSync(), 'edited');
      expect(cloneCalls, calls);
      expect(reporter.lines.where((l) => l.contains('[dry run] would move')), hasLength(1));
    });
  });

  group('dry run changes nothing', () {
    test('missing folder', () async {
      final r = await ensure(dryRun: true);
      expect(r.summary, 'dry run');
      expect(cloneCalls, 0);
      expect(FileSystemEntity.typeSync(dir), FileSystemEntityType.notFound);
    });

    test('clean copy', () async {
      await goodClone();
      final before = await head(dir);
      await commit(seed, 'NEW.md', 'second');
      await git(['-C', seed, 'push', '-q', 'origin', 'HEAD:main']);
      final r = await ensure(dryRun: true);
      expect(r.summary, 'dry run');
      expect(await head(dir), before);
      expect(runner.calls.where((c) => c.contains('pull')), isEmpty);
    });

    test('folder to move aside', () async {
      Directory(dir).createSync();
      File('$dir${Platform.pathSeparator}notes.txt').writeAsStringSync('x');
      final r = await ensure(dryRun: true);
      expect(r.summary, 'dry run');
      expect(backups(), isEmpty);
      expect(File('$dir${Platform.pathSeparator}notes.txt').existsSync(), isTrue);
      expect(cloneCalls, 0);
    });
  });
}
