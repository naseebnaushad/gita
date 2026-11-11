---
type: fix
area: onboard
title: Running the setup again repairs an old or incomplete company repository
authors: [naseebnaushad]
branch: fix/onboard-repair
cr: CR-1.1.2-01
after_the_fact: false
---

## What changed and why
- **Before:** `gita onboard` stopped with "Setup stopped: ~/<repo> has no <file>. It may be an old copy" when a company repository on the computer had both:
  - local changes, so it was "kept (local changes)" and never updated;
  - no copy of a file a later step needs (for example `gita/thoughtbox.json`).
- Running the setup again could not fix this. People had to move the folder away by hand. This happened in a real botched macOS install.
- **Now:** the repo step first checks whether the copy has every file the later steps need from it. If one is missing, the copy is moved to `<folder>.backup-<date>` and downloaded again. Running the setup again repairs it, and nothing is deleted.

## How it works (logic)
- `RepoEnsurer.ensure()` takes `needs`: paths inside the repository that later steps use (`lib/core/onboarding/repo_step.dart:100`).
  - **Clean copy:** it is updated first (`git pull --ff-only`), then checked. A copy the update fixes is not moved.
  - **Update failed** (for example a diverged copy): the copy is checked the same way.
  - **Copy with local changes:** it is checked straight away. If every needed file is there, it is kept as before.
  - **Missing file:** the copy is moved aside (`_moveAside`) and a fresh copy is downloaded. The summary says `downloaded again (old copy in <backup>)`, and a note says where the local changes are.
  - **Dry run:** says what it would do and changes nothing.
- `onboard_command.dart:298` builds `needs` from the `companyFile` paths and this system's `repoScript` for the same folder. Only paths that stay inside the folder are used.
- The later "has no … It may be an old copy" stops remain as a safety net.
- The existing old-backups step already offers to delete `<repo>.backup-<date>` folders after 30 days.

## Tests added and results
`flutter test test/unit/onboarding_repo_step_test.dart test/unit/cli_onboard_test.dart` was run on macOS on 2026-11-10: all 37 tests passed.

| ID | Case | Result |
|---|---|---|
| ONBOARD-001 | Local changes and a needed file missing: moved aside, downloaded again, changes kept in the backup | ✅ |
| ONBOARD-002 | Local changes and every needed file present: kept, as before | ✅ |
| ONBOARD-003 | Clean old copy that the update fixes: updated, not moved | ✅ |
| ONBOARD-004 | Diverged copy missing a needed file: moved aside with its commit, downloaded again | ✅ |
| ONBOARD-005 | Download fails after the move: run fails, backup stays | ✅ |
| ONBOARD-006 | Dry run with a missing file: changes nothing | ✅ |
| ONBOARD-007 | Full `gita onboard` rerun after a company file was deleted and a local file added: finishes OK, file back, local file in the backup | ✅ |

ONBOARD-007 was also run against the old code. It fails there with the original error: "Setup stopped: ~/handbook has no gita/lab.json."

## Bugs fixed
- **What people saw:** rerunning the dev-setup installer after a botched install stopped with "has no gita/thoughtbox.json. It may be an old copy".
- **Cause:** a repository copy with local changes was never updated or replaced, even when it lacked files setup needs.
- **Fix:** such a copy is now backed up and downloaded again.

## Notes for users / upgrade steps
- If setup went wrong, run the same setup command again.
- A company repository that is missing files is moved to `<folder>.backup-<date>`, and a fresh copy is downloaded. Your own changes are in the backup folder.
- dev-setup must pin this Gita version for its one-line installer to do this.

## Technical notes
- No new dependencies.
- No configuration changes.
- No change to the onboarding file format.

## Suggestions
- Dashboard **Remove** for tracked projects (CR-1.2.0-01, Draft).
- `gita onboard --check`: report what is missing without changing anything.
