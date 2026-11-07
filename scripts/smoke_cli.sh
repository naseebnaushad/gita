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
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
mkdir -p "$HOME" "$ROOT/work/api"

pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; exit 1; }
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
PROFILE_ID=$($GITA profiles --json | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p' | head -1)
[ -n "$PROFILE_ID" ] || fail "profile id not found in profiles --json"
OUT=$(printf 'protocol=https\nhost=github.com\n\n' | $GITA credential --profile "$PROFILE_ID" get 2>/dev/null)
case "$OUT" in *quit=1*) pass "credential helper stops when no token is saved";; *) fail "credential get: $OUT";; esac

# The MCP server answers the protocol handshake.
OUT=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' | $GITA mcp 2>/dev/null | head -1)
case "$OUT" in *'"result"'*) pass "mcp initialize";; *) fail "mcp initialize: $OUT";; esac

echo "All smoke checks passed."
