import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gita/cli/gita_cli.dart';
import 'package:gita/core/providers.dart';
import 'package:gita/core/services/cli_installer.dart';
import 'package:gita/core/services/path_setup.dart';
import 'package:gita/core/services/platform_paths.dart';
import 'package:path/path.dart' as p;

/// Adding ~/.gita/bin to PATH in shell startup files, always against a
/// temp home folder: the developer's own dotfiles are never touched.
void main() {
  late Directory home;
  late PlatformPaths paths;

  PathSetup setup(String os, {String? packageCommand}) => PathSetup(
        paths: paths,
        operatingSystem: os,
        linuxPackageCommand: packageCommand ?? p.join(home.path, 'no-package', 'gita'),
      );

  String h(String relative) => p.join(home.path, relative);
  File f(String relative) => File(h(relative));

  setUp(() async {
    home = await Directory.systemTemp.createTemp('gita_path_');
    paths = PlatformPaths(overrideHomeDir: home.path);
  });

  tearDown(() async {
    if (await home.exists()) await home.delete(recursive: true);
  });

  group('which startup files', () {
    test('macOS: .zprofile always, plus bash and fish when they are set up', () {
      expect(setup('macos').targetFiles(), [h('.zprofile')]);

      f('.profile').writeAsStringSync('');
      expect(setup('macos').targetFiles(), [h('.zprofile'), h('.profile')]);

      f('.bash_profile').writeAsStringSync('');
      Directory(h('.config/fish')).createSync(recursive: true);
      expect(setup('macos').targetFiles(),
          [h('.zprofile'), h('.bash_profile'), h('.config/fish/conf.d/gita.fish')]);
    });

    test('Linux: .profile (or .bash_profile), plus .bashrc and .zshrc if present', () {
      expect(setup('linux').targetFiles(), [h('.profile')]);

      f('.bashrc').writeAsStringSync('');
      f('.zshrc').writeAsStringSync('');
      f('.bash_profile').writeAsStringSync('');
      expect(setup('linux').targetFiles(), [h('.bash_profile'), h('.bashrc'), h('.zshrc')]);
    });

    test('Windows is left to the installer', () async {
      final s = setup('windows');
      expect(s.targetFiles(), isEmpty);
      expect(s.status().state, PathSetupState.unsupported);
      expect(await s.addOnce(), isNull);
      expect(home.listSync(), isEmpty);
    });

    test('a Linux package that links /usr/bin/gita needs nothing', () async {
      final bundled = File(h('opt/gita/cli/bin/gita'))..createSync(recursive: true);
      final link = Link(h('usr/bin/gita'));
      link.parent.createSync(recursive: true);
      link.createSync(bundled.path);

      final s = setup('linux', packageCommand: link.path);
      expect(s.status().state, PathSetupState.providedElsewhere);
      expect(await s.addOnce(), isNull);
      expect(f('.profile').existsSync(), isFalse);
    });
  });

  group('add and remove', () {
    test('adds a marked block once, after the existing content', () async {
      const original = 'export EDITOR=vim\n';
      f('.zprofile').writeAsStringSync(original);
      final s = setup('macos');
      expect(s.status().state, PathSetupState.notAdded);

      final first = await s.add();
      expect(first.ok, isTrue);
      expect(first.changed, [h('.zprofile')]);
      final text = f('.zprofile').readAsStringSync();
      expect(text, startsWith('$original\n${PathSetup.startMarker}\n'));
      expect(text, endsWith('${PathSetup.endMarker}\n'));
      expect(s.status().state, PathSetupState.added);

      final second = await s.add();
      expect(second.changed, isEmpty);
      expect(f('.zprofile').readAsStringSync(), text);
    });

    test('makes .zprofile when there is none', () async {
      await setup('macos').add();
      expect(f('.zprofile').readAsStringSync(), startsWith(PathSetup.startMarker));
    });

    test('remove gives back the file exactly as it was', () async {
      for (final original in ['export A=1\n', 'export A=1', '', 'a\n\nb\n']) {
        f('.zprofile').writeAsStringSync(original);
        final s = setup('macos');
        await s.add();
        final removed = await s.remove();
        expect(removed.changed, [h('.zprofile')]);
        final back = f('.zprofile').readAsStringSync();
        // A file without a final newline gets one; nothing else changes.
        expect(back, original.isEmpty || original.endsWith('\n') ? original : '$original\n',
            reason: 'original: ${jsonEncode(original)}');
        expect(s.status().state, PathSetupState.notAdded);
      }
    });

    test('remove keeps what the user wrote after the block', () async {
      f('.zprofile').writeAsStringSync('export A=1\n');
      await setup('macos').add();
      f('.zprofile').writeAsStringSync('export B=2\n', mode: FileMode.append);
      await setup('macos').remove();
      expect(f('.zprofile').readAsStringSync(), 'export A=1\nexport B=2\n');
    });

    test('fish gets its own file, deleted again on remove', () async {
      Directory(h('.config/fish')).createSync(recursive: true);
      final s = setup('macos');
      await s.add();
      final fish = f('.config/fish/conf.d/gita.fish');
      expect(fish.readAsStringSync(), contains('set -gx PATH \$PATH \$HOME/.gita/bin'));
      await s.remove();
      expect(fish.existsSync(), isFalse);
    });

    test('a symlinked dotfile stays a symlink, and its target is edited', () async {
      final real = File(h('dotfiles/zprofile'))..createSync(recursive: true);
      real.writeAsStringSync('export A=1\n');
      Link(h('.zprofile')).createSync(real.path);

      await setup('macos').add();
      expect(FileSystemEntity.isLinkSync(h('.zprofile')), isTrue);
      expect(real.readAsStringSync(), contains(PathSetup.startMarker));

      await setup('macos').remove();
      expect(FileSystemEntity.isLinkSync(h('.zprofile')), isTrue);
      expect(real.readAsStringSync(), 'export A=1\n');
    });

    test('keeps the file permissions', () async {
      f('.zprofile').writeAsStringSync('export A=1\n');
      await Process.run('chmod', ['600', h('.zprofile')]);
      await setup('macos').add();
      expect(f('.zprofile').statSync().modeString(), 'rw-------');
    }, skip: Platform.isWindows);

    test('removeBlock leaves text without a block alone', () {
      expect(PathSetup.removeBlock('a\nb\n'), 'a\nb\n');
    });
  });

  group('the app adds it once', () {
    test('first start adds it and remembers; later starts do nothing', () async {
      final s = setup('macos');
      final first = await s.addOnce();
      expect(first?.changed, [h('.zprofile')]);
      expect(File(s.autoMarkerPath).existsSync(), isTrue);

      // The user deletes the block by hand: the app doesn't put it back.
      f('.zprofile').writeAsStringSync('');
      expect(await s.addOnce(), isNull);
      expect(f('.zprofile').readAsStringSync(), '');
    });

    test('after "gita path remove" the app does not add it back', () async {
      final s = setup('macos');
      await s.add();
      await s.remove();
      expect(await s.addOnce(), isNull);
      expect(s.status().state, PathSetupState.notAdded);
      expect(jsonDecode(File(s.autoMarkerPath).readAsStringSync()), contains('removed'));
    });

    test('if it is already there, it just remembers that', () async {
      final s = setup('macos');
      await s.add();
      final before = f('.zprofile').readAsStringSync();
      expect(await s.addOnce(), isNull);
      expect(File(s.autoMarkerPath).existsSync(), isTrue);
      expect(f('.zprofile').readAsStringSync(), before);
    });
  });

  group('real shells find gita after reading the files', () {
    late String binDir;

    setUp(() async {
      binDir = p.dirname(paths.cliPath);
      File(paths.cliPath)
        ..createSync(recursive: true)
        ..writeAsStringSync('#!/bin/sh\necho fake-gita\n');
      await Process.run('chmod', ['+x', paths.cliPath]);
    });

    /// Runs [script] in [shell] with a bare PATH and the temp home.
    Future<String> inShell(String shell, String script) async {
      final r = await Process.run(shell, ['-c', script],
          environment: {'HOME': home.path, 'PATH': '/usr/bin:/bin'}, includeParentEnvironment: false);
      expect(r.exitCode, 0, reason: '$shell: ${r.stderr}');
      return (r.stdout as String).trim();
    }

    bool has(String shell) => Process.runSync('/bin/sh', ['-c', 'command -v $shell']).exitCode == 0;

    for (final (shell, file, os) in [
      ('zsh', '.zprofile', 'macos'),
      ('bash', '.bash_profile', 'macos'),
      ('sh', '.profile', 'linux'),
      ('bash', '.bashrc', 'linux'),
    ]) {
      test('$shell reading $file ($os), even twice', () async {
        if (file != '.zprofile' && file != '.profile') f(file).writeAsStringSync('# mine\n');
        await setup(os).add();
        expect(f(file).readAsStringSync(), contains(PathSetup.startMarker));

        final out = await inShell(shell, '. "\$HOME/$file"; . "\$HOME/$file"; echo "\$PATH"; gita');
        final lines = out.split('\n');
        expect(lines.first, '/usr/bin:/bin:$binDir');
        expect(lines.last, 'fake-gita');
      }, skip: Platform.isWindows || !has(shell) ? 'needs $shell' : false);
    }

    test('fish reading conf.d/gita.fish, even twice', () async {
      Directory(h('.config/fish')).createSync(recursive: true);
      await setup('macos').add();
      final file = h('.config/fish/conf.d/gita.fish');
      final r = await Process.run(
          'fish', ['--no-config', '-c', 'source $file; source $file; string join : \$PATH; gita'],
          environment: {'HOME': home.path, 'PATH': '/usr/bin:/bin'}, includeParentEnvironment: false);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect((r.stdout as String).trim().split('\n'), ['/usr/bin:/bin:$binDir', 'fake-gita']);
    }, skip: Platform.isWindows || !has('fish') ? 'needs fish' : false);

    test('another gita earlier on PATH keeps winning', () async {
      final other = Directory(h('other'))..createSync();
      File(p.join(other.path, 'gita')).writeAsStringSync('#!/bin/sh\necho other-gita\n');
      await Process.run('chmod', ['+x', p.join(other.path, 'gita')]);
      await setup('macos').add();
      final r = await Process.run('/bin/sh', ['-c', '. "\$HOME/.zprofile"; gita'],
          environment: {'HOME': home.path, 'PATH': '${other.path}:/usr/bin:/bin'},
          includeParentEnvironment: false);
      expect((r.stdout as String).trim(), 'other-gita');
    }, skip: Platform.isWindows);
  });

  group('gita path', () {
    late StringBuffer out;
    late StringBuffer err;

    Future<int> run(List<String> args, {String os = 'macos'}) {
      out = StringBuffer();
      err = StringBuffer();
      return GitaCli(out: out, err: err, paths: paths, pathSetup: setup(os)).run(args);
    }

    test('status, add, status again, remove', () async {
      expect(await run(['path']), ExitCodes.problem);
      expect(out.toString(), contains('path add'));

      expect(await run(['path', 'add']), ExitCodes.ok);
      expect(out.toString(), contains('Open a new terminal window'));
      expect(f('.zprofile').readAsStringSync(), contains(PathSetup.startMarker));

      expect(await run(['path', 'add']), ExitCodes.ok);
      expect(out.toString(), contains('Already done'));

      expect(await run(['path', 'status']), ExitCodes.ok);
      expect(out.toString(), contains('New terminals find gita'));

      expect(await run(['path', 'remove']), ExitCodes.ok);
      expect(out.toString(), contains("won't add it back"));
      expect(f('.zprofile').readAsStringSync(), isEmpty);
    });

    test('--json', () async {
      expect(await run(['path', 'add', '--json']), ExitCodes.ok);
      final added = jsonDecode(out.toString()) as Map<String, dynamic>;
      expect(added['ok'], isTrue);
      expect(added['state'], 'added');
      expect(added['changed'], [h('.zprofile')]);

      expect(await run(['path', '--json']), ExitCodes.ok);
      final status = jsonDecode(out.toString()) as Map<String, dynamic>;
      expect(status['state'], 'added');
      expect(status['command'], paths.cliPath);
    });

    test('on Windows it explains and changes nothing', () async {
      expect(await run(['path', 'add'], os: 'windows'), ExitCodes.ok);
      expect(out.toString(), contains('installer'));
      expect(home.listSync(), isEmpty);
    });

    test('a bad action is a usage error', () async {
      expect(await run(['path', 'sideways']), ExitCodes.usage);
      expect(err.toString(), contains('gita path [status|add|remove]'));
    });
  });

  group('app start', () {
    Future<CliInstallResult> start(String bundledDir) async {
      final container = ProviderContainer(overrides: [
        platformPathsProvider.overrideWithValue(paths),
        cliInstallerProvider.overrideWithValue(CliInstaller(paths: paths, bundledDir: bundledDir)),
        pathSetupProvider.overrideWithValue(setup('macos')),
      ]);
      try {
        return await container.read(cliInstallProvider.future);
      } finally {
        container.dispose();
      }
    }

    test('an app that ships the command installs it and adds it to PATH once', () async {
      final bundle = Directory(h('app/cli'));
      File(p.join(bundle.path, 'bin', 'gita'))
        ..createSync(recursive: true)
        ..writeAsStringSync('#!/bin/sh\n');

      expect((await start(bundle.path)).status, CliInstallStatus.installed);
      expect(f('.zprofile').readAsStringSync(), contains(PathSetup.startMarker));

      f('.zprofile').writeAsStringSync('');
      expect((await start(bundle.path)).status, CliInstallStatus.upToDate);
      expect(f('.zprofile').readAsStringSync(), isEmpty);
    });

    test('without a bundled command (like flutter test) no startup file is touched', () async {
      // An older install is there, as on a developer's machine.
      File(paths.cliPath).createSync(recursive: true);
      expect((await start(h('no-bundle'))).status, CliInstallStatus.notBundled);
      expect(f('.zprofile').existsSync(), isFalse);
      expect(File(setup('macos').autoMarkerPath).existsSync(), isFalse);
    });
  });
}
