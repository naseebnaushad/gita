---
name: gita
description: Use before any git commit, push or clone, and when the user asks which GitHub account, email or profile a project uses, or a commit or push was rejected for the wrong account or email, or asks to set up or change Gita (profiles, GitHub sign-in, which account a folder or organization uses). Gita keeps each project on the right GitHub account (for example personal and work).
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
   commit with. Ask which ones to set up.
2. `gita_setup` with `only` set to the emails they chose. For an account
   no project uses yet, `gita_profile_add`.
3. For each profile in `needSignIn`, `gita_sign_in`. It returns a code and
   a page: tell the user to open the page, sign in **as that account**,
   and enter the code. Gita finishes by itself; `gita_profiles` shows
   `signedIn: true` once it has (`signInWaiting` while it waits,
   `signInError` if it failed). Sign profiles in one at a time, so the
   user doesn't mix the accounts up.
4. If their company gave them a Gita setup file, `gita_company_import`.
5. `gita_doctor` with `fix: true`, then explain anything left.

To change which account a folder or a GitHub organization uses:
`gita_rules`, then `gita_rule_add` (it replaces an existing rule) or
`gita_rule_remove`. Never ask the user for a password or token. Removing
a profile isn't possible from here; tell the user to do it in the app.

## If the gita tools are missing or fail to start

Gita isn't installed, or hasn't been opened yet on this computer. Opening
the Gita app once installs what these tools need. Tell the user that,
and fall back to plain git only if they say so.
