# Changelog

## 1.1.0 (unreleased)

- `gita gh`: run the GitHub CLI as the account that owns the project, by
  giving `gh` the profile's saved GitHub sign-in in `GH_TOKEN` for that one
  command. No `gh auth login` / `gh auth switch` needed. AI agents (MCP
  instructions and the Claude Code skill) are told to use it.
