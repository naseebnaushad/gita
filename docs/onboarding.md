# Setting up a new computer with `gita onboard`

`gita onboard <file>` sets a developer's computer up from one file that a
company writes once. It is safe to run again: it checks every step first,
keeps what works, repairs what is broken, and finishes with a summary.

```
gita onboard acme-onboarding.json
gita onboard acme-onboarding.json --dry-run     # show what would change; change nothing
```

## What it does, in order

1. **Tools.** Checks git, the GitHub CLI (`gh`) and Claude Code, and
   installs or repairs the ones the file asks for: winget on Windows,
   Homebrew and Xcode's command line tools on macOS, apt, dnf or pacman on
   Linux (it shows the `sudo` command first, and sudo asks for your
   password), and Claude Code's official installer. On Linux it also makes
   sure `secret-tool` is there, because Gita keeps sign-ins with it.
2. **Old GitHub sign-ins.** Finds settings that make git or gh use an old
   GitHub account instead of your Gita profile: saved github.com logins
   (Windows Credential Manager, macOS Keychain, `~/.git-credentials`),
   `url.*.insteadOf` rules and sign-in headers for github.com, old
   credential helpers, GitHub CLI logins and, on Windows, user-level
   `GH_TOKEN` / `GITHUB_TOKEN`. It lists them, asks, backs up
   `~/.gitconfig`, then removes them. Gita's own sign-ins, other sites and
   SSH keys are never touched. Tokens set for all users, tokens set in your
   shell profile and `Host github.com` in your SSH settings are only
   reported.
3. **Old backups.** Backups that earlier runs made (`~/.gitconfig.backup-<date>` from
   the clean-up, `<repo folder>.backup-<date>` from the repo step) that are older than 30
   days are listed and, after you say yes, deleted. The newest backup of each is always
   kept. Old `.gitconfig` backups matter: they can still hold the GitHub tokens the
   clean-up removed. Without a terminal they are only listed (`--yes` deletes them).
4. **Accounts.** Asks for your name and one email per account (or takes
   `--name` and `--email <account>=<email>`), checks each email is at the
   account's domain, and adds a Gita profile for it (or reuses the one you
   have).
5. **The steps in the file**, in the order written (below).
6. **Summary.** One line per step, then what to do next. If a step can't go
   on, the run stops with "Setup stopped:", the reason and what to do; fix
   it and run the same command again.

## Options

| Option | Effect |
|---|---|
| `--dry-run` | Show what would change; change nothing. |
| `--yes` | Answer yes to every question (removing old sign-ins and old backups, running setup scripts). |
| `--clean` | Remove old GitHub sign-ins without asking. Without a terminal and without this, they are kept. |
| `--name <name>` | Your name for commits. Default: git's `user.name`. |
| `--email <account>=<email>` | Your email for an account in the file. Repeat per account. |
| `--skip-sign-in`, `--skip-repos` | Leave out GitHub sign-in, or the repository steps (for testing). |

Exit codes: `0` done (some steps may need attention), `1` a step stopped
the run, `2` the file or the options are wrong.

## The onboarding file

JSON, at most 64 KB. Unknown fields are an error, so a typo is caught
instead of silently ignored. Gita only reads it from a local path: it never
downloads it. It can't run arbitrary commands: only the step types below.

```json
{
  "format": 1,
  "name": "Acme",
  "tools": { "git": "required", "gh": "optional", "claude": "required" },
  "cleanup": "ask",
  "accounts": [
    { "id": "work", "label": "Acme", "emailDomain": "acme.com" },
    { "id": "labs", "label": "Acme Labs", "emailDomain": "acme-labs.com",
      "question": "Your @acme-labs.com email (projects in acme-labs)" }
  ],
  "steps": [
    { "type": "signIn", "account": "labs" },
    { "type": "repo", "account": "labs", "url": "https://github.com/acme-labs/handbook.git",
      "dir": "~/handbook" },
    { "type": "companyFile", "account": "work", "repoDir": "~/handbook", "path": "gita/acme.json" },
    { "type": "companyFile", "account": "labs", "repoDir": "~/handbook", "path": "gita/acme-labs.json" },
    { "type": "signIn", "account": "work" },
    { "type": "repoScript", "repoDir": "~/handbook", "windows": "setup.ps1", "unix": "setup.sh" },
    { "type": "claudeCode" },
    { "type": "doctor" }
  ]
}
```

| Field | Meaning |
|---|---|
| `format` | Always `1`. |
| `name` | Shown to the developer. |
| `tools` | `git`, `gh`, `claude`: `required`, `optional` or `skip` (the default for a tool left out). |
| `cleanup` | `ask` (default), `yes` (remove without asking) or `skip`. |
| `accounts` | One per GitHub account: `id` (used by the steps; a-z, 0-9, `-`), `label` (the Gita profile name), `emailDomain`, and an optional `question`. |

### Step types

| Type | What it does |
|---|---|
| `signIn` | Signs the account's profile in to GitHub. An existing sign-in is kept after you confirm it is your account for that email. A GitHub login that another account in the file already uses is refused. |
| `repo` | Clones `url` (an `https://github.com/owner/repo` address) into `dir` (always inside your home folder) with the account's profile. A clean copy that is already there is updated; one with local changes is kept; anything else in that folder is moved to `<dir>.backup-<date>`, never deleted. If the download fails, the first likely cause listed is that the organization hasn't approved the Gita app yet. |
| `companyFile` | Imports a Gita company file (see [company-rollout.md](company-rollout.md)) from a repository cloned by an earlier `repo` step, for that account. |
| `repoScript` | Runs a script that is inside a repository cloned by an earlier `repo` step: `windows` (a `.ps1`, run with PowerShell) or `unix` (a `.sh`, run with bash). Gita shows the path and asks first (`--yes` skips the question). The script gets no terminal input. |
| `claudeCode` | Connects Gita to Claude Code (`gita mcp add-to-claude`). |
| `doctor` | Runs `gita doctor`. "Heads up" notes don't count as problems. |

## Getting the file to people

Gita is the same app for everyone, so the file usually comes with a small
script of your own that downloads a pinned Gita release, checks its
SHA-256 against the release's `SHA256SUMS`, downloads your onboarding file
next to it, and runs `gita onboard` with it.
