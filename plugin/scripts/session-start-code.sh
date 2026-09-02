#!/usr/bin/env bash
# SessionStart hook: decide, once per session, whether NexusMind code search is
# enforceable — and put code discovery on it from the first turn when it is.
#
# The PreToolUse hook denies grep for code discovery, but grep must stay a real
# fallback, not a wall: if the project has no code index, the index is stale, or
# we simply cannot confirm one this session, blocking grep would leave the agent
# with no way to find code. So this probe writes a per-session marker in exactly
# those cases and the PreToolUse hook stands down when it sees it. Enforcement
# only bites when there is a fresh index to enforce toward.
#
# stdout is injected as session context. Everything the probe does is kept off
# stdout so it cannot corrupt that context.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_helpers.sh
source "${SCRIPT_DIR}/_helpers.sh" 2>/dev/null || true

INPUT="$(cat)"
PYTHON_BIN="$(resolve_python 2>/dev/null || true)"

get() { # get <json-path-expr fallback> from INPUT, best-effort
  [[ -n "$PYTHON_BIN" ]] || { echo ""; return; }
  printf '%s' "$INPUT" | "$PYTHON_BIN" -c "import sys,json;d=json.load(sys.stdin);print(d.get('$1',''))" 2>/dev/null || echo ""
}
session_id="$(get session_id)"
cwd="$(get cwd)"
[[ -n "$cwd" ]] && cd "$cwd" 2>/dev/null || true

marker="${TMPDIR:-/tmp}/nexusmind-allow-grep-${session_id:-nosession}"
rm -f "$marker" 2>/dev/null || true   # start clean; only (re)create when falling back

BASE_URL="${NEXUSMIND_BASE_URL:-https://nexusmind-backend.fly.dev}"

allow_fallback() { # $1: human reason for the context block
  : > "$marker" 2>/dev/null || true
  cat <<CTX
## NexusMind — Code Search (fallback mode)

$1 — so for THIS session, grep/rg/find are allowed as a fallback for finding
code. Prefer \`mcp__nexusmind__index_project\` to build/refresh the index and
then \`mcp__nexusmind__locate_code\` / \`search_code\`; fall back to grep only
while the index is unavailable.
CTX
  exit 0
}

enforce() {
  cat <<'CTX'
## NexusMind — Code Search

This project's code is indexed in NexusMind. To find or understand code — where
something is defined, how a pattern is implemented, which files a change touches —
call `mcp__nexusmind__locate_code` (ranked file paths) or
`mcp__nexusmind__search_code` (ranked code chunks) FIRST, then read only what they
point to. Do NOT use grep/rg/find or the Grep tool for code discovery — those
calls are denied by a hook. Full detail: the nexusmind-code skill.
CTX
  exit 0
}

# Can we even probe? Without a key, jq/python, or curl we cannot confirm a usable
# index, and the whole point is not to block grep on an unconfirmed index.
if [[ -z "${NEXUSMIND_API_KEY:-}" ]] || ! command -v curl >/dev/null 2>&1 || [[ -z "$PYTHON_BIN" ]]; then
  allow_fallback "The code index could not be confirmed this session (no API key / tools)"
fi

PROJECT="$(detect_project 2>/dev/null || true)"
[[ -n "$PROJECT" ]] || allow_fallback "No project could be detected for the code index"

PROJECTS_JSON="$(curl -sf --max-time 6 -H "Authorization: Bearer ${NEXUSMIND_API_KEY}" \
  "${BASE_URL}/v1/code/projects" 2>/dev/null || true)"
[[ -n "$PROJECTS_JSON" ]] || allow_fallback "The code index service was unreachable"

# Decide freshness in one python pass: is PROJECT indexed, and is the newest git
# commit newer than last_indexed? Prints: MISSING | STALE | FRESH.
GIT_LAST="$(git -C "${cwd:-.}" log -1 --format=%cI 2>/dev/null || true)"
# The JSON goes through a temp FILE, not stdin: `python -` already takes its
# program from the heredoc on stdin, so a piped body would be discarded and
# every check would silently fall back.
PROJECTS_FILE="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/nexusmind-projects-$$.json")"
printf '%s' "$PROJECTS_JSON" > "$PROJECTS_FILE" 2>/dev/null || true
STATE="$("$PYTHON_BIN" - "$PROJECTS_FILE" "$PROJECT" "$GIT_LAST" <<'PY' 2>/dev/null || true
import sys, json, datetime
data = json.load(open(sys.argv[1]))
items = data.get('projects', data) if isinstance(data, dict) else data
name, git_last = sys.argv[2], (sys.argv[3] or '').strip()
p = next((x for x in items if x.get('name') == name), None)
if not p:
    print('MISSING'); raise SystemExit
files = p.get('indexed_files_count') or p.get('file_count') or 0
last = p.get('last_indexed')
if not files or not last:
    print('MISSING'); raise SystemExit
def parse(s):
    s = s.replace('Z', '+00:00')
    try: return datetime.datetime.fromisoformat(s)
    except Exception: return None
li, gl = parse(last), parse(git_last) if git_last else None
if li and gl and gl > li:
    print('STALE')
else:
    print('FRESH')
PY
)"
rm -f "$PROJECTS_FILE" 2>/dev/null || true

case "$STATE" in
  FRESH) enforce ;;
  STALE) allow_fallback "The code index is stale (newer commits than the last index)" ;;
  MISSING) allow_fallback "This project has no code index yet" ;;
  *) allow_fallback "The code index state could not be determined" ;;
esac
