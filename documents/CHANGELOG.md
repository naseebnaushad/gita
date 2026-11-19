# Changelog

## 1.2.0 (2026-11-19)

- Gita now notices when GitHub has cancelled a sign-in. GitHub keeps only
  the 10 newest sign-ins per account, so signing in elsewhere can silently
  cancel an old one. Profiles shows "sign-in stopped working" with a
  **Sign in again** button, and `gita doctor` reports it with a fix. It
  also warns when a sign-in belongs to a different GitHub account than the
  profile names.
- When a push or `gita gh` is turned down, the message says what happened:
  the sign-in was cancelled (sign in once), it's for the wrong account, or
  that account can't open the project (signing in again won't help).
- `gita sign-in` does nothing when the sign-in already works, so it no
  longer uses up one of the 10. Add `--force` to sign in anyway.
- `gita onboard` signs a profile in again when its sign-in was cancelled,
  instead of skipping it.
- Two accounts in one organization: a folder rule can be marked to win over
  organization rules (Rules screen checkbox, `gita rule add --over-org`), so
  a second profile can be used for that organization's projects in that
  folder.
- Access tokens are a first-class sign-in in the profile editor: a button
  opens GitHub's classic token page with Gita's scopes selected, **Check
  token** confirms the account, and saving checks the token too.
- Running `gita onboard` again now repairs a company repository copy that
  is old or missing files: the copy is moved to `<folder>.backup-<date>`
  (your changes stay there) and downloaded again.

## 1.1.1 (2026-11-09)

- Windows: `gita onboard` started from PowerShell 7 could not install Claude
  Code ("Get-FileHash is not recognized"): Windows PowerShell inherited
  PowerShell 7's module path. It now gets its own, also for setup scripts.

## 1.1.0 (2026-11-09)

- `gita onboard <file>`: set a new computer up from one onboarding file:
  tools (git, gh, Claude Code), clean-up of old GitHub sign-ins that use the
  wrong account, a profile and sign-in per account, repositories and their
  company files and setup script, Claude Code, and `gita doctor`. Safe to run
  again. Also offers to delete old backups from earlier runs. See
  [docs/onboarding.md](../docs/onboarding.md).
- Sign-in also asks for `read:org`, so `gita gh` can run organization and
  team commands. Earlier sign-ins keep working.
- Releases include `SHA256SUMS`.
- The CLI smoke test can no longer change a real setup on Windows.
- `gita gh`: run the GitHub CLI as the account that owns the project, by
  giving `gh` the profile's saved GitHub sign-in in `GH_TOKEN` for that one
  command. No `gh auth login` / `gh auth switch` needed. AI agents (MCP
  instructions and the Claude Code skill) are told to use it.
