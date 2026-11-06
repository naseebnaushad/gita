<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/branding/logo-dark.png">
  <img alt="Gita" src="assets/branding/logo.png" width="360">
</picture>

A cross-platform desktop app (macOS, Windows, Linux) for managing multiple Git
identities — e.g. Work vs. Personal — and preventing the class of bug where a
commit or push ends up using the wrong account.

Gita is not a Git GUI: there's no commit/branch/merge/diff view. It's an
identity, credential, and safety-net manager that sits on top of native Git
mechanisms (`includeIf`, SSH host aliases, hooks) and never reimplements
plumbing that `git config`, `git remote`, etc. already do.

## Core idea

Assign a profile to a folder once. Gita keeps `~/.gitconfig`, `~/.ssh/config`,
and per-repo hooks in sync, and flags — or eventually blocks — any commit or
push where the effective identity doesn't match what's expected for that repo.

## Features

- **Set up in one go** — the first time Gita opens (or any time from
  **Scan this computer** on Profiles), it looks through the usual project
  folders, sees which email each project commits with, and suggests one
  profile per account with the folders that belong to it and any matching
  SSH key. People untick or rename what they want, press **Set these up**,
  and Gita makes the profiles and folder rules, adds the projects to the
  Dashboard with the safety check, and offers **Sign in with GitHub** for
  each profile. Nothing changes before that button.
- **Clone with the right account** — **Clone a project** on the Dashboard
  (or `gita clone`) takes the address from GitHub's green Code button,
  picks the profile whose GitHub account owns the project, and downloads
  it with that profile's sign-in or SSH key. The new project is set up to
  keep using that profile, gets the safety check, and appears on the
  Dashboard.
- **Profiles** — bundle a `user.name`/`user.email`, optional signing key, and
  an optional GitHub access token that HTTPS pushes from that profile's
  projects sign in with (stored in the OS keychain/Credential
  Manager/libsecret, never in a plain file) per identity.
- **SSH keys** — one key per profile, made and added to the GitHub account
  by Gita, so `git@github.com:` pushes also use the right account.
- **Rules** — map a folder to a profile; Gita writes a managed `includeIf`
  block into `~/.gitconfig` so Git resolves the right identity per repo
  automatically.
- **Dashboard** — lists tracked repos with their assigned profile, effective
  email, remote, and a mismatch badge. When Gita can fix a problem itself,
  a wrench button sits next to the badge: it adds a missing safety check,
  removes an email a project set for itself (so the profile's applies), or
  re-applies Gita's git settings.
- **Doctor** — scans profiles/rules/keys for configuration drift (e.g. a
  profile with commit signing enabled but no matching GPG key on this
  machine) before it turns into a failed commit or push. Most problems come
  with a one-click fix: turn off signing, stop using a missing SSH key or
  set up a new one, delete a rule whose profile is gone, sign in with
  GitHub, or install the `gita` command.

## Getting started

```
flutter pub get
flutter run -d macos   # or -d windows / -d linux
```

Run the test suite with:

```
flutter test
```

## Command line

Gita also ships a small `gita` command for git hooks, scripts and AI
coding agents, which can't use the desktop app. It reads the same profiles
and rules the app saves.

```
gita scan [folder...]  # suggest profiles from the projects on this computer (changes nothing)
gita clone <address> [folder] [--profile <name>]   # download a project with the right account
gita which [folder]    # which account should this project use, and which is it using?
gita check [folder]    # same, but exits 1 if it would commit/push as the wrong account
gita doctor            # find setup problems before they break a commit or push
gita profiles          # list profiles: email, GitHub account, sign-in, SSH key, folders
gita sign-in --profile <name>   # sign a profile in to GitHub (shows a code to enter)
gita guard install [folder]   # add the safety check to a project (the app does this for you)
gita guard remove [folder]    # take it out again
gita guard status [folder]    # is it in place?
```

Add `--json` to any command for machine-readable output. Exit codes:
`0` all good, `1` problem found, `2` couldn't run (bad arguments, or not a
git project).

Build it with:

```
dart build cli          # -> build/cli/<platform>/bundle/bin/gita(.exe)
```

(`dart compile exe` doesn't work here because some Flutter plugin
dependencies use native build hooks; `dart build cli` handles them.)

### Setting up from the projects already on the computer

`gita scan` (and **Scan this computer** in the app) looks in the usual
project folders under your home folder (`StudioProjects`, `source/repos`,
`code`, `dev`, `projects`, `git`, `Documents/GitHub`, `Desktop` and so
on), or in the folders you name. For each project it reads the email
the project's recent commits used, and any email set inside the project.
Then:

- Each email becomes a suggested profile. The one in `~/.gitconfig` is
  marked as used where no rule applies.
- A folder goes to a profile when every project in it uses that email;
  otherwise each project gets its own rule. The home folder and drive
  roots are never used.
- An SSH key is matched through `~/.ssh/config` or the email in its
  `.pub` file.
- Emails that are already a profile are shown as such, so running it
  again only adds what is new.

It looks 4 folders deep, skips hidden folders and `node_modules`, `build`
and similar, and stops at 400 projects.

### Cloning with the right account

A clone is the one moment no folder rule can help yet: the project isn't
on the computer, so git would use whatever account it finds first.
`gita clone` (and **Clone a project** in the app) avoids that:

1. **Which account.** `--profile` if given; otherwise the profile whose
   GitHub account matches the owner in the address (`github.com/acme/...`
   -> the profile signed in as `acme`); otherwise the profile of the
   folder rule covering the destination. If none fits, it asks for
   `--profile` instead of guessing.
2. **Where.** The folder given, or `<profile's rule folder>/<name>`, or
   the first usual project folder.
3. **The download** runs with that profile's settings for just this one
   command (`git -c include.path=~/.gita/profiles/<id>.gitconfig clone`),
   so HTTPS uses its GitHub sign-in and SSH addresses use its key. Git is
   never left waiting for a password: if the sign-in is missing or wrong,
   Gita says which profile to sign in.
4. **After.** If no rule already gives the folder that profile, Gita adds
   one for exactly that project. Then it adds the safety check and puts
   the project on the Dashboard (`--no-track` skips those two).

```
gita clone https://github.com/acme/api.git                 # account worked out from "acme"
gita clone git@github.com:acme/api.git ~/work/api --profile Work
```

### The safety check: wrong-account commits and pushes are stopped

When you add a project on the Dashboard, Gita puts a small safety check
into it (git `pre-commit` and `pre-push` hooks). From then on:

- A **commit** made with the wrong email for that project is stopped
  before it happens, with a message saying which account the project
  belongs to and what to do.
- A **push** that contains commits made with another email (for example
  ones made before the project had a rule) is stopped. The message lists
  those commits and gives the one command that re-makes them with the
  right email (`git commit --amend --no-edit --reset-author` for a single
  latest commit, or a `git rebase ... --exec` that fixes them all). Only
  commits no remote has yet are checked, so teammates' commits never
  count.
- To get past the check just once, add `--no-verify` to the `git commit`
  or `git push`.

Details for the curious:

- A hook the project already had is kept as `pre-commit.local` /
  `pre-push.local` and still runs after Gita's check. Removing the check
  (`gita guard remove`) puts it back.
- Projects that keep hooks somewhere else (`core.hooksPath`, for example
  husky) are left alone; the app tells you so when you add them.
- If the `gita` command isn't installed, the hooks let everything through,
  so uninstalling Gita never blocks anyone.
- Projects no rule covers are never blocked.
- The Dashboard and `gita check` show a warning for a tracked project
  without the check, and Gita updates checks written by an older version
  each time it starts.

### HTTPS pushes with the right account

Git normally remembers one GitHub login per computer, so every HTTPS push
uses that account, whichever project it comes from. Gita fixes this per
profile. Once a profile has an access token saved and the `gita` command is
installed at `~/.gita/bin/gita` (`gita.exe` on Windows), the profile's
include file tells git to sign in to `https://github.com` through
`gita credential --profile <id>`. Git runs that command itself, and it
answers with that profile's token from the OS credential store.

The managed section looks like this:

```
[credential "https://github.com"]
    helper =
    helper = "!\"/home/me/.gita/bin/gita\" credential --profile <id>"
```

The empty `helper =` stops git from falling back to a login it remembered
for another account. Projects outside the profile's folders, and other
hosts, keep using whatever sign-in the computer already had.

If no token is saved, the push stops with a message telling the person to
add one in Gita. If GitHub rejects the token, the push says so and explains
how to replace it. Doctor (in the app and `gita doctor`) warns about
profiles with no token, and about tokens saved while the `gita` command is
not installed yet.

Gita installs the command by itself. Windows and Linux builds of the app
carry a copy in a `cli` folder next to the app, and every time Gita starts
it copies that to `~/.gita/bin` if it is missing or out of date, then
rewrites the profiles' git settings so saved sign-ins start working.
Nobody has to install anything by hand.

The build does this through a step at the end of `windows/CMakeLists.txt`
and `linux/CMakeLists.txt`, which runs `dart build cli` (about 5 seconds).
macOS builds don't include it yet; on a Mac, install it by hand:

```
dart build cli
mkdir -p ~/.gita/bin && cp build/cli/*/bundle/bin/gita ~/.gita/bin/
```

then open each profile in Gita and press Save again.

#### Signing in from the command line

`gita sign-in` does the same as **Sign in with GitHub** in the app, for
people who live in a terminal or set up machines with a script:

```
gita sign-in --profile Work
```

1. It prints a short code and opens github.com/login/device.
2. Sign in there as the GitHub account for that profile, enter the code and
   press Authorize.
3. Gita saves the sign-in, remembers which GitHub account it is, and turns
   on HTTPS pushes for the profile's folders.

`--profile` takes the profile's name or id (`gita profiles` lists them).
`--no-browser` only prints the steps. To use a token you already have
instead, pipe it in:

```
echo "$TOKEN" | gita sign-in --profile Work --with-token
```

If GitHub refuses the token, nothing is saved and the command says so. If
the account's main email isn't the one the profile commits with, the
command points that out, because GitHub then won't link the commits to the
account unless that email is added to it.

### SSH pushes with the right account

For projects whose remote looks like `git@github.com:org/repo.git`, press
**Set up SSH** in a profile. Gita:

1. makes a new key for that profile, `~/.ssh/gita_<profile>` (ed25519, no
   passphrase, so pushes never stop to ask for one);
2. adds GitHub's published host keys to `~/.ssh/known_hosts` if they
   aren't there, so the first push doesn't ask "Are you sure you want to
   continue connecting?";
3. adds the key to the profile's GitHub account, if the profile is signed
   in with GitHub. Otherwise it shows the key with **Copy key** and **Open
   GitHub** buttons and three short steps;
4. checks which account GitHub sees for the key, and warns if it is not
   the profile's account.

The profile's include file then tells git to use that key:

```
[core]
    sshCommand = "ssh -i \"/home/me/.ssh/gita_work\" -o IdentitiesOnly=yes"
```

So remotes stay as they are: no host aliases, no rewritten URLs.
`IdentitiesOnly=yes` stops git from using keys loaded in an SSH agent,
which belong to whichever account they were made for. **Check** in the
profile runs the account check again at any time; **Remove** takes the
key off the profile but leaves the files in `~/.ssh`.

Profiles signed in before Gita asked for `write:public_key` get the
manual steps; signing in again lets Gita add keys by itself.

### Sign in with GitHub

Instead of creating and pasting a token, people can press **Sign in with
GitHub** in a profile. Gita shows a short code, copies it, and opens
github.com/login/device; they paste the code, press Authorize, and Gita
saves the resulting token for that profile and shows which account it is
(`Signed in as @name`). New profiles also get their name and email filled
in from the GitHub account.

The token asks for `repo` (push to private repos), `workflow` (push
changes to `.github/workflows`), `read:user` and `user:email` (to show
the account and fill in the email), and `write:public_key` (to add the
profile's SSH key to the account).

Gita signs in through its own GitHub OAuth app, "Gita"
(client ID `Ov23licOLgsWLhLzch9w`, built in, nothing to set up). On
GitHub's approval page people see "Gita" asking for those permissions.

To use a different OAuth app instead (for example one owned by your
organization):

1. On GitHub, open **Settings → Developer settings → OAuth Apps → New
   OAuth App** (for a company, create it under the organization's
   settings).
2. Name it `Gita`. Homepage URL: this repository. Callback URL: the same
   (device flow doesn't use it, but GitHub requires one).
3. Tick **Enable Device Flow** and register the app. No client secret is
   needed.
4. Copy the **Client ID** and build Gita with it:

   ```
   flutter build windows --dart-define=GITA_GITHUB_CLIENT_ID=<client id>
   ```

   or, without rebuilding, set the `GITA_GITHUB_CLIENT_ID` environment
   variable before starting Gita.

Building with `--dart-define=GITA_GITHUB_CLIENT_ID=` (empty) hides the
button, leaving only "paste a token".

If the organization restricts OAuth app access, an owner approves Gita
once under **Organization settings → Third-party access**; until then
pushes to that organization's private repos are refused.

Tokens live in Windows Credential Manager, the macOS login Keychain, or
libsecret on Linux (which needs `secret-tool`, from the `libsecret-tools`
package), filed under `gita`. Tokens saved by earlier versions of Gita move
there automatically the first time the app reads them.

Gita stores its own state (profiles, rules, tracked repos) as flat JSON under
`~/.gita/`, plus one generated `.gitconfig` fragment per profile. It never
hand-edits your `~/.gitconfig` outside a clearly delimited managed block.
