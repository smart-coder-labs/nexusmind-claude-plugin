#!/usr/bin/env bash
# SessionStart hook: decide, once per session, whether NexusMind code search is
# enforceable — and put code discovery on it from the first turn when it is.
#
# It emits one short block telling the agent whether the index is usable, and
# nothing else. There is no longer a PreToolUse hook denying grep: measurement
# showed the denial did not change what the agent did, only what it cost — it
# lost a round trip to the refusal and then ran the same search through the
# escape hatch. What remains is a statement of fact the agent can act on.
#
# stdout is injected as session context. Everything the probe does is kept off
# stdout so it cannot corrupt that context.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_helpers.sh
source "${SCRIPT_DIR}/_helpers.sh" 2>/dev/null || true

# A hook does not inherit the MCP server's env; resolve the key from where the
# client keeps it, or every check below silently decides NexusMind is unconfigured.
hydrate_nexusmind_env 2>/dev/null || true

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

# A hook does not inherit the MCP server's `env`, so the key may be configured
# and still absent from this process. resolve_nexusmind_env looks where the client
# itself looks; without it a correctly configured user silently lost enforcement.
NM_KEY=""
NM_URL=""
if IFS=$'\t' read -r NM_KEY NM_URL < <(resolve_nexusmind_env 2>/dev/null); then :; fi
BASE_URL="${NM_URL:-${NEXUSMIND_BASE_URL:-https://nexusmind-backend.fly.dev}}"

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
point to — it is fewer round trips than scanning the tree. Full detail: the
nexusmind-code skill.
CTX
  exit 0
}

# Can we even probe? Without a key, jq/python, or curl we cannot confirm a usable
# index, and the whole point is not to block grep on an unconfirmed index.
if [[ -z "$NM_KEY" ]]; then
  allow_fallback "No NexusMind API key is reachable from this session — checked the \
environment, ~/.claude/settings.json, ~/.claude.json and the Codex config. Run \
\`npx @smart-coder-labs/nexusmind-mcp setup\` (or \`… doctor\` to see where the key lives)"
fi
if ! command -v curl >/dev/null 2>&1 || [[ -z "$PYTHON_BIN" ]]; then
  allow_fallback "The code index could not be confirmed this session (curl or python missing)"
fi

PROJECT="$(detect_project 2>/dev/null || true)"
[[ -n "$PROJECT" ]] || allow_fallback "No project could be detected for the code index"

PROJECTS_JSON="$(curl -sf --max-time 6 -H "Authorization: Bearer ${NM_KEY}" \
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
