# docs/lifecycle-1.1.1

## What changed and why

`documents/Lifecycle and process flows.md` stopped at PR #27. It now lists #27 merged,
#28 (release 1.1.0), #29 (Windows PowerShell module path fix), #30 (release 1.1.1) and
#31 (onboard repair, not released yet), adds a "Used by" note about the first real Windows
run of a company setup that pins 1.1.1, and updates the Figure 8 caption.

## Logic

Documentation only. No code changed.

## Tests and results

| ID | Check | Result |
|---|---|---|
| DOCS-001 | All 8 Mermaid diagrams render with mermaid-cli 11.4.2 | Pass |
| DOCS-002 | No control bytes; Windows paths keep their backslash | Pass |

## Suggestions

- A `claudeCode` onboarding step could add `~\.local\bin` to the user PATH on Windows,
  since Claude Code's own installer leaves it off.
