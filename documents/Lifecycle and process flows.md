# Gita – Lifecycle and process flows

How Gita's command-line parts work end to end, with labelled diagrams: what goes where
and when. This covers `gita onboard`, sign-in, cloning, `gita gh`, the files Gita writes,
and how a release reaches people. User-facing docs: [README](../README.md),
[docs/onboarding.md](../docs/onboarding.md), [docs/company-rollout.md](../docs/company-rollout.md).
Every figure has a short "who / what / where / when" table.

Contents:
1. [Components](#1-components)
2. [What goes where on a computer](#2-what-goes-where-on-a-computer)
3. [`gita onboard` from start to finish](#3-gita-onboard-from-start-to-finish)
4. [Checking an onboarding file](#4-checking-an-onboarding-file)
5. [Signing a profile in to GitHub](#5-signing-a-profile-in-to-github)
6. [The repo step and failed clones](#6-the-repo-step-and-failed-clones)
7. [`gita gh`](#7-gita-gh)
8. [From a change to a release](#8-from-a-change-to-a-release)
9. [History](#9-history)

---

## 1. Components

```mermaid
flowchart TB
  subgraph UI["Front-ends"]
    APP["Desktop app<br/>(Flutter, lib/features)"]
    CLI["gita command<br/>(lib/cli/gita_cli.dart + parts)"]
    MCP["gita mcp<br/>(AI tools, lib/cli/mcp_server.dart)"]
  end
  subgraph CORE["Core (pure Dart, lib/core)"]
    SVC["services: profiles, rules, git config,<br/>sign-in (device flow), clone,<br/>company setup, doctor, path setup"]
    ONB["onboarding: file parser, tools,<br/>clean-up, old backups, repo step"]
    PORTS["ports: CommandRunner, Prompter,<br/>Reporter, keychain, paths"]
  end
  APP --> SVC
  CLI --> SVC
  CLI --> ONB
  MCP --> CLI
  ONB --> PORTS
  SVC --> PORTS
  PORTS --> OS["git, gh, package managers,<br/>password store, file system"]
```

*Figure 1 – Front-ends call the same core; the core reaches the machine only through ports
(so tests use fakes).*

| Piece | Where | Used when |
|---|---|---|
| Desktop app | `lib/features/`, `lib/app/` | People manage profiles and rules by hand |
| `gita` command | `lib/cli/` (`onboard_command.dart`, `gh_command.dart`, `manage_commands.dart`) | Scripts, hooks, git's credential helper, onboarding |
| Onboarding core | `lib/core/onboarding/` | `gita onboard` |

---

## 2. What goes where on a computer

```mermaid
flowchart LR
  INST["Installer or setup script"] -->|"app"| APPDIR["Windows: %LOCALAPPDATA%\\Programs\\Gita<br/>macOS: gita.app<br/>Linux: ~/.local/share/gita"]
  INST -->|"command: cli/bin, cli/lib"| BIN["~/.gita/bin, ~/.gita/lib"]
  APPDIR -->|"app start copies its command"| BIN
  BIN -->|"gita path add"| PATHF["Shell startup files /<br/>Windows user PATH"]
  G["gita (app or command)"] -->|"profiles, rules,<br/>company setup"| DATA["~/.gita/profiles.json, rules.json,<br/>company.json, tracked_repos.json"]
  G -->|"per-profile git settings"| PG["~/.gita/profiles/&lt;id&gt;.gitconfig"]
  G -->|"managed includeIf block"| GC["~/.gitconfig"]
  G -->|"sign-in tokens"| KS["Password store:<br/>Credential Manager (gita:...),<br/>Keychain, secret-tool"]
  GITC["git"] -->|"credential helper:<br/>gita credential --profile id get"| G
  G -->|"onboard clean-up backup"| BK["~/.gitconfig.backup-date"]
```

*Figure 2 – Files Gita and its installers write.*

| Item | Path | Written by | When |
|---|---|---|---|
| Command | `~/.gita/bin`, `~/.gita/lib` | Installer, app start | Install, every app start |
| Profiles, rules | `~/.gita/*.json` | App, `gita profile/rule/company/onboard` | When changed |
| Git settings | `~/.gitconfig` managed block, `~/.gita/profiles/<id>.gitconfig` | Gita | When rules or profiles change |
| Tokens | Password store, one per profile | Sign-in | Sign-in |
| Backups | `~/.gitconfig.backup-<date>`, `<repo>.backup-<date>` | `gita onboard` | Before removing settings / moving a folder |

---

## 3. `gita onboard` from start to finish

```mermaid
flowchart TD
  A(["gita onboard file.json<br/>--name, --email id=..., --dry-run, --yes, --clean"]) --> B["Read local file (64 KB max)<br/>and check it (Figure 4)"]
  B -->|"invalid"| X1["Setup stopped: message, exit 2"]
  B --> T["Tools: git, gh, Claude Code<br/>(+ secret-tool on Linux)<br/>required / optional / skip"]
  T -->|"required tool can't be fixed"| X2["Setup stopped, exit 1"]
  T --> C["Clean-up of old GitHub sign-ins<br/>ask / yes / skip"]
  C --> OB["Old backups older than 30 days<br/>(newest kept), after asking"]
  OB --> AC["Accounts: name + email per account,<br/>email must match emailDomain;<br/>find or add a profile"]
  AC --> S{"Next step in the file"}
  S -->|"signIn"| S1["Sign in, confirm the login,<br/>refuse a login another account uses"]
  S -->|"repo"| S2["Clone / update / keep / move aside<br/>(Figure 6)"]
  S -->|"companyFile"| S3["gita company import, for that account"]
  S -->|"repoScript"| S4["Show, ask, run the script<br/>inside the cloned repo<br/>(no terminal input)"]
  S -->|"claudeCode"| S5["gita mcp add-to-claude"]
  S -->|"doctor"| S6["gita doctor"]
  S1 & S2 & S3 & S4 & S5 & S6 --> S
  S -->|"no more steps"| SUM(["Summary: one line per step,<br/>Done / needs attention / Dry run finished"])
```

*Figure 3 – Order of work in `gita onboard`. A step that can't go on stops the run with
"Setup stopped:" and exit code 1; the summary is printed either way.*

| Who / what | What | Where | When |
|---|---|---|---|
| Company | Writes the onboarding file once | Any repo or folder; given to Gita as a local path | When their setup changes |
| Developer (or a company script) | Runs `gita onboard <file>` | Terminal | New computer; again to repair |
| Gita | Runs the steps above | This computer | Each run (finished steps are skipped) |

---

## 4. Checking an onboarding file

```mermaid
flowchart LR
  F["file.json"] --> S1{"≤ 64 KB and JSON?"}
  S1 -->|"no"| E["Refused with a message"]
  S1 --> S2{"Only known fields?<br/>format = 1?"}
  S2 -->|"no"| E
  S2 --> S3{"Text: length limits,<br/>no control or bidi characters?"}
  S3 -->|"no"| E
  S3 --> S4{"Accounts: unique id, label,<br/>emailDomain is a domain?"}
  S4 -->|"no"| E
  S4 --> S5{"Steps: fixed types only;<br/>repo url https://github.com/owner/repo;<br/>dir inside ~; paths inside the repo;<br/>repoDir from an earlier repo step"}
  S5 -->|"no"| E
  S5 --> OK(["Accepted"])
```

*Figure 4 – `OnboardingFile.parse` (`lib/core/onboarding/onboarding_file.dart`). Nothing in
the file can run an arbitrary command.*

---

## 5. Signing a profile in to GitHub

```mermaid
sequenceDiagram
  autonumber
  participant P as Person
  participant G as Gita
  participant B as Browser
  participant H as GitHub
  G->>H: Device code request (client "Gita",<br/>scopes repo, workflow, read:user,<br/>user:email, write:public_key, read:org)
  H-->>G: User code + github.com/login/device
  G->>B: Opens the page, shows the code
  P->>B: Signs in as the account for this profile, enters the code, Authorize
  loop until authorized
    G->>H: Poll for the token
  end
  H-->>G: Token
  G->>H: Who is this? (/user)
  G->>G: Save token in the password store,<br/>record the login, update git settings
  Note over G,H: Organizations that restrict OAuth apps must approve "Gita"<br/>(Organization settings → Third-party access)<br/>or the token can't see their private repos
```

*Figure 5 – Device-flow sign-in (`lib/core/services/github_device_flow.dart`).*

---

## 6. The repo step and failed clones

```mermaid
stateDiagram-v2
  [*] --> Check
  Check --> Missing: folder doesn't exist
  Check --> Clean: git copy of the same repo, no changes
  Check --> Dirty: local changes
  Check --> Other: not a folder, empty, not git,<br/>another project, damaged
  Clean --> Updated: git pull --ff-only works
  Clean --> KeptUpdateFailed: can't fast-forward / offline
  Dirty --> KeptLocalChanges
  Other --> MovedAside: rename to dir.backup-date
  MovedAside --> Missing
  Missing --> Downloaded: gita clone --profile works
  Missing --> Failed: clone fails
  Failed --> Explain
  Explain --> Missing: signIn problem, person agrees<br/>to sign in again (once)
  Explain --> [*]: helper / sshKey problem,<br/>or no retry
  Updated --> [*]
  KeptUpdateFailed --> [*]
  KeptLocalChanges --> [*]
  Downloaded --> [*]
```

*Figure 6 – States of the repo step (`lib/core/onboarding/repo_step.dart`). A failed clone
removes the partial folder. The explanation follows the problem `gita clone --json`
reports: `signIn` lists the likely causes (organization approval of the Gita app first,
wrong account, not a member, no connection); `helper` says git never got a sign-in from
Gita (run `gita doctor --fix`); `sshKey` says the SSH key was refused.*

---

## 7. `gita gh`

```mermaid
flowchart TD
  A(["gita gh [--profile name] gh-arguments"]) --> B{"--profile given?"}
  B -->|"yes"| P["Use that profile"]
  B -->|"no"| C["Find the project's profile the way<br/>pushes do: folder and account rules"]
  C -->|"none"| X1["Exit 2: say which, with an example"]
  C --> P
  P --> D{"gh command would print the token?<br/>(auth token, auth status --show-token)"}
  D -->|"yes"| X2["Refused, exit 2"]
  D --> E{"Profile signed in?"}
  E -->|"no"| X3["Exit 1: gita sign-in --profile name"]
  E --> F["Start gh on the same terminal<br/>with GH_TOKEN = profile token<br/>(GITHUB_TOKEN removed)"]
  F --> G(["gh's own exit code"])
```

*Figure 7 – `gita gh` (`lib/cli/gh_command.dart`). The token only goes into gh's
environment for that one command; gh's own login isn't used or changed.*

---

## 8. From a change to a release

```mermaid
flowchart LR
  BR["Branch + PR into master"] --> CI["build.yml: tests (Linux, macOS),<br/>builds (Windows, macOS, Linux),<br/>packages, CLI smoke test"]
  CI --> M["Owner merges"]
  M --> V["Version PR: pubspec.yaml version<br/>and GitaCli.version"]
  V --> TAG["Tag vX.Y.Z"]
  TAG --> R["release.yml: tag = pubspec = CLI version?<br/>build → SHA256SUMS → gh release create<br/>(pre-release when the tag has a -suffix)"]
  R --> U(["Installers and company setup scripts<br/>pin X.Y.Z + SHA-256"])
```

*Figure 8 – Release flow (`.github/workflows/build.yml`, `release.yml`). `SHA256SUMS` is
added by PR #27, so scripts that pin a version can check new releases.*

---

## 9. History

| Date | PR / release | What |
|---|---|---|
| 2026-11-07 | 1.0.0 – 1.0.2 | First releases, installers, MIT licence (#19, #20) |
| 2026-11-09 | #21 | macOS: bundled command signed with the entitlement the Dart runtime needs (no more "Killed: 9") |
| 2026-11-09 | #22 | macOS test fixes; macOS tests block merges |
| 2026-11-09 | #23 | `gita gh` |
| 2026-11-09 | #24 | `gita` command on PATH for new terminals (`gita path`) |
| 2026-11-09 | #25 | Clone window offers the fix when a clone can't sign in; clone errors classified |
| 2026-11-09 | 1.0.3 | Release with #21–#25 |
| 2026-11-09 | #27 (open) | `gita onboard`, clean-up, old backups, `read:org`, `SHA256SUMS`, isolated smoke test |
