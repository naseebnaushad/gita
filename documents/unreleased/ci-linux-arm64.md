---
type: ci
area: release
title: Gita is built and released for arm64 Linux
authors: [naseebnaushad]
branch: ci/linux-arm64
after_the_fact: false
---

## What changed and why
- **Before:** releases had Linux downloads for x86_64 only. ThoughtBox dev-setup stopped on arm64 Linux computers with "Gita is only built for x86_64 Linux (this is aarch64)".
- **Now:** every build and release also makes `gita-linux-arm64.tar.gz`, `gita_<version>_arm64.deb` and `gita-<version>-1.aarch64.rpm`, listed in the release's `SHA256SUMS` like the other downloads.

## How it works (logic)
- `.github/workflows/build.yml`: a new matrix entry, **Linux arm64**, runs on GitHub's `ubuntu-24.04-arm` runner and uploads the artifact `linux-arm64`. The x64 Linux artifact keeps its name `linux`, so the Arch job is unchanged.
- Flutter publishes no Linux arm64 SDK archive, so `subosito/flutter-action` can't install a pinned version there. The arm64 job clones Flutter's git tag `$FLUTTER_VERSION` instead; its first `flutter` run downloads the arm64 Dart SDK and engine.
- The packaging step uses `build/linux/<arch>/release/bundle`, runs `gita --version` and `scripts/smoke_cli.sh`, and checks that the `.deb` installs and runs, as for x64.
- `packaging/linux/package.sh` takes an optional fifth argument, `x64` (default) or `arm64`, which sets the deb (`amd64`/`arm64`) and rpm (`x86_64`/`aarch64`) architecture and file names.
- `release.yml` is unchanged apart from a comment: the publish step already merges every artifact and writes `SHA256SUMS`.

## Tests added and results
No app code changed. The pull request's Build workflow run (#37) builds, smoke-tests and installs the arm64 `.deb` on an arm64 runner.

## Notes for users / upgrade steps
- On an arm64 Linux computer, download `gita-linux-arm64.tar.gz` (or the arm64 `.deb` / `.rpm`) from the release.
- ThoughtBox dev-setup supports arm64 Linux once it pins a Gita release with this download (ThoughtBoxFinTechAI/dev-setup#15).

## Technical notes
- No app code, dependency or configuration changes.
- The Arch package (`gita-bin`) stays x86_64 only: the `archlinux` container image used in CI is x86_64 only.
