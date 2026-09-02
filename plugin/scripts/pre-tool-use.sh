#!/usr/bin/env bash
# PreToolUse hook: keep code discovery on NexusMind, not grep.
#
# The whole point of an indexed codebase is that "where is X / how is Y done"
# is a semantic lookup, not a tree scan. Left to its own devices an agent still
# reaches for grep/rg/find first, burning context reading files to locate code
# the index already knows. This hook denies those code-search calls and points
# the agent at `mcp__nexusmind__locate_code` / `search_code` instead.
#
# It denies ONLY discovery-shaped calls:
#   - the built-in `Grep` tool (always a code/content search)
#   - Bash `grep`/`rg`/`ripgrep`/`ag`/`ack`/`git grep`
#   - Bash `find … -name/-iname/-path/-regex` (locating files by name)
# Everything else — reading a file, `git log`, `ls`, `wc`, a grep inside a
# committed script the agent runs, piping `--help` into grep — is left alone.
#
# Escape hatches, because "always" must not mean "stuck":
#   - export NEXUSMIND_ALLOW_GREP=1  → the hook stands down entirely (a repo with
#     no index, or a deliberate text hunt through logs).
#   - put  # nexusmind:allow  in the command → allow that one call.
#
# Contract: PreToolUse reads the tool call as JSON on stdin and prints a JSON
# decision on stdout. `permissionDecision: "deny"` blocks the call and feeds the
# reason back to the model so it self-corrects.

set -euo pipefail

# A blanket operator override — no index, or an intentional non-code search.
if [[ "${NEXUSMIND_ALLOW_GREP:-}" == "1" ]]; then
  exit 0
fi

input="$(cat)"

# jq is how every other script in this plugin parses hook input; if it is not on
# PATH the hook must fail OPEN (allow) rather than wedge the session.
if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty')"

deny() {
  # $1: what was blocked, for the reason line.
  jq -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

REDIRECT="Use NexusMind instead of scanning the tree: call mcp__nexusmind__locate_code \
(ranked file paths for a query) to decide what to read, or mcp__nexusmind__search_code \
(ranked code chunks) when you need the code itself — same query, far less context. \
If this project is not indexed yet, call mcp__nexusmind__index_project first. \
If you genuinely need a text search that is NOT code discovery (logs, data files), \
re-run with NEXUSMIND_ALLOW_GREP=1 in the environment or add '# nexusmind:allow' to the command."

case "$tool_name" in
  Grep)
    deny "The Grep tool is disabled for code discovery. $REDIRECT"
    ;;
  Bash)
    cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
    # Per-command opt-out.
    if printf '%s' "$cmd" | grep -qF '# nexusmind:allow'; then
      exit 0
    fi
    # A search tool invoked as a command word: start of line, or after a pipe,
    # `;`, `&&`, `||`, `(`, or `xargs`. Anchored so it does not fire on a path
    # or flag that merely contains the letters (e.g. `./configure`, `--regexp`).
    search_re='(^|[|;&(]|&&|\|\||[[:space:]]xargs[[:space:]]+)[[:space:]]*(grep|egrep|fgrep|rg|ripgrep|ag|ack)([[:space:]]|$)'
    gitgrep_re='(^|[|;&(]|&&|\|\|)[[:space:]]*git[[:space:]]+grep([[:space:]]|$)'
    # `find … -name/-iname/-path/-regex`: locating files by name/path.
    find_re='(^|[|;&(]|&&|\|\|)[[:space:]]*find[[:space:]].*-(i?name|i?path|regex)([[:space:]]|$)'
    if printf '%s' "$cmd" | grep -qE "$search_re" \
       || printf '%s' "$cmd" | grep -qE "$gitgrep_re" \
       || printf '%s' "$cmd" | grep -qE "$find_re"; then
      deny "\`$cmd\` is a code search. $REDIRECT"
    fi
    ;;
esac

exit 0
