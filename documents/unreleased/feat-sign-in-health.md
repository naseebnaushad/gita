---
type: feature
area: signin
title: Gita notices when GitHub has cancelled a sign-in, and stops asking you to sign in again for nothing
authors: [naseebnaushad46]
branch: feat/sign-in-health
cr: "v1.1.0 - Change Request (sign-in health)"
after_the_fact: false
---

## What changed and why
People kept being told to "sign in to Gita again", and each time it was
treated as a mystery. The cause: GitHub keeps only the 10 newest sign-ins
per account for one OAuth app. Signing in again on another computer, or
for another profile with the same account, silently cancels the oldest.
Gita still showed the cancelled sign-in as "Signed in as @name", so pushes
failed with a vague message.

Now Gita asks GitHub whether each saved sign-in still works:

- **Profiles** shows "sign-in stopped working" with a **Sign in again**
  button.
- **Doctor** (app, `gita doctor`, and `gita_doctor` for Claude) reports a
  cancelled sign-in as a problem with a **Sign in** fix, and warns when a
  sign-in belongs to a different GitHub account than the profile names.
- When a push is turned down, the message says which of three things
  happened: the sign-in was cancelled (sign in once), it's for the wrong
  account, or it works but that account can't open the project (signing
  in again won't help).
- `gita sign-in` (and `gita_sign_in`) does nothing when the sign-in
  already works for the right account, so it no longer uses up one of the
  10. `--force` (`force: true`) signs in anyway.

## How it works (logic)
- `lib/core/services/sign_in_checker.dart`: the `SignInChecker` port and
  `GitHubSignInChecker`, which calls `GET https://api.github.com/user`.
  200 with a login = working, 401 = rejected, anything else (other status,
  timeout of 10 s, no network, bad JSON) = unknown. Clear answers are kept
  in memory for 5 minutes per token; unknown is not kept.
- Unknown is treated as fine everywhere, so being offline never sends
  people to sign in again.
- `IdentityDoctorService._signInHealthIssue` adds `signInRejected`
  (blocking) or `signInWrongAccount` (warning); both map to
  `DoctorFix.signIn`.
- `GitaCli`: `_explainRejectedSignIn` (credential `erase`) and
  `_workingSignIn` (sign-in skip). The CLI only creates the network checker
  when it also uses the real token store, so tests stay offline.
- The token is never printed, logged or returned; it is only sent to
  GitHub in the `Authorization` header, as pushes already do.

## Tests added and results
`flutter test`: 273 passed (was 254). `flutter analyze`: no issues.

| ID | Case | Result |
|---|---|---|
| SIGNIN-001 | 200 from GitHub = working, with the account name | ✅ |
| SIGNIN-002 | 401 = rejected | ✅ |
| SIGNIN-003 | 500, 403, bad JSON, no login, network error, timeout = unknown | ✅ |
| SIGNIN-004 | Empty token = rejected without asking GitHub | ✅ |
| SIGNIN-005 | Clear answers cached 5 min per token; unknown not cached | ✅ |
| SIGNIN-006 | Doctor: rejected sign-in is blocking, names the profile, no token in text | ✅ |
| SIGNIN-007 | Doctor: sign-in for another account is a warning naming both accounts | ✅ |
| SIGNIN-008 | Doctor: working / unknown / no expected account = no issue | ✅ |
| SIGNIN-009 | Doctor: no checker or no token = GitHub not asked | ✅ |
| SIGNIN-010 | Push turned down, sign-in cancelled: one clear step, token kept, nothing on stdout | ✅ |
| SIGNIN-011 | Push turned down, sign-in works: "signing in again will not help" | ✅ |
| SIGNIN-012 | Push turned down, wrong account: says which account to use | ✅ |
| SIGNIN-013 | Push turned down, GitHub not reachable: general advice | ✅ |
| SIGNIN-014 | `gita sign-in` on a working sign-in does nothing (text and `--json` alreadySignedIn) | ✅ |
| SIGNIN-015 | `gita sign-in` on a cancelled or wrong-account sign-in signs in | ✅ |
| SIGNIN-016 | `--force` signs in without checking | ✅ |
| SIGNIN-017 | `gita doctor --json` lists signInRejected, without the token | ✅ |
| SIGNIN-018 | Both new categories offer the Sign in fix | ✅ |
| SIGNIN-019 | MCP `gita_sign_in` passes `force` as `--force` | ✅ |
| SIGNIN-020 | Live (read-only), built `gita.exe doctor` on the dev machine flags the cancelled "ThoughtBox" sign-in | ✅ |
| SIGNIN-021 | Live, built `gita.exe sign-in --profile AI` on a working sign-in: "Nothing to do" | ✅ |

Not tested automatically: the Profiles screen's "Sign in again" row
(no widget test; checked by reading the code and the analyzer only).

## Bugs fixed
- A sign-in cancelled on GitHub showed as "Signed in" and the Doctor said
  nothing. Cause: Gita only checked that a token was saved, not that GitHub
  still accepted it. Fix: the check above.
- A turned-down push told people to "paste a new access token and press
  Save", an option the app no longer leads with. It now points to
  **Sign in with GitHub** and only when that will help.

## Notes for users / upgrade steps
- If Gita says a sign-in "has stopped working", sign that profile in once
  (Profiles → edit → Sign in with GitHub). Don't sign in again otherwise.
- `gita sign-in` on an already working sign-in now does nothing; add
  `--force` to switch accounts.

## Technical notes
- New outbound request: `GET https://api.github.com/user` when the Doctor
  runs, when a profile opens, when a push is turned down, and before
  `gita sign-in`. 10 s timeout, results cached 5 min.
- No new dependencies, settings or migrations.
- New Doctor categories `signInRejected` and `signInWrongAccount` appear in
  `gita doctor --json`.

## Suggestions
- Per-profile SSH as a fallback for HTTPS sign-ins (option D, not approved).
- A widget test for the Profiles "Sign in again" row.
- Show in Profiles how many profiles share one GitHub account, since they
  share the 10-sign-in limit.
