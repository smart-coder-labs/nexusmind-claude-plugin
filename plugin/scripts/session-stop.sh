#!/usr/bin/env bash
# session-stop.sh — NexusMind Claude Code plugin: Stop hook (gate, not async)
# Enforces the "save before finishing" rule: if the turn since the last real
# user message looks like it produced a decision/fix/discovery and nothing
# was saved via store_memory, blocks once per session with a reminder.
#
# Hard requirement: this script must NEVER exit non-zero, no matter what
# fails internally — a nonzero exit must not be confused with the block
# decision, which is communicated purely via stdout JSON. All logic runs
# inside main(), called as `main || true`, followed by an unconditional
# `exit 0`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_helpers.sh
source "${SCRIPT_DIR}/_helpers.sh"

# Same decision-keyword regex as subagent-stop.sh — copied verbatim so
# behavior stays consistent across hooks.
KEYWORD_RE='decided|decision|fixed|error|warning|convention|architecture|discovered|discovery|issue|solution|implemented|changed|added|removed|refactored|pattern|config|gotcha|caveat|note|important'

main() {
  local input python_bin stop_hook_active
  local nexusmind_stop_gate session_id transcript_path
  local state_dir state_file analysis since_user_text has_store_memory

  input="$(cat)"

  python_bin="$(resolve_python || true)"
  if [[ -z "$python_bin" ]]; then
    # Can't parse the hook payload without a real interpreter — nothing
    # useful (and no safe way) to block. Exit clean.
    return 0
  fi

  # MANDATORY anti-loop: bail out immediately if this Stop event was itself
  # triggered by a previous block decision from this hook.
  stop_hook_active="$(echo "$input" | $python_bin -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(json.dumps(bool(d.get('stop_hook_active', False))))
except Exception:
    print('false')
" 2>/dev/null || echo 'false')"
  if [[ "$stop_hook_active" == "true" ]]; then
    return 0
  fi

  nexusmind_stop_gate="${NEXUSMIND_STOP_GATE:-on}"
  if [[ "$nexusmind_stop_gate" == "off" ]]; then
    return 0
  fi

  if [[ -z "${NEXUSMIND_API_KEY:-}" ]]; then
    return 0
  fi

  session_id="$(echo "$input" | $python_bin -c "import sys,json; d=json.load(sys.stdin); print(d.get('session_id',''))" 2>/dev/null || true)"
  transcript_path="$(echo "$input" | $python_bin -c "import sys,json; d=json.load(sys.stdin); print(d.get('transcript_path',''))" 2>/dev/null || true)"

  if [[ -z "$session_id" ]]; then
    return 0
  fi

  # Rate limit: block at most once per session.
  state_dir="${XDG_CACHE_HOME:-$HOME/.cache}/nexusmind"
  state_file="${state_dir}/stop-gate-${session_id}"
  if [[ -e "$state_file" ]]; then
    return 0
  fi

  if [[ -z "$transcript_path" || ! -f "$transcript_path" ]]; then
    return 0
  fi

  # Analyze the transcript since the last real user text message. A "real"
  # user message has a text content block; tool_result entries also carry
  # role: "user" in Claude Code transcripts but must NOT count as a user
  # turn — only text-carrying user entries mark a genuine turn boundary.
  analysis="$($python_bin -c "
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

# Synthetic user-type entries (isMeta preludes, hook/skill injections, local
# command output, system notifications) must NOT count as real turn
# boundaries — only genuine user-typed text does.
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

span = entries[last_user_idx + 1:] if last_user_idx >= 0 else entries

assistant_text = []
has_store_memory = False
for entry in span:
    try:
        if entry.get('type') != 'assistant':
            continue
        message = entry.get('message', {}) or {}
        content = message.get('content', [])
        if not isinstance(content, list):
            continue
        for item in content:
            if not isinstance(item, dict):
                continue
            if item.get('type') == 'text':
                assistant_text.append(item.get('text', ''))
            elif item.get('type') == 'tool_use':
                name = item.get('name', '') or ''
                if 'store_memory' in name:
                    has_store_memory = True
    except Exception:
        continue

print(json.dumps({
    'text': '\n'.join(assistant_text),
    'has_store_memory': has_store_memory,
}))
" "$transcript_path" 2>/dev/null || true)"

  if [[ -z "$analysis" ]]; then
    return 0
  fi

  since_user_text="$(echo "$analysis" | $python_bin -c "import sys,json; print(json.load(sys.stdin).get('text',''))" 2>/dev/null || true)"
  has_store_memory="$(echo "$analysis" | $python_bin -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('has_store_memory', False)))" 2>/dev/null || echo 'false')"

  if [[ "$has_store_memory" == "true" ]]; then
    return 0
  fi

  if [[ -z "$since_user_text" ]]; then
    return 0
  fi

  if ! echo "$since_user_text" | grep -iEq "$KEYWORD_RE"; then
    return 0
  fi

  # Write the state file BEFORE emitting the block decision: if the cache
  # dir is unwritable, fail open (no block) instead of blocking on every
  # Stop event for this session.
  if ! mkdir -p "$state_dir" 2>/dev/null || ! touch "$state_file" 2>/dev/null; then
    return 0
  fi

  printf '%s\n' '{"decision":"block","reason":"NexusMind gate: this turn looks like it produced a decision, fix, or discovery, but nothing was saved. Call store_memory now (set type, title, project) — or finish normally if there is genuinely nothing worth persisting; this gate will not fire again this session."}'
  return 0
}

main || true
exit 0
