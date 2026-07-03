#!/usr/bin/env bash
# post-compaction.sh — NexusMind Claude Code plugin: PostCompact hook
# Outputs recovery instructions after a compaction event.
# Unlike SessionStart, PostCompact does NOT auto-inject plain stdout as
# context — it requires the structured hookSpecificOutput JSON envelope:
#   {"hookSpecificOutput":{"hookEventName":"PostCompact","additionalContext":"..."}}
# Plain stdout under PostCompact is silently discarded by Claude Code.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_helpers.sh
source "${SCRIPT_DIR}/_helpers.sh"

# Real python3/python/py may all be missing or Windows Store stubs; degrade
# gracefully everywhere below rather than crashing under set -e.
PYTHON_BIN="$(resolve_python || true)"

# ---------------------------------------------------------------------------
# Parse stdin JSON
# ---------------------------------------------------------------------------
INPUT="$(cat)"

session_id="$(echo "$INPUT" | $PYTHON_BIN -c "import sys,json; d=json.load(sys.stdin); print(d.get('session_id',''))" 2>/dev/null || true)"
cwd="$(echo "$INPUT" | $PYTHON_BIN -c "import sys,json; d=json.load(sys.stdin); print(d.get('cwd',''))" 2>/dev/null || true)"

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
NEXUSMIND_BASE_URL="${NEXUSMIND_BASE_URL:-https://nexusmind-backend.fly.dev}"

# ---------------------------------------------------------------------------
# emit_context: wraps text in the hookSpecificOutput JSON envelope PostCompact
# requires (plain stdout is discarded under this event, unlike SessionStart).
# Built via python3's json.dumps so we never hand-roll JSON string escaping.
# ---------------------------------------------------------------------------
emit_context() {
  # $1 = context text
  if [[ -z "$PYTHON_BIN" ]]; then
    # Can't safely build the JSON envelope without a real interpreter —
    # emitting raw text would be silently discarded anyway, so emit nothing.
    return 0
  fi
  $PYTHON_BIN -c "
import json, sys
print(json.dumps({
    'hookSpecificOutput': {
        'hookEventName': 'PostCompact',
        'additionalContext': sys.argv[1],
    }
}))
" "$1" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Guard: API key required
# ---------------------------------------------------------------------------
if [[ -z "${NEXUSMIND_API_KEY:-}" ]]; then
  emit_context "NexusMind NOT CONNECTED after compaction: NEXUSMIND_API_KEY is not set."
  exit 0
fi

# ---------------------------------------------------------------------------
# Guard: backend health check
# ---------------------------------------------------------------------------
if ! curl -sf --max-time 5 "${NEXUSMIND_BASE_URL}/v1/health" &>/dev/null; then
  emit_context "NexusMind NOT CONNECTED after compaction: backend is unreachable."
  exit 0
fi

# ---------------------------------------------------------------------------
# Detect project
# ---------------------------------------------------------------------------
if [[ -n "$cwd" ]]; then
  pushd "$cwd" &>/dev/null || true
fi

PROJECT="$(detect_project)"

if [[ -n "$cwd" ]]; then
  popd &>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Fetch recent memories
# ---------------------------------------------------------------------------
NEXUSMIND_SESSION_RECENT_LIMIT="${NEXUSMIND_SESSION_RECENT_LIMIT:-5}"

RECENT_MEMORIES=""
MEMORIES_RESPONSE="$(curl -sf --max-time 10 \
  -H "Authorization: Bearer ${NEXUSMIND_API_KEY}" \
  -H "Content-Type: application/json" \
  "${NEXUSMIND_BASE_URL}/v1/memory?limit=${NEXUSMIND_SESSION_RECENT_LIMIT}" 2>/dev/null || true)"

if [[ -n "$MEMORIES_RESPONSE" && -n "$PYTHON_BIN" ]]; then
  RECENT_MEMORIES="$(echo "$MEMORIES_RESPONSE" | $PYTHON_BIN -c "
import sys, json
try:
    data = json.load(sys.stdin)
    items = data if isinstance(data, list) else data.get('memories', data.get('items', data.get('data', [])))
    lines = []
    for m in items[:int(sys.argv[1])]:
        project = m.get('project', '') or m.get('metadata', {}).get('project', '')
        tool    = m.get('tool', '') or m.get('metadata', {}).get('tool', '')
        content = m.get('content', m.get('text', ''))
        label   = '/'.join(filter(None, [project, tool]))
        snippet = content[:120].replace('\n', ' ')
        lines.append(f'- [{label}] {snippet}')
    print('\n'.join(lines))
except Exception:
    pass
" "${NEXUSMIND_SESSION_RECENT_LIMIT}" 2>/dev/null || true)"
fi

# ---------------------------------------------------------------------------
# Build the recovery text, then emit it via the hookSpecificOutput envelope.
# ---------------------------------------------------------------------------
CONTEXT_TEXT="$(cat <<PROTOCOL
## NexusMind — Post-Compaction Recovery (project: ${PROJECT})

Context was compacted. FIRST: call store_memory (type="session_summary") with what was in progress. THEN call get_context or list_memories with project="${PROJECT}" as a filter to recover history — never search_memory("${PROJECT}"). Full protocol: nexusmind-memory skill.
PROTOCOL
)"

if [[ -n "$RECENT_MEMORIES" ]]; then
  CONTEXT_TEXT="$(cat <<MEMORIES
${CONTEXT_TEXT}

### Recent Team Memories (last ${NEXUSMIND_SESSION_RECENT_LIMIT})
${RECENT_MEMORIES}
MEMORIES
)"
fi

emit_context "$CONTEXT_TEXT"
