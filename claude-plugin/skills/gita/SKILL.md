---
name: gita
description: Use before any git commit, push or clone, before running the GitHub CLI (gh), and when the user asks which GitHub account, email or profile a project uses, or a commit or push was rejected for the wrong account or email, or asks to set up or change Gita (profiles, GitHub sign-in, which account a folder or organization uses). Gita keeps each project on the right GitHub account (for example personal and work).
---

# Gita: the right GitHub account for each project

This computer uses Gita to keep each git project on the right GitHub
account. The `gita` MCP server provides the tools below. The people using it
may not know git well, so explain things in plain words and keep git
jargon out of it.

## Before committing or pushing

Call `gita_check` with the project folder (absolute path).

- `ok: true`: go ahead.
- `ok: false`: **don't commit or push.** Tell the user, in plain words,
  which account the project belongs to and what is wrong, then the fix
  Gita suggests (often "open Gita" or one command). Only run a fix
  yourself if the user agrees.
- The tool reports an error (for example "isn't a git project"): say so
  and carry on with what the user asked for. Don't guess an account.

Never change `user.name`, `user.email`, credential helpers, or SSH
settings yourself to get past a problem Gita reports, and don't use
`--no-verify` unless the user asks for it. Gita's settings are what keep
work and personal accounts apart.

## Downloading a project

Use `gita_clone` with the address instead of `git clone`. It picks the
account, uses that account's sign-in or SSH key, and keeps the project on
it. If it says it can't tell which account to use, ask the user which
profile (see `gita_profiles`) and call it again with `profile`.

## Using the GitHub CLI (`gh`)

`gh` has one login for the whole computer, which may be a different
account from the project's. In a project, run `gita gh <command>` instead
of `gh <command>` (for example `gita gh pr create --fill`): Gita runs `gh`
as the project's account. Everything after `gh` goes to `gh`, including
`--json`. If it says it can't tell which account to use, ask the user
which profile and run `gita gh --profile <name> <command>`. If it says the
profile isn't signed in, use `gita_sign_in`. Don't run `gh auth login`,
`gh auth switch` or `gh auth token` to get around it.

## When something about accounts is wrong

- "Which account is this?" → `gita_which`.
- Push rejected, permission denied, or commits showing the wrong person
  → `gita_which`, then `gita_doctor`, and explain what they say.
- "What accounts do I have?" → `gita_profiles`.
- Doctor found something → `gita_doctor` with `fix: true` fixes what
  needs no person (after you tell the user what it will change).

## Setting Gita up or changing it

Only when the user asks (for example "set up Gita", "make my acme
projects use my work account"). Before each tool that changes something,
say in one sentence what it will change.

1. `gita_scan` (changes nothing) shows the accounts the user's projects
   commit with. Tell the user which folders it looked in (they may keep
   projects somewhere else; pass `folders` then), and ask which accounts
   to set up.
2. `gita_setup` with `only` set to the emails they chose. For an account
   no project uses yet, `gita_profile_add`. Setup names each new profile
   after its email (for example "Acme" for `@acme.com`), so then use
   `gita_profile_edit` to give it the name the user knows it by (such as
   "Work") and its GitHub account name, if they told you it.
3. If their company gave them a Gita setup file, `gita_company_import`
   with the file's full path. If you don't know where it is, ask.
4. For each profile in `needSignIn` (ids; the setup result's `profiles`
   gives their names), `gita_sign_in`. It returns a code and a page: tell
   the user to open the page, sign in **as that account**, and enter the
   code. Gita finishes by itself; `gita_profiles` shows `signedIn: true`
   once it has. While a sign-in is running it also shows
   `signInWaiting`, and `signInError` if it failed (say what it says,
   and offer to try again). Sign profiles in one at a time, so the user
   doesn't mix the accounts up. If sign-in can't be done now, finish the
   other steps and tell the user it's still to do.
5. `gita_doctor` with `fix: true`, then explain anything left. Until a
   profile is signed in, the doctor warns it has no GitHub sign-in:
   that's expected, and the fix is step 4, not a token.
6. `gita_check` each project, then sum up for the user in plain words:
   each profile, the folders and organizations that use it, and what's
   still to do.

When a project matches more than one rule, the strongest wins: a rule
for one project beats an organization rule (`owner`), which beats a
folder rule.

To change which account a folder or a GitHub organization uses:
`gita_rules`, then `gita_rule_add` (it replaces an existing rule) or
`gita_rule_remove`. To rename a profile or change its email or GitHub
account: `gita_profile_edit`. To add or check the safety check in one
project: `gita_guard`. Never ask the user for a password or token.
Removing a profile isn't possible from here; tell the user to do it in
the app.

## If the gita tools are missing or fail to start

Gita isn't installed, or hasn't been opened yet on this computer. Opening
the Gita app once installs what these tools need. Tell the user that,
and fall back to plain git only if they say so.
