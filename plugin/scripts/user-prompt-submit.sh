#!/usr/bin/env bash
# user-prompt-submit.sh — NexusMind Claude Code plugin: UserPromptSubmit hook
# Runs on EVERY prompt, so it is the most token-sensitive hook in the plugin.
# Behavior is controlled by NEXUSMIND_PROMPT_INJECT (default "minimal"):
#   off     — inject nothing (after the API-key gate).
#   minimal — inject nothing unless the prompt matches recall-intent keywords;
#             on a match, inject up to 3 memory lines + one save reminder.
#   full    — legacy behavior: protocol skeleton + memory fetch on every prompt.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_helpers.sh
source "${SCRIPT_DIR}/_helpers.sh"

# Parse stdin
INPUT="$(cat)"
cwd="$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('cwd',''))" 2>/dev/null || true)"
prompt="$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('prompt',''))" 2>/dev/null || true)"

# Guard: API key — must run before the NEXUSMIND_PROMPT_INJECT branch in all modes.
if [[ -z "${NEXUSMIND_API_KEY:-}" ]]; then
  exit 0
fi

NEXUSMIND_BASE_URL="${NEXUSMIND_BASE_URL:-https://nexusmind-backend.fly.dev}"
NEXUSMIND_PROMPT_INJECT="${NEXUSMIND_PROMPT_INJECT:-minimal}"

if [[ "$NEXUSMIND_PROMPT_INJECT" == "off" ]]; then
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

fetch_memory_lines() {
  # $1 = url, $2 = limit
  local json
  json="$(curl -sf --max-time 5 \
    -H "Authorization: Bearer ${NEXUSMIND_API_KEY}" \
    "$1" 2>/dev/null || true)"
  [[ -z "$json" ]] && return 0
  echo "$json" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    items = data if isinstance(data, list) else data.get('memories', data.get('items', data.get('data', [])))
    lines = []
    for m in items[:int(sys.argv[1])]:
        t = m.get('type') or 'general'
        title = m.get('title') or (m.get('content','').split('\n')[0][:120])
        lines.append(f'- [{t}] {title}')
    print('\n'.join(lines))
except Exception:
    pass
" "$2" 2>/dev/null || true
}

emit_system_message() {
  python3 -c "
import json, sys
print(json.dumps({'systemMessage': sys.argv[1]}))
" "$1"
}

if [[ "$NEXUSMIND_PROMPT_INJECT" == "minimal" ]]; then
  # Recall-intent keywords, case-insensitive, single regex.
  if ! echo "$prompt" | grep -qiE 'remember|recall|recuerda|acordate|what did we|qué hicimos'; then
    exit 0
  fi

  RECENT_BLOCK="$(fetch_memory_lines "${NEXUSMIND_BASE_URL}/v1/memory?limit=3" 3)"
  [[ -z "$RECENT_BLOCK" ]] && RECENT_BLOCK="(none)"

  MESSAGE="$(cat <<EOF
## NexusMind — Recall (project: ${PROJECT})
${RECENT_BLOCK}

Save any decision you make with store_memory before moving on.
EOF
)"
  emit_system_message "$MESSAGE"
  exit 0
fi

if [[ "$NEXUSMIND_PROMPT_INJECT" == "full" ]]; then
  NEXUSMIND_PROMPT_MEMORY_LIMIT="${NEXUSMIND_PROMPT_MEMORY_LIMIT:-3}"

  # Section 1: recent memories
  RECENT_BLOCK="$(fetch_memory_lines "${NEXUSMIND_BASE_URL}/v1/memory?limit=${NEXUSMIND_PROMPT_MEMORY_LIMIT}" "${NEXUSMIND_PROMPT_MEMORY_LIMIT}")"
  [[ -z "$RECENT_BLOCK" ]] && RECENT_BLOCK="(none)"

  # Section 2: project-specific memories — filter by project, do NOT
  # semantic-search the project name. This runs on every prompt; searching the
  # project name floods the audit log with noise and returns poor matches.
  PROJECT_ENC="$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "${PROJECT}" 2>/dev/null || echo "${PROJECT}")"
  PROJECT_BLOCK="$(fetch_memory_lines "${NEXUSMIND_BASE_URL}/v1/memory?project=${PROJECT_ENC}&limit=${NEXUSMIND_PROMPT_MEMORY_LIMIT}" "${NEXUSMIND_PROMPT_MEMORY_LIMIT}")"
  [[ -z "$PROJECT_BLOCK" ]] && PROJECT_BLOCK="(none)"

  MESSAGE="$(cat <<EOF
## NexusMind — Per-Prompt Protocol (project: ${PROJECT})

### 1) Recent session memories
\`\`\`nexusmind-recent
${RECENT_BLOCK}
\`\`\`

### 2) Project-specific memories — ${PROJECT}
\`\`\`nexusmind-project
${PROJECT_BLOCK}
\`\`\`

### 3) MANDATORY behavioral rule
MANDATORY: if this message references existing work, call \`search_memory\` before responding with a SEMANTIC query describing the topic (never the project name — that goes in the project filter). Save any decision you make to NexusMind. Do not skip this.

### 4) Save reminder
After completing any decision, bug fix, or non-obvious discovery, call \`store_memory\` BEFORE moving on.

### 5) Format hint
When you call \`store_memory\`, always set \`type\`, always set \`title\`, always set \`project\`.
EOF
)"
  emit_system_message "$MESSAGE"
  exit 0
fi

# Unknown mode value — fail safe with no injection rather than erroring.
exit 0
