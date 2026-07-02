#!/usr/bin/env bash
# post-compaction.sh — NexusMind Claude Code plugin: SessionStart (compact matcher) hook
# Outputs additionalContext after a compaction event with recovery instructions.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_helpers.sh
source "${SCRIPT_DIR}/_helpers.sh"

# ---------------------------------------------------------------------------
# Parse stdin JSON
# ---------------------------------------------------------------------------
INPUT="$(cat)"

session_id="$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('session_id',''))" 2>/dev/null || true)"
cwd="$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('cwd',''))" 2>/dev/null || true)"

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
NEXUSMIND_BASE_URL="${NEXUSMIND_BASE_URL:-https://nexusmind-backend.fly.dev}"

# ---------------------------------------------------------------------------
# Guard: API key required
# ---------------------------------------------------------------------------
if [[ -z "${NEXUSMIND_API_KEY:-}" ]]; then
  cat <<'EOF'
<!-- NexusMind NOT CONNECTED after compaction: NEXUSMIND_API_KEY is not set. -->
EOF
  exit 0
fi

# ---------------------------------------------------------------------------
# Guard: backend health check
# ---------------------------------------------------------------------------
if ! curl -sf --max-time 5 "${NEXUSMIND_BASE_URL}/v1/health" &>/dev/null; then
  cat <<'EOF'
<!-- NexusMind NOT CONNECTED after compaction: backend is unreachable. -->
EOF
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

if [[ -n "$MEMORIES_RESPONSE" ]]; then
  RECENT_MEMORIES="$(echo "$MEMORIES_RESPONSE" | python3 -c "
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
# Output additionalContext with compaction-specific recovery instructions
# ---------------------------------------------------------------------------
cat <<PROTOCOL
## NexusMind — Post-Compaction Recovery (project: ${PROJECT})

Context was compacted. FIRST: call store_memory (type="session_summary") with what was in progress. THEN call get_context or list_memories with project="${PROJECT}" as a filter to recover history — never search_memory("${PROJECT}"). Full protocol: nexusmind-memory skill.
PROTOCOL

# ---------------------------------------------------------------------------
# Append recent memories if available
# ---------------------------------------------------------------------------
if [[ -n "$RECENT_MEMORIES" ]]; then
  cat <<MEMORIES

### Recent Team Memories (last ${NEXUSMIND_SESSION_RECENT_LIMIT})
${RECENT_MEMORIES}
MEMORIES
fi
