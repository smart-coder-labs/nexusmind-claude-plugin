#!/usr/bin/env bash
# _helpers.sh — shared helper functions for NexusMind Claude Code plugin scripts

# project_from_config: echoes the project alias whose `paths` claim $PWD, from the
# nearest `.nexusmind.yaml` walking up from the current directory. Silent (empty)
# when there is no config, no match and no default.
#
# Deliberately no git: the case this exists for is a directory that is not a
# repository. Matching mirrors resolveProject in the MCP — glob against the path
# relative to the config's own directory, most specific wins, `defaults.project`
# as the fallback — so hooks and tools agree on the answer.
project_from_config() {
  local py; py="$(resolve_python 2>/dev/null || true)"
  [[ -n "$py" ]] || return 1
  $py - <<'PY' 2>/dev/null
import os, sys

def find_config(start):
    cur = os.path.abspath(start)
    while True:
        cand = os.path.join(cur, '.nexusmind.yaml')
        if os.path.isfile(cand):
            return cand
        parent = os.path.dirname(cur)
        if parent == cur:
            return None
        cur = parent

cfg = find_config(os.getcwd())
if not cfg:
    raise SystemExit(1)

# Minimal reader for the two keys that matter. A full YAML parser is not worth a
# dependency in a hook that must never block a session start.
projects, order, default = {}, [], None
alias = None
section = None
for raw in open(cfg, encoding='utf-8'):
    line = raw.rstrip('\n')
    if not line.strip() or line.lstrip().startswith('#'):
        continue
    indent = len(line) - len(line.lstrip())
    body = line.strip()
    if indent == 0:
        section = body.rstrip(':')
        alias = None
        continue
    if section == 'defaults' and body.startswith('project:'):
        default = body.split(':', 1)[1].strip().strip('"\'')
        continue
    if section != 'projects':
        continue
    if indent == 2 and body.endswith(':'):
        alias = body[:-1].strip()
        projects[alias] = []
        order.append(alias)
    elif alias and body.startswith('- '):
        projects[alias].append(body[2:].strip().strip('"\''))

root = os.path.dirname(cfg)
rel = os.path.relpath(os.getcwd(), root).replace(os.sep, '/')
if rel == '.':
    rel = ''

best, best_len = None, -1
for a in order:
    for pat in projects[a]:
        pat = pat.rstrip('/')
        base = pat[:-3] if pat.endswith('/**') else pat
        if base == '**':
            hit, length = True, 0
        else:
            hit = rel == base or rel.startswith(base + '/')
            length = len(base)
        if hit and length > best_len:
            best, best_len = a, length

print(best or default or '')
PY
}

# detect_project: determines the project name from git or directory context.
# Priority: git remote origin repo name → git root basename → cwd basename.
detect_project() {
  local project=""

  # 0. A `.nexusmind.yaml` claiming this directory wins over anything inferred.
  #
  # Inference works fine inside a clone and not at all one level up: a workspace
  # folder holding several clones is not a repository, so git says nothing and
  # the fallback returns the folder's own name — a project that does not exist,
  # which makes the session-start probe declare "no index" and stand NexusMind
  # down. The config is the only thing that can say which project a path belongs
  # to when the filesystem cannot.
  project="$(project_from_config 2>/dev/null || true)"
  if [[ -n "$project" ]]; then
    echo "$project"
    return 0
  fi

  # 1. Try git remote origin URL → extract repo name
  if git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    local remote_url
    remote_url="$(git remote get-url origin 2>/dev/null || true)"
    if [[ -n "$remote_url" ]]; then
      # Strip trailing .git, then extract last path component
      project="$(basename "$remote_url" .git)"
    fi

    # 2. Fallback: git root directory basename
    if [[ -z "$project" ]]; then
      project="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || true)")"
    fi
  fi

  # 3. Final fallback: current working directory basename
  if [[ -z "$project" ]]; then
    project="$(basename "$PWD")"
  fi

  echo "$project"
}

# resolve_python: finds a real, working Python interpreter and echoes the
# command to invoke it (may be two words, e.g. "py -3").
# On Windows, `python3` and `python` on PATH frequently resolve to Microsoft
# Store stub executables (under ...\AppData\Local\Microsoft\WindowsApps\)
# that print an install hint to stderr and exit non-zero instead of running
# any code — they are not real interpreters. We probe each candidate with a
# trivial import to weed those out, and fall back to the `py` launcher, which
# is the reliable way to reach a real Python install on Windows when
# python3/python are missing or are stubs. Returns 1 if nothing works so
# callers can degrade gracefully instead of crashing under `set -e`.
resolve_python() {
  local candidates=("python3" "python" "py -3" "py")
  local candidate

  for candidate in "${candidates[@]}"; do
    # Unquoted on purpose: "py -3" must word-split into two argv entries.
    if $candidate -c 'import sys' >/dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

# resolve_nexusmind_env: echoes "<api_key>\t<base_url>", either field possibly empty.
#
# A hook is a subprocess of Claude Code, not of the MCP server, so it does NOT
# inherit the server's `env` block. Setup writes the key to whichever place works
# on the user's platform — ~/.claude/settings.json on macOS/Linux, a literal in
# ~/.claude.json's mcpServers entry as the out-of-the-box fallback — and only the
# first of those reaches this process. Reading just $NEXUSMIND_API_KEY therefore
# made the enforcement hook stand down for a correctly configured user.
#
# TWO SECURITY RULES, both learned the hard way:
#
#   * Repository files are NOT a source. An earlier version walked up from the cwd
#     reading every `.mcp.json`, which meant cloning a repo and opening Claude Code
#     in it was enough to send the user's real key to a host the repo chose. Claude
#     Code prompts before trusting a project `.mcp.json`; a hook must not bypass
#     that prompt. Nothing is lost by dropping them: the plugin's own `.mcp.json`
#     carries `${VAR}` placeholders, which are rejected anyway.
#
#   * A URL may only be paired with a key when it comes from the key's own source
#     or from one the user wrote directly (the process env, ~/.claude/settings*.json).
#     Filling each field from whichever source happens to have it is what let a
#     trusted key be paired with an untrusted URL — `~/.claude.json` mcpServers can
#     hold a URL that originated in an approved project `.mcp.json`, so it donates a
#     URL only when it also supplied the key.
#
# The pairing rule has to allow that fallback: a self-hosted user keeping the key in
# ~/.claude.json and the URL in settings.json would otherwise get no URL at all, and
# every hook falls back to the provider's cloud default — their key leaving for a
# host they never configured. A security fix that exfiltrates more quietly is not a
# fix.
resolve_nexusmind_env() {
  local py; py="$(resolve_python 2>/dev/null || true)"
  if [[ -z "$py" ]]; then
    printf '%s\t%s' "${NEXUSMIND_API_KEY:-}" "${NEXUSMIND_BASE_URL:-}"
    return 0
  fi
  # The key goes through the environment, never argv: /proc/*/cmdline and `ps aux`
  # are world-readable, so an argument would expose it to every local user for the
  # lifetime of the process.
  # Unquoted on purpose — resolve_python may return two words ("py -3").
  NM_ENV_KEY="${NEXUSMIND_API_KEY:-}" \
  NM_ENV_URL="${NEXUSMIND_BASE_URL:-}" \
  NM_CODEX_HOME="${CODEX_HOME:-}" \
  $py - <<'PY' 2>/dev/null || printf '%s\t%s' "${NEXUSMIND_API_KEY:-}" "${NEXUSMIND_BASE_URL:-}"
import json, os, re, sys

home = os.path.expanduser('~')
SERVER_NAMES = {'nexusmind', 'nexus-mind', 'nexus_mind'}

def load(path):
    try:
        with open(path, encoding='utf-8') as fh:
            return json.load(fh)
    except Exception:
        return None

def literal(value):
    # "${NEXUSMIND_API_KEY}" / "$NEXUSMIND_API_KEY" are placeholders Claude Code
    # expands from the process env. If one reached here the env was empty, so the
    # placeholder is not a key — sending it would put the literal string on the
    # wire as a bearer token.
    if not isinstance(value, str):
        return ''
    v = value.strip()
    return '' if (not v or v.startswith('$')) else v

def from_env_block(env):
    if not isinstance(env, dict):
        return ('', '')
    return (literal(env.get('NEXUSMIND_API_KEY')), literal(env.get('NEXUSMIND_BASE_URL')))

def from_mcp_servers(node):
    # ~/.claude.json nests a copy of mcpServers under projects.<path>, so recurse
    # instead of only looking at the top level. Returns the first pair holding a key.
    best = ('', '')
    if isinstance(node, dict):
        servers = node.get('mcpServers')
        if isinstance(servers, dict):
            for name, cfg in servers.items():
                if str(name).lower() in SERVER_NAMES and isinstance(cfg, dict):
                    pair = from_env_block(cfg.get('env'))
                    if pair[0]:
                        return pair
                    if pair[1] and not best[1]:
                        best = pair
        for k, v in node.items():
            if k != 'mcpServers':
                pair = from_mcp_servers(v)
                if pair[0]:
                    return pair
                if pair[1] and not best[1]:
                    best = pair
    return best

def from_codex():
    path = os.path.join(os.environ.get('NM_CODEX_HOME') or os.path.join(home, '.codex'), 'config.toml')
    key = url = ''
    try:
        with open(path, encoding='utf-8') as fh:
            section = False
            for raw in fh:
                line = raw.strip()
                if line.startswith('['):
                    section = line.rstrip(']').lstrip('[') == 'mcp_servers.nexusmind.env'
                    continue
                if not section:
                    continue
                m = re.match(r'^(\w+)\s*=\s*["\'](.*)["\']\s*$', line)
                if m:
                    if m.group(1) == 'NEXUSMIND_API_KEY':
                        key = literal(m.group(2))
                    elif m.group(1) == 'NEXUSMIND_BASE_URL':
                        url = literal(m.group(2))
    except Exception:
        pass
    return (key, url)

# Every source below is user-owned and outside any repository. Ordered by
# authority: the process env is what the MCP server will actually send.
#
# `direct` marks the sources the user (or our own setup) wrote by hand. Those may
# donate a URL to a key found elsewhere. The mcpServers blocks may not: a URL in
# there can have arrived from a project `.mcp.json` the user approved once.
sources = []   # (key, url, direct)
sources.append((os.environ.get('NM_ENV_KEY', ''), os.environ.get('NM_ENV_URL', ''), True))
for settings in (os.path.join(home, '.claude', 'settings.json'),
                 os.path.join(home, '.claude', 'settings.local.json')):
    data = load(settings)
    pair = from_env_block(data.get('env')) if isinstance(data, dict) else ('', '')
    sources.append((pair[0], pair[1], True))
pair = from_mcp_servers(load(os.path.join(home, '.claude.json')))
sources.append((pair[0], pair[1], False))
pair = from_codex()
sources.append((pair[0], pair[1], False))

key, url = '', ''
for src_key, src_url, _direct in sources:
    if src_key:
        key, url = src_key, src_url   # the key's own source is always allowed
        break
if not url:
    # Fall back only to sources the user wrote directly. Leaving this empty would
    # send the key to the hardcoded provider default instead — worse, not safer.
    url = next((u for _k, u, direct in sources if direct and u), '')

sys.stdout.write('%s\t%s' % (key, url))
PY
}

# hydrate_nexusmind_env: exports NEXUSMIND_API_KEY / NEXUSMIND_BASE_URL when they
# are missing from this process but configured somewhere the client reads.
#
# Every hook in this plugin gates on `[[ -z "${NEXUSMIND_API_KEY:-}" ]]` and quietly
# does nothing when it is empty. For a user whose key lives only in the MCP server's
# `env` block that check was always true, so memory capture, compaction snapshots
# and search enforcement all went silently idle on a correctly configured machine.
# Hydrating once after sourcing fixes every one of those call sites without
# touching them.
hydrate_nexusmind_env() {
  local k u
  # `|| true`, not `|| return 0`: the python writes no trailing newline, so `read`
  # assigns both fields and then returns 1 at EOF. A `return 0` there skipped both
  # exports and made this function a silent no-op — the exact bug it exists to fix.
  IFS=$'\t' read -r k u < <(resolve_nexusmind_env 2>/dev/null) || true
  [[ -n "${NEXUSMIND_API_KEY:-}" ]] || { [[ -n "$k" ]] && export NEXUSMIND_API_KEY="$k"; }
  [[ -n "${NEXUSMIND_BASE_URL:-}" ]] || { [[ -n "$u" ]] && export NEXUSMIND_BASE_URL="$u"; }
  return 0
}

