---
name: gita
description: Use before any git commit, push or clone, and when the user asks which GitHub account, email or profile a project uses, or a commit or push was rejected for the wrong account or email. Gita keeps each project on the right GitHub account (for example personal and work).
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
- Setting Gita up for the first time → `gita_scan` shows suggestions
  (it changes nothing); the user finishes setup in the Gita app.

## If the gita tools are missing or fail to start

Gita isn't installed, or hasn't been opened yet on this computer. Opening
the Gita app once installs what these tools need. Tell the user that,
and fall back to plain git only if they say so.
