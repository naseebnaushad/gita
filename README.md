<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/branding/logo-dark.png">
  <img alt="Gita" src="assets/branding/logo.png" width="360">
</picture>

A cross-platform desktop app (macOS, Windows, Linux) for managing multiple Git
identities — e.g. Work vs. Personal — and preventing the class of bug where a
commit or push ends up using the wrong account.

Gita is not a Git GUI: there's no commit/branch/merge/diff view. It's an
identity, credential, and safety-net manager that sits on top of native Git
mechanisms (`includeIf`, SSH host aliases, hooks) and never reimplements
plumbing that `git config`, `git remote`, etc. already do.

## Core idea

Assign a profile to a folder once. Gita keeps `~/.gitconfig`, `~/.ssh/config`,
and per-repo hooks in sync, and flags — or eventually blocks — any commit or
push where the effective identity doesn't match what's expected for that repo.

## Features

- **Profiles** — bundle a `user.name`/`user.email`, optional signing key, and
  an optional GitHub access token that HTTPS pushes from that profile's
  projects sign in with (stored in the OS keychain/Credential
  Manager/libsecret, never in a plain file) per identity.
- **Rules** — map a folder to a profile; Gita writes a managed `includeIf`
  block into `~/.gitconfig` so Git resolves the right identity per repo
  automatically.
- **Dashboard** — lists tracked repos with their assigned profile, effective
  email, remote, and a mismatch badge.
- **Doctor** — scans profiles/rules/keys for configuration drift (e.g. a
  profile with commit signing enabled but no matching GPG key on this
  machine) before it turns into a failed commit or push.

Planned: SSH key manager with host aliasing, a pre-push hook that blocks
mismatched pushes outright, remote URL rewriting, and a credential-helper
inspector.

## Getting started

```
flutter pub get
flutter run -d macos   # or -d windows / -d linux
```

Run the test suite with:

```
flutter test
```

## Command line

Gita also ships a small `gita` command for git hooks, scripts and AI
coding agents, which can't use the desktop app. It reads the same profiles
and rules the app saves.

```
gita which [folder]    # which account should this project use, and which is it using?
gita check [folder]    # same, but exits 1 if it would commit/push as the wrong account
gita doctor            # find setup problems before they break a commit or push
```

Add `--json` to any command for machine-readable output. Exit codes:
`0` all good, `1` problem found, `2` couldn't run (bad arguments, or not a
git project).

Build it with:

```
dart build cli          # -> build/cli/<platform>/bundle/bin/gita(.exe)
```

(`dart compile exe` doesn't work here because some Flutter plugin
dependencies use native build hooks; `dart build cli` handles them.)

### HTTPS pushes with the right account

Git normally remembers one GitHub login per computer, so every HTTPS push
uses that account, whichever project it comes from. Gita fixes this per
profile. Once a profile has an access token saved and the `gita` command is
installed at `~/.gita/bin/gita` (`gita.exe` on Windows), the profile's
include file tells git to sign in to `https://github.com` through
`gita credential --profile <id>`. Git runs that command itself, and it
answers with that profile's token from the OS credential store.

The managed section looks like this:

```
[credential "https://github.com"]
    helper =
    helper = "!\"/home/me/.gita/bin/gita\" credential --profile <id>"
```

The empty `helper =` stops git from falling back to a login it remembered
for another account. Projects outside the profile's folders, and other
hosts, keep using whatever sign-in the computer already had.

If no token is saved, the push stops with a message telling the person to
add one in Gita. If GitHub rejects the token, the push says so and explains
how to replace it. Doctor (in the app and `gita doctor`) warns about
profiles with no token, and about tokens saved while the `gita` command is
not installed yet.

Until the installers ship the command, install it by hand:

```
dart build cli
# macOS / Linux
mkdir -p ~/.gita/bin && cp build/cli/*/bundle/bin/gita ~/.gita/bin/
# Windows (PowerShell)
New-Item -ItemType Directory -Force ~/.gita/bin; Copy-Item build/cli/windows_x64/bundle/bin/gita.exe ~/.gita/bin/
```

Then open the profile in Gita and press Save again so it writes the
credential settings.

Tokens live in Windows Credential Manager, the macOS login Keychain, or
libsecret on Linux (which needs `secret-tool`, from the `libsecret-tools`
package), filed under `gita`. Tokens saved by earlier versions of Gita move
there automatically the first time the app reads them.

Gita stores its own state (profiles, rules, tracked repos) as flat JSON under
`~/.gita/`, plus one generated `.gitconfig` fragment per profile. It never
hand-edits your `~/.gitconfig` outside a clearly delimited managed block.
