#!/usr/bin/env bash
# pre-compact.sh — NexusMind Claude Code plugin: PreCompact hook
# Persists a session snapshot BEFORE compaction destroys context, without
# depending on the model to do it. Runs synchronously (not async) so it
# finishes before compaction happens.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_helpers.sh
source "${SCRIPT_DIR}/_helpers.sh"

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

session_id="$(echo "$INPUT" | $PYTHON_BIN -c "import sys,json; d=json.load(sys.stdin); print(d.get('session_id',''))" 2>/dev/null || true)"
transcript_path="$(echo "$INPUT" | $PYTHON_BIN -c "import sys,json; d=json.load(sys.stdin); print(d.get('transcript_path',''))" 2>/dev/null || true)"
cwd="$(echo "$INPUT" | $PYTHON_BIN -c "import sys,json; d=json.load(sys.stdin); print(d.get('cwd',''))" 2>/dev/null || true)"

NEXUSMIND_BASE_URL="${NEXUSMIND_BASE_URL:-https://nexusmind-backend.fly.dev}"

# Project detection — mirror the pushd/popd pattern used in
# user-prompt-submit.sh so detect_project resolves relative to the hook's cwd.
if [[ -n "$cwd" ]]; then
  pushd "$cwd" &>/dev/null || true
fi
PROJECT="$(detect_project)"
if [[ -n "$cwd" ]]; then
  popd &>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Extract the last ~15 assistant text messages from the JSONL transcript.
# Transcript lines are JSON objects; skip unparseable lines defensively.
# ---------------------------------------------------------------------------
extract_recent_assistant_text() {
  local transcript_path="$1"
  if [[ -z "$transcript_path" || ! -f "$transcript_path" ]]; then
    echo ""
    return 0
  fi
  $PYTHON_BIN -c "
import sys, json

path = sys.argv[1]
messages = []
try:
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except Exception:
                continue
            try:
                if entry.get('type') != 'assistant':
                    continue
                message = entry.get('message', {}) or {}
                content = message.get('content', [])
                if not isinstance(content, list):
                    continue
                for item in content:
                    if isinstance(item, dict) and item.get('type') == 'text':
                        text = item.get('text', '')
                        if text:
                            messages.append(text)
            except Exception:
                continue
except Exception:
    pass

print('\n\n---\n\n'.join(messages[-15:]))
" "$transcript_path" 2>/dev/null || true
}

RECENT_TEXT="$(extract_recent_assistant_text "$transcript_path")"

# Skip if there isn't enough extracted content to be worth persisting.
if [[ -z "$RECENT_TEXT" || "${#RECENT_TEXT}" -lt 100 ]]; then
  exit 0
fi

CONTENT="Pre-compaction snapshot — last assistant messages before compaction:

${RECENT_TEXT}"

PAYLOAD="$($PYTHON_BIN -c "
import json, sys
content = sys.argv[1]
project = sys.argv[2]
session_id = sys.argv[3]
if len(content) > 2000:
    content = content[:2000] + '... [truncated]'
payload = {
    'title': 'Pre-compaction snapshot: ' + project,
    'content': content,
    'type': 'session_summary',
    'tool': 'claude-code',
    'project': project,
}
if session_id:
    # Same session's repeated compactions upsert instead of duplicating.
    payload['topic_key'] = 'session-snapshot/' + session_id
print(json.dumps(payload))
" "$CONTENT" "$PROJECT" "$session_id" 2>/dev/null || true)"

if [[ -n "$PAYLOAD" ]]; then
  curl -sf --max-time 10 \
    -X POST \
    -H "Authorization: Bearer ${NEXUSMIND_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "${NEXUSMIND_BASE_URL}/v1/memory/store" &>/dev/null || true
fi

exit 0
