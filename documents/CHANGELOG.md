# Changelog

## 1.1.0 (unreleased)

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
