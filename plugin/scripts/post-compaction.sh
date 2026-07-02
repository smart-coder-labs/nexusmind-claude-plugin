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
RECENT_MEMORIES=""
MEMORIES_RESPONSE="$(curl -sf --max-time 10 \
  -H "Authorization: Bearer ${NEXUSMIND_API_KEY}" \
  -H "Content-Type: application/json" \
  "${NEXUSMIND_BASE_URL}/v1/memory?limit=15" 2>/dev/null || true)"

if [[ -n "$MEMORIES_RESPONSE" ]]; then
  RECENT_MEMORIES="$(echo "$MEMORIES_RESPONSE" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    items = data if isinstance(data, list) else data.get('memories', data.get('items', data.get('data', [])))
    lines = []
    for m in items[:10]:
        project = m.get('project', '') or m.get('metadata', {}).get('project', '')
        tool    = m.get('tool', '') or m.get('metadata', {}).get('tool', '')
        content = m.get('content', m.get('text', ''))
        label   = '/'.join(filter(None, [project, tool]))
        snippet = content[:120].replace('\n', ' ')
        lines.append(f'- [{label}] {snippet}')
    print('\n'.join(lines))
except Exception:
    pass
" 2>/dev/null || true)"
fi

# ---------------------------------------------------------------------------
# Output additionalContext with compaction-specific recovery instructions
# ---------------------------------------------------------------------------
cat <<PROTOCOL
## NexusMind — ACTIVE PROTOCOL (post-compaction recovery)

Context was compacted. You MUST recover state before continuing.

**FIRST ACTION REQUIRED after compaction:**
1. Call store_memory with a summary of what was being worked on before compaction
2. Recover this project's context with get_context (or list_memories with the project filter) — NOT search_memory("${PROJECT}"). Use search_memory only for a specific topic you need, with a semantic query.
3. Only then continue working

**Project detected**: ${PROJECT}

### CORE TOOLS
store_memory — save decisions, bugs, discoveries, conventions PROACTIVELY (do not wait to be asked)
search_memory — SEMANTIC search by topic (pass the project via the project filter, never as the query; never search the project name)
list_memories — list a project's memories via the project filter
get_context — recover a project's accumulated context

### PROACTIVE SAVE RULE
Call store_memory IMMEDIATELY after ANY decision, bug fix, discovery, or convention — not just when asked.
Always pass tool="claude-code" and project="${PROJECT}".

### WHEN TO SEARCH
- User's first message references a feature or problem → search_memory with a SEMANTIC query from the topic (not the project name)
- Starting work on something that might have been done before → search_memory by topic
- User asks to recall anything → search_memory by topic
- Want the project's overall context → get_context / list_memories with the project filter, NOT search_memory("${PROJECT}")

### SESSION CLOSE (MANDATORY)
Before saying "done", call store_memory with:
- What was accomplished
- Key decisions and why
- Files changed
- Next steps

This is NOT optional. If you skip this, the next session starts blind.
PROTOCOL

# ---------------------------------------------------------------------------
# Append recent memories if available
# ---------------------------------------------------------------------------
if [[ -n "$RECENT_MEMORIES" ]]; then
  cat <<MEMORIES

### Recent Team Memories (last 10)
${RECENT_MEMORIES}
MEMORIES
fi
