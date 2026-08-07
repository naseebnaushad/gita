import 'dart:io';

/// Resolves a folder path to its symlink-free canonical form.
///
/// macOS in particular symlinks common paths (`/tmp` -> `/private/tmp`),
/// and git's `gitdir:` matching in `includeIf` blocks is done against the
/// resolved path. Rule folder patterns and tracked repo paths must be
/// stored in the same resolved form as git uses, or includeIf silently
/// never matches.
String resolveRepoPath(String path) {
  final dir = Directory(path);
  if (!dir.existsSync()) return path;
  return dir.resolveSymbolicLinksSync();
}
