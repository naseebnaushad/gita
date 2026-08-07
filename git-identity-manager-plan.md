# Gita — Cross-Platform Git Identity Manager
### Implementation Plan

---

## 1. Product Summary

A Flutter desktop app (macOS, Windows, Linux) that manages multiple Git identities
(e.g. work vs. personal) and prevents the class of bug where a commit/push uses the
wrong account. It is **not** a full Git GUI (no commit/branch/merge UI) — it is an
identity, credential, and safety-net manager that sits on top of native Git
mechanisms (`includeIf`, SSH host aliases, hooks).

**Core value prop:** you assign a profile to a folder once; the app keeps
`~/.gitconfig`, `~/.ssh/config`, and per-repo hooks in sync; and a pre-push hook
blocks any push where the effective identity doesn't match the expected account
for that remote.

---

## 2. Tech Stack

| Layer | Choice | Notes |
|---|---|---|
| UI framework | Flutter (desktop) | `flutter build macos/windows/linux` |
| State management | Riverpod | testable, no BuildContext coupling for services |
| Local persistence | `sqlite3` via `sqlite3_flutter_libs` (or `drift`) | profiles, rules, repo cache |
| Process execution | `dart:io Process.run` | wraps `git`, `ssh`, `ssh-keygen` |
| File system watching | `watcher` package | detect new repos / config drift |
| System tray | `tray_manager` | quick-glance widget |
| Secure storage (tokens, if needed) | `flutter_secure_storage` | Keychain/Credential Manager/libsecret |
| File picker | `file_selector` | choosing repo/key paths |
| Packaging | `msix` (Windows), manual notarization script (macOS), AppImage/deb (Linux) | see §9 |

Git itself does all the real work — the app is a config/credential orchestrator,
not a Git reimplementation. Never shell out to reimplement plumbing that
`git config`, `git remote`, `git rev-parse` etc. already do.

---

## 3. Architecture

```
lib/
  main.dart
  app/
    app.dart                 # MaterialApp, routing, theme
    theme.dart
  core/
    services/
      git_service.dart        # wraps git CLI calls
      ssh_service.dart         # keygen, ssh config read/write
      gitconfig_service.dart   # read/write ~/.gitconfig + includeIf files
      hook_service.dart        # install/update/remove pre-push hook
      repo_scanner_service.dart# filesystem walk to discover .git dirs
      credential_inspector_service.dart # OS credential helper detection
      platform_paths.dart      # cross-OS home/config path resolution
    models/
      profile.dart
      repo_rule.dart
      tracked_repo.dart
      ssh_key.dart
      mismatch_report.dart
    db/
      app_database.dart        # sqlite schema + migrations
  features/
    profiles/                  # profile CRUD screens
    rules/                     # folder-rule assignment
    dashboard/                 # repo list + mismatch badges
    repo_detail/                # single-repo effective-config view
    ssh_manager/                 # key generation, host alias editor
    hooks/                       # hook install/status screen
    settings/
  widgets/
    profile_badge.dart
    mismatch_banner.dart
    ...
test/
  unit/
  integration/
scripts/
  hooks/pre-push.sh.tmpl        # templated hook script, see §7
  install/                      # platform packaging scripts
```

Rationale: `core/services` are pure Dart, no Flutter dependency, so they're
unit-testable by shelling out to a real temp git repo in tests rather than
mocking `Process.run` everywhere.

---

## 4. Data Models

### 4.1 `Profile`
```dart
class Profile {
  String id;              // uuid
  String label;           // "Work", "Personal"
  String gitName;         // user.name
  String gitEmail;        // user.email
  String? sshKeyId;        // FK -> SshKey.id, nullable
  String? gpgKeyId;        // optional signing key fingerprint
  bool signCommitsByDefault;
  int colorArgb;           // for UI badges
  DateTime createdAt;
}
```

### 4.2 `SshKey`
```dart
class SshKey {
  String id;
  String label;
  String privateKeyPath;   // e.g. ~/.ssh/id_work
  String publicKeyPath;
  String hostAlias;        // e.g. "github-work"
  String realHost;         // e.g. "github.com"
  DateTime createdAt;
}
```

### 4.3 `RepoRule` (folder → profile mapping)
```dart
class RepoRule {
  String id;
  String pathPattern;      // absolute dir, e.g. "/Users/me/work"
  String profileId;        // FK -> Profile.id
  int priority;            // longer/more-specific paths win; explicit priority as tiebreaker
}
```
Maps 1:1 to a generated `includeIf "gitdir:<pathPattern>/"` block pointing at a
per-profile include file (see §6.1).

### 4.4 `TrackedRepo` (cached scan result, not source of truth — always
re-verify live before showing critical state)
```dart
class TrackedRepo {
  String path;
  String? remoteUrl;
  String? expectedProfileId;   // resolved via RepoRule match
  String? effectiveEmail;      // last known `git config user.email`
  String? effectiveSshKey;     // resolved from ssh config for remote host
  bool hookInstalled;
  DateTime lastScanned;
}
```

### 4.5 `MismatchReport` (computed, not stored)
```dart
class MismatchReport {
  String repoPath;
  MismatchType type;  // identityMismatch, noRuleMatched, hookMissing, sshKeyMismatch
  String detail;
  Severity severity;  // warning, blocking
}
```

---

## 5. Feature Roadmap (Phased — matches priority tiers from earlier discussion)

### Phase 1 — MVP (identity switching that actually works)
1. **Profile CRUD** — create/edit/delete; detect & import existing identities from
   `~/.gitconfig` on first run.
2. **Rule engine** — assign a profile to a directory; writes `includeIf` blocks.
3. **Repo dashboard** — list known repos (from rules + manually added), show:
   profile assigned, effective email (`git config --get user.email` run *inside*
   that repo dir, not global), remote URL, mismatch badge.
4. **Manual "Add repo"** — folder picker to register a repo outside auto-scan.

**Definition of done for Phase 1:** user can add two profiles, assign work/
personal folders, and see correctly in a table which identity governs each repo.

### Phase 2 — The safety net (this is what prevents your original bug)
5. **SSH key manager** — generate new keypair per profile, or import existing;
   write `~/.ssh/config` host alias block.
6. **Remote URL rewriting tool** — one-click convert `git@github.com:org/repo`
   → `git@github-work:org/repo` (or vice versa) for a selected repo.
7. **Pre-push hook installer** — per-repo or global (`core.hooksPath`) install;
   hook compares effective identity/key against the rule-expected profile for
   that remote and aborts the push with a clear message on mismatch (see §7).
8. **Connection test** — `ssh -T git@<alias>` button with parsed pass/fail.

**Definition of done for Phase 2:** pushing from a misconfigured repo is blocked
locally, with a message telling the user exactly what's wrong and how to fix it.

### Phase 3 — Quality of life
9. **Repo auto-discovery** — background scan of common roots (`~/work`,
   `~/projects`, `~/code`, configurable), suggests rule assignments for
   unmatched repos found.
10. **GPG/SSH commit signing management** — per-profile signing key, toggle
    `commit.gpgsign`, verify via `git log --show-signature` on demo commit.
11. **Credential helper inspector** — surface what `credential.helper` is
    configured (Keychain / Windows Credential Manager / libsecret / manager-core)
    and, where possible, which account it will hand out for a given host —
    this is the second independent cause of the "wrong account pushed" bug.
12. **System tray widget** — shows current active repo (based on focused
    terminal/IDE working dir if feasible, else last-viewed repo) → profile.

### Phase 4 — Power user
13. **Effective config diff/audit view** — show merged config (global + all
    matching `includeIf` + local `.git/config`) with source-file annotations,
    so `includeIf` precedence bugs are debuggable in the UI.
14. **Bulk remote migration** — apply alias rewriting across N repos at once.
15. **Commit history identity audit** — scan `git log --format='%ae'` across a
    repo, flag commits authored with an email that doesn't match the expected
    profile for that remote (retroactive detection, read-only).
16. **Team template export/import** — export Profile+Rule+Hook config as JSON
    (no private key material) for team onboarding.

**Explicitly out of scope for all phases:** commit/branch/merge/diff UI, cloud
sync of profiles or private keys.

---

## 6. Core Logic Detail

### 6.1 Config file layout the app manages

```
~/.gitconfig                      # root; app inserts managed includeIf block
~/.gita/
  profiles/
    work.gitconfig                # [user] name/email, [core] sshCommand, [commit] gpgsign
    personal.gitconfig
  hooks/
    pre-push                      # shared hook script, referenced via core.hooksPath OR copied per-repo
  gita.db                    # sqlite: profiles, rules, keys, cache
```

App writes a clearly delimited managed section in `~/.gitconfig` so it never
clobbers user's existing manual entries:
```ini
# >>> Gita managed rules — do not edit below by hand >>>
[includeIf "gitdir:/Users/me/work/"]
    path = /Users/me/.gita/profiles/work.gitconfig
[includeIf "gitdir:/Users/me/personal/"]
    path = /Users/me/.gita/profiles/personal.gitconfig
# <<< Gita managed rules <<<
```
`gitconfig_service.dart` parses this block with a regex/marker-based approach
(read whole file, replace content between markers, or append markers if
absent) — never a full INI rewrite of the user's file, to avoid destroying
formatting/comments outside the managed block.

### 6.2 SSH config managed block

Same marker strategy in `~/.ssh/config`:
```
# >>> Gita managed hosts >>>
Host github-work
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_work
    IdentitiesOnly yes

Host github-personal
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_personal
    IdentitiesOnly yes
# <<< Gita managed hosts <<<
```
`IdentitiesOnly yes` is important — without it, ssh-agent may offer the wrong
loaded key first regardless of `IdentityFile`, which is a common real-world
cause of exactly the bug the user hit.

### 6.3 Mismatch detection algorithm (used by dashboard AND hook)

Given a repo path:
1. Run `git -C <path> config --get user.email` (falls through includeIf chain
   automatically — this is git's own resolution, so trust it).
2. Run `git -C <path> remote get-url origin` (or first remote found).
3. Look up which `RepoRule` matches this path (longest-prefix match).
4. Determine expected profile from the rule; determine expected identity email
   from that profile.
5. Compare: if `user.email` != expected email → `identityMismatch`.
6. Parse remote URL host (handle both `git@host:` and `https://host/` forms).
   If host is an alias (`github-work`), resolve via `~/.ssh/config` to confirm
   which `IdentityFile` it maps to, and confirm that matches the expected
   profile's `sshKeyId` → else `sshKeyMismatch`.
7. If no rule matches this path at all → `noRuleMatched` (warning severity,
   not blocking — new repo the user hasn't configured yet).

This same function is the one the pre-push hook calls (via a small Dart CLI
build or a portable POSIX+PowerShell reimplementation — see §7 tradeoffs).

### 6.4 Cross-platform path handling

```dart
String homeDir() {
  if (Platform.isWindows) return Platform.environment['USERPROFILE']!;
  return Platform.environment['HOME']!;
}
```
Git config paths on Windows should be written with forward slashes (Git for
Windows accepts them) to avoid escaping issues in `.gitconfig` `path =` lines.

---

## 7. Pre-Push Hook — Implementation Options

The hook must run without Flutter/Dart runtime overhead and must work
identically invoked by `git push` on all three OSes. Two viable approaches;
recommend **Option B** for v1 simplicity, revisit Option A if hook logic grows.

**Option A — Compiled Dart CLI**
`dart compile exe` a small standalone `gita-check` binary, ship it in
the packaged app, hook script just calls it: `gita-check pre-push "$@"`.
Pros: shares exact Dart logic/models with the app, single source of truth.
Cons: binary must be installed to a stable PATH-independent location the hook
script can always find (e.g. `~/.gita/bin/gita-check`).

**Option B — Portable shell + PowerShell dual script (v1 choice)**
Keep the check logic simple enough (mismatch algorithm in §6.3 is ~10 lines
of git plumbing) to hand-write twice:
- `scripts/hooks/pre-push` (POSIX sh, used on macOS/Linux and Git Bash/Windows)
- Git for Windows ships with Git Bash, so a POSIX sh hook actually works on
  all three platforms unmodified — **no PowerShell variant needed**, since
  Git invokes hooks through its bundled bash on Windows too.

```sh
#!/bin/sh
# Gita pre-push guard — installed by the app, do not edit manually
repo_path=$(git rev-parse --show-toplevel)
db="$HOME/.gita/gita.db"
# ... query expected profile for $repo_path from sqlite via `sqlite3` CLI,
# compare against `git config user.email` and resolved ssh identity ...
if [ "$mismatch" = "1" ]; then
  echo "⚠️  Gita: this push would use '$actual_email' but"
  echo "   '$repo_path' is configured for '$expected_email'."
  echo "   Fix in Gita, or run: git config user.email <correct-email>"
  echo "   To push anyway: git push --no-verify"
  exit 1
fi
exit 0
```
Requires `sqlite3` CLI available, or simpler: have the app export a flat
`~/.gita/rules.json` cache file the shell hook parses without a DB
dependency (recommended — avoids requiring sqlite3 on PATH). Use `jq` if
present, else grep/sed on a deliberately simple JSON-lines format written by
the app for exactly this purpose:
```
/Users/me/work|work@company.com|github-work
/Users/me/personal|me@personal.com|github-personal
```
This avoids any parsing dependency at all — `pathPattern|expectedEmail|expectedHostAlias`
matched with `grep`.

**Install modes:**
- Per-repo: copy script to `<repo>/.git/hooks/pre-push`, chmod +x.
- Global: set `git config --global core.hooksPath ~/.gita/hooks` once,
  drop the script there — applies to every repo automatically, including
  future clones. **Recommend this as the default offered in the UI.**

---

## 8. Screens (UI spec, high level)

1. **Onboarding** — detect existing `~/.gitconfig` identity, offer to import
   as first profile; prompt to create a second profile.
2. **Dashboard** (home) — table: Repo | Profile | Effective Email | Remote |
   Status badge (✅ / ⚠️ / ❌) | Last checked. Filter/search. Click row →
   Repo Detail.
3. **Repo Detail** — full effective-config breakdown, remote info, SSH key
   resolution trace, "Fix mismatch" button (applies correct profile or
   rewrites remote), hook install status + toggle.
4. **Profiles** — list + create/edit form (name, email, key picker, color,
   sign-by-default toggle).
5. **Rules** — folder tree/list of rules, add/edit/reorder priority.
6. **SSH Manager** — list of keys, generate new, view/copy public key, host
   alias table, "Test connection" per alias.
7. **Hooks** — global vs per-repo install status across all tracked repos,
   bulk install/reinstall action (useful after updating the hook script).
8. **Settings** — scan roots for auto-discovery, theme, telemetry opt-out
   (if any), version/update check.

---

## 9. Packaging & Distribution

| OS | Format | Notes |
|---|---|---|
| macOS | `.dmg` via `flutter build macos` | Needs Developer ID signing + notarization (`notarytool`) for Gatekeeper; hardened runtime entitlements for file/network access |
| Windows | `.msix` via `msix` pub package, or plain installer via Inno Setup | Code signing cert recommended to avoid SmartScreen warnings |
| Linux | AppImage primary; `.deb` secondary | Ensure `sqlite3` (if used) and `ssh` are declared as expected deps or bundled |

CI: GitHub Actions matrix build (`macos-latest`, `windows-latest`,
`ubuntu-latest`) running `flutter build <platform>` + packaging step per OS,
triggered on tag push.

---

## 10. Testing Strategy

- **Unit tests** for `gitconfig_service`, `ssh_service` marker-block
  read/write logic — test against real temp files, not mocks, to catch
  real INI-quirks.
- **Integration tests** for `git_service` — spin up real temp git repos
  (`git init` in a tmp dir) and assert against actual `git config` output
  rather than mocking `Process.run`, since git CLI behavior nuances
  (quoting, path escaping on Windows) are exactly what's likely to break.
- **Hook script tests** — a small shell test harness (`bats` or plain sh)
  that creates a temp repo, writes a rules cache file, and asserts hook
  exit codes for matching/mismatching identity.
- **Manual QA matrix** — explicitly test the original bug scenario: public
  personal repo + work SSH key loaded in agent + no `IdentitiesOnly` →
  confirm hook now blocks it.

---

## 11. Suggested Build Order

1. Scaffold Flutter project + Riverpod + sqlite schema (models from §4).
2. `git_service.dart` + `gitconfig_service.dart` with unit tests against
   real temp repos — get config read/write and includeIf-block management
   rock solid first, since everything else depends on it.
3. Profiles + Rules screens (Phase 1) wired to the services above.
4. Dashboard with mismatch detection (§6.3) — read-only, builds confidence.
5. `ssh_service.dart` + SSH Manager screen (Phase 2).
6. Hook script (§7, Option B) + `hook_service.dart` installer + Hooks screen.
7. Remote URL rewriting tool.
8. Phase 3/4 features iteratively, per §5.
9. Packaging pipeline (§9) once core flows are stable.

---

## 12. Open Decisions to Confirm Before/During Build

- SQLite vs. flat JSON for local storage — JSON is simpler and sufficient
  given expected data volume (dozens of repos/rules, not thousands); may be
  the better v1 choice over sqlite to reduce native-dependency packaging
  headaches across 3 OSes. **Recommend starting with JSON, migrate to
  sqlite only if query complexity grows.**
- Whether to support GitLab/Bitbucket host aliasing in v1 or GitHub-only
  first (recommend GitHub-only for MVP, generalize the host-alias model in
  §4.2 so it's a config change, not a rewrite, to add more hosts later).
- Whether repo auto-discovery (Phase 3) should run on a background isolate
  continuously or on-demand only — recommend on-demand for v1 to avoid
  battery/fs-watcher complexity.
