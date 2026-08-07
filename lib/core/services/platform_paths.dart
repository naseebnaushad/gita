import 'dart:io';

import 'package:path/path.dart' as p;

/// Cross-OS home dir + ~/.gita path resolution (plan §6.4).
class PlatformPaths {
  /// [overrideHomeDir] lets tests point the whole path tree at a temp
  /// directory instead of the real user home.
  const PlatformPaths({String? overrideHomeDir}) : _overrideHomeDir = overrideHomeDir;

  final String? _overrideHomeDir;

  String homeDir() {
    if (_overrideHomeDir != null) return _overrideHomeDir;
    if (Platform.isWindows) {
      return Platform.environment['USERPROFILE'] ??
          '${Platform.environment['HOMEDRIVE']}${Platform.environment['HOMEPATH']}';
    }
    return Platform.environment['HOME']!;
  }

  String get gitaDir => p.join(homeDir(), '.gita');

  String get profilesDir => p.join(gitaDir, 'profiles');

  String get hooksDir => p.join(gitaDir, 'hooks');

  String get profilesJsonPath => p.join(gitaDir, 'profiles.json');

  String get rulesJsonPath => p.join(gitaDir, 'rules.json');

  String get sshKeysJsonPath => p.join(gitaDir, 'ssh_keys.json');

  String get trackedReposJsonPath => p.join(gitaDir, 'tracked_repos.json');

  /// Flat pathPattern|expectedEmail|expectedHostAlias cache the pre-push
  /// hook scripts parse without any DB/JSON dependency (plan §7).
  String get hookRulesCachePath => p.join(gitaDir, 'rules.cache');

  String get gitConfigPath => p.join(homeDir(), '.gitconfig');

  String get sshConfigPath => p.join(homeDir(), '.ssh', 'config');

  /// Git config `path =` lines must use forward slashes even on Windows
  /// (Git for Windows accepts them and this avoids escaping issues).
  String toGitConfigPath(String nativePath) => nativePath.replaceAll('\\', '/');
}
