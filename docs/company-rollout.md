# Rolling out Gita at a company

This guide is for a company where each developer has two GitHub accounts,
for example a personal one and a work one, and every project must commit
and push with the right one. It has two parts: what the person setting it
up does once, and what each developer does.

Nobody needs to know git well. Gita does the git settings.

## What Gita does for each developer

- Work projects commit with the work email and push as the work account.
  Personal projects use the personal ones. This works over HTTPS and SSH.
- It decides by **where the project comes from** (your company's GitHub
  organizations) and by **which folder it's in**. A work project is still
  treated as work if someone puts it in the wrong folder.
- Every project Gita knows about gets a **safety check**. A commit or push
  with the wrong account is stopped before it happens, and a message says
  what to do.
- Plain `git`, editors and AI tools all follow the same settings, because
  Gita writes them into git's own configuration.

## Part 1: for whoever sets it up (once)

### 1. Write the company file

Make a file called, say, `acme-gita.json`:

```json
{
  "name": "Acme",
  "emailDomains": ["acme.com"],
  "github": { "owners": ["acme", "acme-labs"] }
}
```

- `name`: shown to developers.
- `emailDomains`: the end of your work email addresses. Gita uses it to
  find each developer's work profile and to warn about commits made with
  other emails.
- `github.owners`: your GitHub organizations, as they appear in project
  addresses (`github.com/acme/...` means `acme`).
- On GitHub Enterprise, add the host: `"github": {"host":
  "github.acme.com", "owners": ["platform"]}`.

### 2. Share two things

Put these where everyone can get them, for example the team wiki or chat:

1. The Gita download for their computer, from the
   [Releases](https://github.com/naseebnaushad/gita/releases) page.
2. The company file from step 1.

### 3. Send everyone the steps in Part 2

You can copy Part 2 into a message as it is.

## Part 2: for each developer (about 10 minutes)

1. **Install Gita.** Unpack the download and open **gita**.
   - On a Mac, the first time: right-click the app, choose **Open**, then
     **Open** again.
2. **Let Gita look at your computer.** The first time it opens, it looks
   at the projects you already have and suggests one profile per email:
   one for work, one for personal. Check the names and emails, untick
   anything wrong, and press **Set these up**. Nothing changes before
   you press it.
   - If you have no projects yet, add the two profiles yourself on
     **Profiles** (name, email, GitHub account).
3. **Sign in to GitHub for each profile.** Gita offers **Sign in with
   GitHub** for each profile right after step 2. (Later: open the profile
   on **Profiles**.) Gita shows a short code: enter it on the GitHub
   page that opens. **Sign in to GitHub with the matching account** first
   (work account for the work profile). A private browser window makes
   this easier.
4. **Import the company file.** On **Rules**, press **Import company
   setup** and choose the file. Gita picks your work profile by its email.
5. **Check.** Open **Doctor**. If it lists anything, press the fix
   button next to it, or follow what it says.

That's it. From now on:

- **Downloading a project:** use **Clone a project** on the Dashboard and
  paste the address from GitHub's green **Code** button. Gita picks the
  account and puts the project in the right place.
- **Projects you already had** were added to the Dashboard in step 2.
  Add any others with **Add repo**.
- If a commit or push is stopped, read the message: it says which
  account the project belongs to and the one thing to do.

### Using an AI coding tool?

If you use Claude Code, connect it to Gita once, so it checks with Gita
before it commits, pushes or clones. Either type these two lines into
Claude Code:

```
/plugin marketplace add naseebnaushad/gita
/plugin install gita@gita
```

or run this one command:

- Windows: open **Command Prompt** and run
  `%USERPROFILE%\.gita\bin\gita.exe mcp add-to-claude`
- macOS or Linux: open **Terminal** and run
  `~/.gita/bin/gita mcp add-to-claude`

(Do one or the other, not both.)

Once it's connected, Claude can also do the setup in Part 2 for you. Put
the company file somewhere on your computer and tell Claude something like:

> Set up Gita for me. The company file is in my Downloads folder.

Claude finds your accounts, asks which ones to set up, and tells you
before each change. When a profile needs to sign in to GitHub, Claude
gives you a code to enter on github.com. You never give Claude your
password.

## Questions people ask

**Will this change my existing projects?** Only their git settings for
name, email and sign-in, and only for projects that match a rule. Your
files and history are not touched. Commits made before keep their old
email. If one of those hasn't been pushed yet, the push check says how to
fix it.

**What if a project is both?** The strongest rule wins: a rule for a
single project beats an organization rule, which beats a folder rule.

**Where are the settings?** In `~/.gita` (profiles, rules) and in a
marked block inside `~/.gitconfig`. GitHub sign-ins are stored in the
computer's password store (Keychain, Credential Manager or libsecret),
never in a plain file.

**How do I check one project from a terminal?** Run
`gita which` inside it (the full path is as in the AI section above). It
says which account the project should use and which it uses now.
