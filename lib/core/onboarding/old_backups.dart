/// Old backups that `gita onboard` made earlier (`~/.gitconfig.backup-<date>`
/// from the clean-up, `<repo folder>.backup-<date>` from the repo step), so
/// they don't pile up. `.gitconfig` backups matter most: they can still hold
/// the old GitHub tokens the clean-up removed.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'system.dart';

/// One backup found next to the file or folder it was made from.
class OldBackup {
  const OldBackup(this.path, this.made, {required this.isFolder});

  final String path;

  /// When it was made, from its name.
  final DateTime made;
  final bool isFolder;
}

/// Finds old backups and, after asking, deletes them. The newest backup of
/// each file or folder is always kept, and so is anything newer than [maxAge].
class OldBackups {
  OldBackups({
    required this._reporter,
    required this._prompter,
    this._now = DateTime.now,
    this.maxAge = const Duration(days: 30),
  });

  final Reporter _reporter;
  final Prompter _prompter;
  final DateTime Function() _now;

  /// Backups younger than this are kept.
  final Duration maxAge;

  /// `<name>.backup-YYYYMMDD-HHMMSS` with an optional `-2`, `-3`... suffix.
  static final _name = RegExp(r'^(.+)\.backup-(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})(?:-\d+)?$');

  /// The backups of each path in [originals] that may be deleted, oldest first.
  List<OldBackup> find(Iterable<String> originals) {
    final found = <OldBackup>[];
    for (final original in originals) {
      final dir = Directory(p.dirname(original));
      final base = p.basename(original);
      if (!dir.existsSync()) continue;
      final mine = <OldBackup>[];
      for (final e in dir.listSync(followLinks: false)) {
        final m = _name.firstMatch(p.basename(e.path));
        if (m == null || m.group(1) != base) continue;
        final made = DateTime(
          int.parse(m.group(2)!),
          int.parse(m.group(3)!),
          int.parse(m.group(4)!),
          int.parse(m.group(5)!),
          int.parse(m.group(6)!),
          int.parse(m.group(7)!),
        );
        mine.add(OldBackup(e.path, made, isFolder: e is Directory));
      }
      if (mine.length < 2) continue; // the only backup is the newest: keep it
      mine.sort((a, b) {
        final c = a.made.compareTo(b.made);
        return c != 0 ? c : a.path.compareTo(b.path);
      });
      final cutoff = _now().subtract(maxAge);
      found.addAll(mine.take(mine.length - 1).where((b) => b.made.isBefore(cutoff)));
    }
    return found;
  }

  /// The whole step. Returns the summary row: 'none', 'dry run', 'kept (n; no
  /// terminal to ask)', 'kept (n)', 'deleted n' or 'deleted k of n (some failed)'.
  Future<String> run(Iterable<String> originals, {required bool dryRun, required bool yes}) async {
    final old = find(originals);
    if (old.isEmpty) return 'none';
    _reporter.note(
      'Old backups made by earlier setups (older than ${maxAge.inDays} days; the newest of each is kept):',
    );
    for (final b in old) {
      _reporter.note('  - ${b.path}${b.isFolder ? ' (folder)' : ''}');
    }
    if (old.any((b) => p.basename(b.path).startsWith('.gitconfig.backup-'))) {
      _reporter.note('Old .gitconfig backups can still hold GitHub tokens that were removed from your settings.');
    }
    if (dryRun) {
      _reporter.note('[dry run] would ask, then delete the backups above');
      return 'dry run';
    }
    if (!yes) {
      if (!_prompter.interactive) {
        _reporter.warn('No terminal to ask, so nothing was deleted.');
        return 'kept (${old.length}; no terminal to ask)';
      }
      if (!await _prompter.confirm('Delete these old backups?', defaultYes: true)) {
        return 'kept (${old.length})';
      }
    }
    var deleted = 0;
    for (final b in old) {
      try {
        // A link is removed as a link: never follow it out of the folder.
        final type = FileSystemEntity.typeSync(b.path, followLinks: false);
        if (type == FileSystemEntityType.link) {
          Link(b.path).deleteSync();
        } else if (type == FileSystemEntityType.directory) {
          Directory(b.path).deleteSync(recursive: true);
        } else {
          File(b.path).deleteSync();
        }
        deleted++;
      } on FileSystemException catch (e) {
        _reporter.warn("Couldn't delete ${b.path}: ${e.osError?.message ?? e.message}");
      }
    }
    _reporter.note('Deleted $deleted of ${old.length}.');
    return deleted == old.length ? 'deleted $deleted' : 'deleted $deleted of ${old.length} (some failed)';
  }
}
