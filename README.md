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
  an optional access token (stored in the OS keychain/Credential
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

Gita stores its own state (profiles, rules, tracked repos) as flat JSON under
`~/.gita/`, plus one generated `.gitconfig` fragment per profile. It never
hand-edits your `~/.gitconfig` outside a clearly delimited managed block.
