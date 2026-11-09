#!/usr/bin/env bash
# Smoke test for the built `gita` command, run against a throwaway HOME so
# it never touches the real ~/.gitconfig or ~/.gita.
#
#   scripts/smoke_cli.sh path/to/gita
#   GITA="dart run bin/gita.dart" scripts/smoke_cli.sh
#
# Exits non-zero at the first failure.
set -euo pipefail

GITA=${1:-${GITA:-}}
if [ -z "$GITA" ]; then echo "usage: $0 <path-to-gita>" >&2; exit 2; fi

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
export HOME="$ROOT/home"
# Gita reads USERPROFILE on Windows, not HOME: without this the test would
# change the real ~/.gita and ~/.gitconfig of whoever runs it.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*)
    WINDOWS=1
    USERPROFILE=$(cygpath -w "$HOME"); export USERPROFILE
    ;;
  *) WINDOWS=0 ;;
esac
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
mkdir -p "$HOME" "$ROOT/work/api"

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; exit 1; }

# Refuse to go on unless Gita sees the empty throwaway home: a profile here
# means it is reading someone's real setup.
case "$($GITA profiles --json 2>/dev/null)" in
  *'"profiles": []'* | *'"profiles":[]'*) ;;
  *) echo "FAIL - gita doesn't see the throwaway home (it found existing profiles); stopping before changing anything." >&2
     exit 1 ;;
esac
run() { # run <description> <command...>: print output on failure
  local what=$1; shift
  local out
  if ! out=$($GITA "$@" 2>&1); then echo "$out" >&2; fail "$what"; fi
  LAST=$out; pass "$what"
}
expect() { case "$LAST" in *"$1"*) ;; *) echo "$LAST" >&2; fail "output should contain: $1";; esac; }

run "version" --version
run "help" --help
expect "gita"

git init -q "$ROOT/work/api"
run "add a work profile" profile add --name work --email work@example.com --label Work
run "folder rule" rule add --profile work --folder "$ROOT/work"
run "rule list" rule list --json
expect "work"
run "profiles --json" profiles --json
expect "work@example.com"
run "which (project under the rule)" which "$ROOT/work/api" --json
expect "work@example.com"
run "doctor --json" doctor --json
run "install the safety check" guard install "$ROOT/work/api"
run "safety check status" guard status "$ROOT/work/api"
run "remove the safety check" guard remove "$ROOT/work/api"

# Git runs `gita credential` as a credential helper. With no token saved it
# must tell git to stop (quit=1), not hang or print a password.
# Windows keeps sign-ins in Credential Manager, shared by the whole account
# and not moved by changing the home folder, so checks that read sign-ins
# run only on macOS and Linux CI machines.
if [ "$WINDOWS" = 1 ]; then
  echo "skip - sign-in checks (Windows Credential Manager can't be isolated)"
else
PROFILE_ID=$($GITA profiles --json | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p' | head -1)
[ -n "$PROFILE_ID" ] || fail "profile id not found in profiles --json"
OUT=$(printf 'protocol=https\nhost=github.com\n\n' | $GITA credential --profile "$PROFILE_ID" get 2>/dev/null)
case "$OUT" in
  *quit=1*) pass "credential helper stops when no token is saved" ;;
  # Never echo the answer: if it is not quit=1 it may hold a real password.
  *) fail "credential get didn't answer quit=1 (output hidden)" ;;
esac
fi

# The MCP server answers the protocol handshake.
OUT=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' | $GITA mcp 2>/dev/null | head -1)
case "$OUT" in *'"result"'*) pass "mcp initialize";; *) fail "mcp initialize: $OUT";; esac

# gita onboard: a dry run changes nothing; a real run (no sign-in, no repos)
# adds the profiles and finishes with a summary; a second run keeps them.
cat >"$ROOT/onboarding.json" <<'EOF'
{"format": 1, "name": "Smoke Co", "tools": {"git": "required"}, "cleanup": "skip",
 "accounts": [{"id": "lab", "label": "Smoke Lab", "emailDomain": "lab.example"}],
 "steps": [{"type": "signIn", "account": "lab"}, {"type": "doctor"}]}
EOF
run "onboard --dry-run" onboard "$ROOT/onboarding.json" --dry-run --name Smoke --email lab=dev@lab.example
expect "Dry run finished. Nothing was changed."
case "$($GITA profiles --json)" in *dev@lab.example*) fail "dry run added a profile";; *) pass "dry run added nothing";; esac
run "onboard" onboard "$ROOT/onboarding.json" --name Smoke --email lab=dev@lab.example --skip-sign-in
expect "==> Summary"
run "onboard again" onboard "$ROOT/onboarding.json" --name Smoke --email lab=dev@lab.example --skip-sign-in
expect "Profile for dev@lab.example already exists"
if $GITA onboard "$ROOT/onboarding.json" --name Smoke --email lab=dev@gmail.com >/dev/null 2>&1; then
  fail "onboard accepted an email at the wrong domain"
else
  pass "onboard stops on an email at the wrong domain"
fi

# gita gh: with no sign-in saved, it says how to sign in (exit 1) and never runs gh.
if [ "$WINDOWS" = 0 ]; then
  if out=$($GITA gh --profile work pr list 2>&1); then fail "gh ran without a sign-in"; fi
  case "$out" in *"gita sign-in --profile"*) pass "gh asks to sign in first";; *) fail "gh without sign-in (output hidden)";; esac
fi

echo "All smoke checks passed."
