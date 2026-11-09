import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'platform_paths.dart';

/// Where the `gita` command stands with respect to the user's PATH.
enum PathSetupState {
  /// Gita's block is in the shell startup files: new terminals find `gita`.
  added,

  /// Not set up yet: `gita` only works by its full path.
  notAdded,

  /// Something else already puts `gita` on PATH (a Linux package's
  /// /usr/bin/gita, or the Windows installer). Nothing to do.
  providedElsewhere,

  /// This platform isn't handled here (Windows: the installer offers it).
  unsupported,
}

class PathSetupStatus {
  const PathSetupStatus(this.state, {this.files = const [], this.note});

  final PathSetupState state;

  /// The startup files that have Gita's block (for [PathSetupState.added]),
  /// or that `add` would write to (for [PathSetupState.notAdded]).
  final List<String> files;

  /// A sentence for people: what's going on, or what to do.
  final String? note;

  Map<String, Object?> toJson() => {
        'state': state.name,
        'files': files,
        if (note != null) 'note': note,
      };
}

class PathSetupResult {
  const PathSetupResult({required this.changed, required this.files, this.error});

  /// Startup files that were written (added to, or had the block removed).
  final List<String> changed;

  /// All the startup files involved, changed or not.
  final List<String> files;

  /// Set when a file couldn't be written; the others were still handled.
  final String? error;

  bool get ok => error == null;
}

/// Adds `~/.gita/bin` to PATH for new terminals, on macOS and Linux, by
/// putting a marked block in the user's shell startup files:
///
/// - zsh: `~/.zprofile` on macOS (where Terminal opens login shells; made
///   if missing), `~/.zshrc` on Linux if it exists.
/// - bash: `~/.bash_profile`, or else `~/.profile` (made on Linux if
///   neither exists), plus `~/.bashrc` on Linux if it exists.
/// - fish: `~/.config/fish/conf.d/gita.fish`, if fish is set up.
///
/// The block appends to PATH and only if `~/.gita/bin` isn't there yet, so
/// sourcing a file twice is harmless and another program called `gita`
/// earlier on PATH keeps winning. Files are edited in place, so dotfiles
/// that are symlinks keep pointing where they did.
///
/// The app adds it once, on its own; [autoMarkerPath] remembers that, so a
/// block the user deleted isn't put back. `gita path add` always adds it.
class PathSetup {
  PathSetup({
    required this.paths,
    String? operatingSystem,
    this.linuxPackageCommand = '/usr/bin/gita',
  }) : operatingSystem = operatingSystem ?? Platform.operatingSystem;

  final PlatformPaths paths;

  /// `macos`, `linux`, `windows`, ... ([Platform.operatingSystem]).
  final String operatingSystem;

  /// Where the Linux packages (.deb, .rpm, Arch) put the command.
  final String linuxPackageCommand;

  static const startMarker = '# >>> gita >>>';
  static const endMarker = '# <<< gita <<<';

  bool get _isMac => operatingSystem == 'macos';
  bool get _isLinux => operatingSystem == 'linux';

  String get _home => paths.homeDir();
  String _inHome(String relative) => p.join(_home, relative);

  /// Remembers that the app already added the block once.
  String get autoMarkerPath => p.join(paths.gitaDir, 'path-setup.json');

  String get binDir => p.dirname(paths.cliPath);

  static const _posixBlock = '''
$startMarker
# Added by Gita so the `gita` command works in new terminals.
# To undo: run `gita path remove`, or delete this block.
case ":\$PATH:" in
  *":\$HOME/.gita/bin:"*) ;;
  *) export PATH="\$PATH:\$HOME/.gita/bin" ;;
esac
$endMarker
''';

  static const _fishBlock = '''
$startMarker
# Added by Gita so the `gita` command works in new terminals.
# To undo: run `gita path remove`, or delete this file.
if not contains -- \$HOME/.gita/bin \$PATH
    set -gx PATH \$PATH \$HOME/.gita/bin
end
$endMarker
''';

  String get _fishFile => _inHome(p.join('.config', 'fish', 'conf.d', 'gita.fish'));

  /// The startup files Gita writes to on this computer, existing or to be
  /// made, in a stable order.
  List<String> targetFiles() {
    if (!_isMac && !_isLinux) return const [];
    bool exists(String relative) => File(_inHome(relative)).existsSync();
    final files = <String>[];
    if (_isMac) {
      files.add(_inHome('.zprofile'));
      if (exists('.bash_profile')) {
        files.add(_inHome('.bash_profile'));
      } else if (exists('.profile')) {
        files.add(_inHome('.profile'));
      }
    } else {
      files.add(_inHome(exists('.bash_profile') ? '.bash_profile' : '.profile'));
      if (exists('.bashrc')) files.add(_inHome('.bashrc'));
      if (exists('.zshrc')) files.add(_inHome('.zshrc'));
    }
    if (Directory(_inHome(p.join('.config', 'fish'))).existsSync()) files.add(_fishFile);
    return files;
  }

  bool _hasBlock(String file) {
    try {
      return File(file).readAsStringSync().contains(startMarker);
    } on FileSystemException {
      return false;
    }
  }

  bool get _providedElsewhere {
    if (!_isLinux) return false;
    final link = File(linuxPackageCommand);
    if (!link.existsSync()) return false;
    try {
      return link.resolveSymbolicLinksSync().endsWith(p.join('cli', 'bin', 'gita'));
    } on FileSystemException {
      return false;
    }
  }

  PathSetupStatus status() {
    if (!_isMac && !_isLinux) {
      return const PathSetupStatus(PathSetupState.unsupported,
          note: 'On Windows, the Gita installer offers to add the gita command to PATH.');
    }
    if (_providedElsewhere) {
      return PathSetupStatus(PathSetupState.providedElsewhere,
          note: 'The installed package already provides $linuxPackageCommand.');
    }
    final targets = targetFiles();
    final withBlock = [
      for (final f in {...targets, ..._allKnownFiles()})
        if (_hasBlock(f)) f,
    ];
    if (withBlock.isNotEmpty) {
      return PathSetupStatus(PathSetupState.added,
          files: withBlock, note: 'New terminals find gita. Open a new terminal window if this one doesn\'t.');
    }
    return PathSetupStatus(PathSetupState.notAdded,
        files: targets, note: 'gita only works by its full path: ${paths.cliPath}');
  }

  /// Every file Gita might have written to on any run, so `remove` and
  /// `status` find blocks even if the user's shells changed since.
  List<String> _allKnownFiles() => [
        for (final f in ['.zprofile', '.zshrc', '.bash_profile', '.profile', '.bashrc']) _inHome(f),
        _fishFile,
      ];

  /// Adds the block to every target file that doesn't have it yet.
  Future<PathSetupResult> add() async {
    final targets = targetFiles();
    final changed = <String>[];
    String? error;
    for (final path in targets) {
      if (_hasBlock(path)) continue;
      final file = File(path);
      final block = path == _fishFile ? _fishBlock : _posixBlock;
      try {
        await file.parent.create(recursive: true);
        var prefix = '';
        if (file.existsSync()) {
          final current = await file.readAsString();
          if (current.isNotEmpty) prefix = current.endsWith('\n') ? '\n' : '\n\n';
        }
        // Appending writes through a symlinked dotfile and keeps its mode.
        await file.writeAsString('$prefix$block', mode: FileMode.append, flush: true);
        changed.add(path);
      } on FileSystemException catch (e) {
        error ??= "Couldn't write $path: ${e.message}";
      }
    }
    return PathSetupResult(changed: changed, files: targets, error: error);
  }

  /// Takes Gita's block out of every startup file that has it.
  Future<PathSetupResult> remove() async {
    final changed = <String>[];
    String? error;
    for (final path in _allKnownFiles()) {
      if (!_hasBlock(path)) continue;
      final file = File(path);
      try {
        final updated = removeBlock(await file.readAsString());
        if (path == _fishFile && updated.trim().isEmpty) {
          await file.delete();
        } else {
          // In place (not write-and-rename), for symlinked dotfiles.
          await file.writeAsString(updated, flush: true);
        }
        changed.add(path);
      } on FileSystemException catch (e) {
        error ??= "Couldn't write $path: ${e.message}";
      }
    }
    // The user chose not to have it: the app mustn't add it back.
    await _writeMarker(const [], removed: true);
    return PathSetupResult(changed: changed, files: changed, error: error);
  }

  /// [text] without Gita's block (and the blank line [add] put before it).
  static String removeBlock(String text) {
    final pattern = RegExp(
      r'\n?' + RegExp.escape(startMarker) + r'.*?' + RegExp.escape(endMarker) + r'\n?',
      dotAll: true,
    );
    return text.replaceAll(pattern, '');
  }

  /// What the app runs at startup: adds the block the first time only.
  /// Returns null when nothing was done.
  Future<PathSetupResult?> addOnce() async {
    if (File(autoMarkerPath).existsSync()) return null;
    final current = status();
    if (current.state != PathSetupState.notAdded) {
      if (current.state == PathSetupState.added) await _writeMarker(current.files);
      return null;
    }
    final result = await add();
    if (result.changed.isNotEmpty) await _writeMarker(result.changed);
    return result;
  }

  Future<void> _writeMarker(List<String> files, {bool removed = false}) async {
    try {
      final marker = File(autoMarkerPath);
      await marker.parent.create(recursive: true);
      await marker.writeAsString(jsonEncode({
        removed ? 'removed' : 'added': DateTime.now().toUtc().toIso8601String(),
        'files': files,
      }));
    } on FileSystemException {
      // Only means the app may offer it again next time.
    }
  }
}
