#!/usr/bin/env bash
# session-start.sh — NexusMind Claude Code plugin: SessionStart hook
# Emits additionalContext with project search + recency + full protocol body.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_helpers.sh
source "${SCRIPT_DIR}/_helpers.sh"

INPUT="$(cat)"
cwd="$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('cwd',''))" 2>/dev/null || true)"

NEXUSMIND_BASE_URL="${NEXUSMIND_BASE_URL:-https://nexusmind-backend.fly.dev}"

# Guard: API key
if [[ -z "${NEXUSMIND_API_KEY:-}" ]]; then
  cat <<'EOF'
<!-- NexusMind NOT CONNECTED: NEXUSMIND_API_KEY is not set. Memory tools will not be available.
     Run: export NEXUSMIND_API_KEY=<your-key>
     Then restart Claude Code. -->
EOF
  exit 0
fi

# Guard: backend health
if ! curl -sf --max-time 5 "${NEXUSMIND_BASE_URL}/v1/health" &>/dev/null; then
  cat <<'EOF'
<!-- NexusMind NOT CONNECTED: backend is unreachable. Memory tools will not be available.
     Check NEXUSMIND_BASE_URL or your network connection. -->
EOF
  exit 0
fi

# Project detection
if [[ -n "$cwd" ]]; then
  pushd "$cwd" &>/dev/null || true
fi
PROJECT="$(detect_project)"
if [[ -n "$cwd" ]]; then
  popd &>/dev/null || true
fi

format_memories() {
  python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    items = data if isinstance(data, list) else data.get('memories', data.get('items', data.get('data', [])))
    lines = []
    for m in items[:int(sys.argv[1])]:
        t = (m.get('type') or 'general')
        title = m.get('title') or (m.get('content','').split('\n')[0][:120].replace('\n',' '))
        lines.append(f'- [{t}] {title}')
    print('\n'.join(lines))
except Exception:
    pass
" "$1"
}

NEXUSMIND_SESSION_PROJECT_LIMIT="${NEXUSMIND_SESSION_PROJECT_LIMIT:-8}"
NEXUSMIND_SESSION_RECENT_LIMIT="${NEXUSMIND_SESSION_RECENT_LIMIT:-5}"

# Project-specific memories — filter by project, do NOT semantic-search the project name.
# The project name is a filter parameter, not a search term; searching it returns
# noise (token matches) and misses everything, so we list by project instead.
PROJECT_BLOCK=""
PROJECT_ENC="$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "${PROJECT}" 2>/dev/null || echo "${PROJECT}")"
PROJECT_JSON="$(curl -sf --max-time 8 \
  -H "Authorization: Bearer ${NEXUSMIND_API_KEY}" \
  "${NEXUSMIND_BASE_URL}/v1/memory?project=${PROJECT_ENC}&limit=${NEXUSMIND_SESSION_PROJECT_LIMIT}" 2>/dev/null || true)"
if [[ -n "$PROJECT_JSON" ]]; then
  PROJECT_BLOCK="$(echo "$PROJECT_JSON" | format_memories "${NEXUSMIND_SESSION_PROJECT_LIMIT}")"
fi

# Recency list
RECENT_BLOCK=""
RECENT_JSON="$(curl -sf --max-time 8 \
  -H "Authorization: Bearer ${NEXUSMIND_API_KEY}" \
  "${NEXUSMIND_BASE_URL}/v1/memory?limit=${NEXUSMIND_SESSION_RECENT_LIMIT}" 2>/dev/null || true)"
if [[ -n "$RECENT_JSON" ]]; then
  RECENT_BLOCK="$(echo "$RECENT_JSON" | format_memories "${NEXUSMIND_SESSION_RECENT_LIMIT}")"
fi

# Minimal protocol pointer — full detail lives in the nexusmind-memory skill.
cat <<PROTOCOL
## NexusMind — Memory Protocol (project: ${PROJECT})

Tools: store_memory, search_memory, list_memories, get_context, get_memory, delete_memory. Full protocol detail: nexusmind-memory skill.
Proactively call store_memory right after any decision, bug fix, discovery, or convention — do not wait to be asked.
Before starting work that may already have context, call search_memory or list_memories with project="${PROJECT}" as a FILTER — never as the search query text.
Before ending the session, call store_memory with a type="session_summary" recap — mandatory, skipping it leaves the next session blind.
PROTOCOL

if [[ -n "$PROJECT_BLOCK" ]]; then
  cat <<EOF

### Project Memories — ${PROJECT}
${PROJECT_BLOCK}
EOF
fi

if [[ -n "$RECENT_BLOCK" ]]; then
  cat <<EOF

### Recent Team Memories (last 10)
${RECENT_BLOCK}
EOF
fi
