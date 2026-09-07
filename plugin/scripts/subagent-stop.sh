#!/usr/bin/env bash
# subagent-stop.sh — NexusMind Claude Code plugin: SubagentStop hook (async)
# Quality-gated passive capture: only stores outputs that contain decision-like
# keywords. Both Claude plugin repos ship this file byte-identical.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_helpers.sh
source "${SCRIPT_DIR}/_helpers.sh"

# A hook does not inherit the MCP server's env; resolve the key from where the
# client keeps it, or every check below silently decides NexusMind is unconfigured.
hydrate_nexusmind_env 2>/dev/null || true

if [[ -z "${NEXUSMIND_API_KEY:-}" ]]; then
  exit 0
fi

# Real python3/python/py may all be missing or Windows Store stubs; degrade
# gracefully everywhere below rather than crashing under set -e.
PYTHON_BIN="$(resolve_python || true)"

INPUT="$(cat)"
if [[ -z "$PYTHON_BIN" ]]; then
  # Can't parse the hook payload or build the JSON store payload without a
  # real interpreter — nothing useful to do, exit clean.
  exit 0
fi

subagent_output="$(echo "$INPUT" | $PYTHON_BIN -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('stdout', ''))
except Exception:
    pass
" 2>/dev/null || true)"

# Skip very short outputs
if [[ -z "$subagent_output" || "${#subagent_output}" -lt 100 ]]; then
  exit 0
fi

# Quality gate: must contain at least one decision-like keyword
# Words that signal a REASON, not an action.
#
# The previous list matched `added|changed|implemented|removed|note` — words
# that appear in every turn that touches code — so the gate fired on routine
# work and the agent saved memories for it. Measured on a throwaway worktree:
# five memories, two of them describing a constant and a bug fix that exist in
# no real repository, and one turn spent answering "Memoria guardada." instead
# of reporting the work.
#
# What is worth persisting is why something is the way it is: a choice and what
# it beat, a root cause, a surprise. Those leave different traces than "added a
# route", and this list matches only those.
KEYWORD_RE='decided|decision|chose|tradeoff|trade-off|instead of|root cause|turns out|it turned out|gotcha|caveat|convention|architecture|discovered|surprising|the reason|why we|deliberately|on purpose'
if ! echo "$subagent_output" | grep -iEq "$KEYWORD_RE"; then
  exit 0
fi

NEXUSMIND_BASE_URL="${NEXUSMIND_BASE_URL:-https://nexusmind-backend.fly.dev}"
PROJECT="$(detect_project)"

PAYLOAD="$($PYTHON_BIN -c "
import json, sys
content = sys.argv[1]
project = sys.argv[2]
if len(content) > 2000:
    content = content[:2000] + '... [truncated]'
print(json.dumps({
    'title': 'Subagent: ' + project,
    'content': content,
    'type': 'discovery',
    'tool': 'claude-code-subagent',
    'project': project,
}))
" "$subagent_output" "$PROJECT" 2>/dev/null || true)"

if [[ -n "$PAYLOAD" ]]; then
  curl -sf --max-time 10 \
    -X POST \
    -H "Authorization: Bearer ${NEXUSMIND_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "${NEXUSMIND_BASE_URL}/v1/memory/store" &>/dev/null || true
fi

exit 0
