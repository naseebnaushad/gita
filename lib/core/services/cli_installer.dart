import 'dart:io';

import 'package:path/path.dart' as p;

import 'platform_paths.dart';

enum CliInstallStatus {
  /// The command wasn't on this computer and now is.
  installed,

  /// An older copy was replaced with the one this app ships.
  updated,

  /// The installed copy already matches.
  upToDate,

  /// This copy of the app doesn't ship the command (e.g. a macOS build, or
  /// a build made without the CMake step). Nothing was changed.
  notBundled,

  /// Copying failed; [CliInstallResult.message] says why.
  failed,
}

class CliInstallResult {
  const CliInstallResult(this.status, {this.message});

  final CliInstallStatus status;
  final String? message;

  /// Whether files under ~/.gita changed, so git settings that depend on
  /// the command being present should be rewritten.
  bool get changed =>
      status == CliInstallStatus.installed || status == CliInstallStatus.updated;

  @override
  String toString() => 'CliInstallResult($status${message == null ? '' : ': $message'})';
}

/// Copies the `gita` command that ships inside the app to ~/.gita, where
/// git runs it as the HTTPS credential helper.
///
/// The app bundle has a `cli` folder laid out like `dart build cli` output
/// (`bin/gita[.exe]`, optional `lib/`). Its `bin` and `lib` folders are
/// mirrored to `~/.gita/bin` and `~/.gita/lib`, so the installed path
/// never depends on where the app itself was installed.
class CliInstaller {
  CliInstaller({required this.paths, String? bundledDir})
      : bundledDir = bundledDir ?? defaultBundledDir();

  final PlatformPaths paths;

  /// The app's `cli` folder.
  final String bundledDir;

  static const _mirroredDirs = ['bin', 'lib'];

  /// Where the build puts the command: `<app folder>/cli` on Windows and
  /// Linux, `Gita.app/Contents/Resources/cli` on macOS.
  static String defaultBundledDir() {
    final exeDir = p.dirname(Platform.resolvedExecutable);
    if (Platform.isMacOS) return p.normalize(p.join(exeDir, '..', 'Resources', 'cli'));
    return p.join(exeDir, 'cli');
  }

  Future<CliInstallResult> install() async {
    final bundledExe = File(p.join(bundledDir, 'bin', p.basename(paths.cliPath)));
    if (!bundledExe.existsSync()) {
      return const CliInstallResult(CliInstallStatus.notBundled);
    }
    final hadCommand = File(paths.cliPath).existsSync();

    try {
      final changedFiles = <String>[];
      for (final dir in _mirroredDirs) {
        final source = Directory(p.join(bundledDir, dir));
        if (!source.existsSync()) continue;
        await for (final entity in source.list(recursive: true)) {
          if (entity is! File) continue;
          final relative = p.relative(entity.path, from: bundledDir);
          final target = File(p.join(paths.gitaDir, relative));
          // A copy moved aside by an earlier update, once nothing runs it.
          _tryDelete(File('${target.path}.old'));
          if (await _sameContent(entity, target)) continue;
          await _replace(entity, target);
          changedFiles.add(relative);
        }
      }
      if (changedFiles.isEmpty) return const CliInstallResult(CliInstallStatus.upToDate);
      return CliInstallResult(
          hadCommand ? CliInstallStatus.updated : CliInstallStatus.installed);
    } on FileSystemException catch (e) {
      return CliInstallResult(CliInstallStatus.failed,
          message: "Couldn't copy the gita command to ${paths.gitaDir}: "
              '${e.message}${e.path == null ? '' : ' (${e.path})'}');
    }
  }

  static Future<bool> _sameContent(File a, File b) async {
    if (!b.existsSync()) return false;
    if (await a.length() != await b.length()) return false;
    final bytesA = await a.readAsBytes();
    final bytesB = await b.readAsBytes();
    for (var i = 0; i < bytesA.length; i++) {
      if (bytesA[i] != bytesB[i]) return false;
    }
    return true;
  }

  /// Puts [source]'s content at [target] without ever leaving a half-written
  /// file there. On Windows a program that is running (git may be running
  /// the credential helper right now) can't be overwritten but can be
  /// renamed, so the old copy is moved aside first and removed later.
  static Future<void> _replace(File source, File target) async {
    await target.parent.create(recursive: true);
    final staged = File('${target.path}.new');
    await source.copy(staged.path);
    if (!Platform.isWindows) {
      final mode = (await source.stat()).mode & 0x1ff;
      await Process.run('chmod', [mode.toRadixString(8), staged.path]);
    }

    final old = File('${target.path}.old');
    _tryDelete(old);
    if (target.existsSync()) {
      if (Platform.isWindows) {
        await target.rename(old.path);
      }
    }
    // On macOS and Linux rename replaces the target in one step, even while
    // it is running.
    await staged.rename(target.path);
    _tryDelete(old);
  }

  static void _tryDelete(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // Still in use; it is removed on a later start.
    }
  }
}
