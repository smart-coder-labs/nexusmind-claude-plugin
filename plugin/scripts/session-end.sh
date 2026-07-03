#!/usr/bin/env bash
# session-end.sh — NexusMind Claude Code plugin: SessionEnd hook
# Fallback session summary when the session dies without the model saving
# one via store_memory. Skips entirely if the model already did its job.
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

# session_id feeds the fallback save's topic_key below (same namespace as
# pre-compact.sh: "session-snapshot/{session_id}") so a PreCompact snapshot
# and a SessionEnd fallback for the SAME session upsert into one record
# instead of leaving two stale, near-duplicate entries per session.
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

if [[ -z "$transcript_path" || ! -f "$transcript_path" ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# If the transcript already contains a store_memory tool_use whose input
# mentions "session_summary", the model already saved its own recap — skip.
# Tool names may be MCP-namespaced (e.g. mcp__nexusmind__store_memory), so
# match by substring rather than exact equality.
#
# Only entries AFTER the last real user message count: a summary saved
# earlier in a long session must not permanently disable this fallback for
# every later turn. "Real" user message excludes synthetic user-type
# entries (isMeta preludes, hook/skill injections, local command output,
# system notifications) — same turn-boundary logic as session-stop.sh's
# is_real_user_text(), kept inline here per-file rather than shared.
# ---------------------------------------------------------------------------
already_saved="$($PYTHON_BIN -c "
import sys, json

path = sys.argv[1]
entries = []
try:
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entries.append(json.loads(line))
            except Exception:
                continue
except Exception:
    pass

SYNTHETIC_TEXT_PREFIXES = (
    '<system-reminder>',
    '[SYSTEM NOTIFICATION',
    'Caveat:',
    '<command-name>',
    '<local-command-stdout>',
    '<task-notification>',
)

def is_real_user_text(entry):
    if entry.get('type') != 'user':
        return False
    if entry.get('isMeta'):
        return False
    message = entry.get('message', {}) or {}
    if message.get('role') != 'user':
        return False
    content = message.get('content', [])
    if isinstance(content, str):
        text = content.strip()
        return bool(text) and not text.lstrip().startswith(SYNTHETIC_TEXT_PREFIXES)
    if not isinstance(content, list):
        return False
    for item in content:
        if isinstance(item, dict) and item.get('type') == 'text':
            text = (item.get('text') or '').strip()
            if text and not text.lstrip().startswith(SYNTHETIC_TEXT_PREFIXES):
                return True
        if isinstance(item, str) and item.strip():
            text = item.strip()
            if not text.lstrip().startswith(SYNTHETIC_TEXT_PREFIXES):
                return True
    return False

last_user_idx = -1
for i, entry in enumerate(entries):
    try:
        if is_real_user_text(entry):
            last_user_idx = i
    except Exception:
        continue

if last_user_idx >= 0:
    span = entries[last_user_idx + 1:]
else:
    # No real user message found — fall back to scanning the tail instead
    # of the whole transcript.
    span = entries[-50:]

found = False
for entry in span:
    try:
        message = entry.get('message', {}) or {}
        content = message.get('content', [])
        if not isinstance(content, list):
            continue
        for item in content:
            if not isinstance(item, dict):
                continue
            if item.get('type') != 'tool_use':
                continue
            name = item.get('name', '') or ''
            if 'store_memory' not in name:
                continue
            if 'session_summary' in json.dumps(item.get('input', {})):
                found = True
                break
    except Exception:
        continue
    if found:
        break

print(json.dumps(found))
" "$transcript_path" 2>/dev/null || echo 'false')"

if [[ "$already_saved" == "true" ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Fallback: extract the last ~15 assistant text messages from the transcript.
# Same extraction logic as pre-compact.sh, kept consistent.
# ---------------------------------------------------------------------------
extract_recent_assistant_text() {
  local transcript_path="$1"
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

if [[ -z "$RECENT_TEXT" || "${#RECENT_TEXT}" -lt 100 ]]; then
  exit 0
fi

CONTENT="Session end auto-capture — last assistant messages (no session_summary was saved by the model):

${RECENT_TEXT}"

PAYLOAD="$($PYTHON_BIN -c "
import json, sys
content = sys.argv[1]
project = sys.argv[2]
session_id = sys.argv[3]
if len(content) > 2000:
    content = content[:2000] + '... [truncated]'
payload = {
    'title': 'Session end auto-capture: ' + project,
    'content': content,
    'type': 'session_summary',
    'tool': 'claude-code',
    'project': project,
}
if session_id:
    # Same topic_key namespace as pre-compact.sh's snapshot — see comment
    # near the session_id parse above for why these two hooks share it.
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
