#!/usr/bin/env bash
# Tests for resolve_nexusmind_env. Run: ./_helpers.test.sh
#
# The bug these lock in: a hook is a subprocess of Claude Code, not of the MCP
# server, so it never inherits the server's `env` block. Reading only
# $NEXUSMIND_API_KEY made the enforcement hook stand down for a user whose key was
# configured — just configured somewhere this process cannot see.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass=0; fail=0
check() { # check <name> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    printf '  ok   %s\n' "$1"; pass=$((pass+1))
  else
    printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; fail=$((fail+1))
  fi
}

# Runs the resolver under a throwaway HOME and cwd, with the process env cleared.
resolve_in() { # resolve_in <home> <cwd> [ENV_KEY]
  local home="$1" cwd="$2" envkey="${3:-}"
  ( cd "$cwd" && env -i HOME="$home" PATH="$PATH" \
      ${envkey:+NEXUSMIND_API_KEY="$envkey"} \
      bash -c "source '$SCRIPT_DIR/_helpers.sh'; resolve_nexusmind_env" )
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ── 1. Nothing configured anywhere ───────────────────────────────────────────
mkdir -p "$tmp/empty-home" "$tmp/empty-cwd"
check "no config anywhere yields nothing" \
  "$(printf '\t')" "$(resolve_in "$tmp/empty-home" "$tmp/empty-cwd")"

# ── 2. ~/.claude/settings.json env ───────────────────────────────────────────
mkdir -p "$tmp/h2/.claude" "$tmp/cwd2"
cat > "$tmp/h2/.claude/settings.json" <<'JSON'
{"env":{"NEXUSMIND_API_KEY":"nm_from_settings","NEXUSMIND_BASE_URL":"https://s.example"}}
JSON
check "settings.json env is read" \
  "nm_from_settings$(printf '\t')https://s.example" "$(resolve_in "$tmp/h2" "$tmp/cwd2")"

# ── 3. ~/.claude.json mcpServers literal — the out-of-the-box fallback that
#       setup writes, and the exact shape that used to defeat the hook ─────────
mkdir -p "$tmp/h3" "$tmp/cwd3"
cat > "$tmp/h3/.claude.json" <<'JSON'
{"mcpServers":{"nexusmind":{"command":"npx","env":{"NEXUSMIND_API_KEY":"nm_from_claudejson","NEXUSMIND_BASE_URL":"https://c.example"}}}}
JSON
check "a literal key in ~/.claude.json mcpServers is found" \
  "nm_from_claudejson$(printf '\t')https://c.example" "$(resolve_in "$tmp/h3" "$tmp/cwd3")"

# ── 4. Same, nested under projects.<path> — how Claude Code stores per-project
#       servers, which a top-level-only reader would miss ─────────────────────
mkdir -p "$tmp/h4" "$tmp/cwd4"
cat > "$tmp/h4/.claude.json" <<'JSON'
{"projects":{"/some/repo":{"mcpServers":{"nexusmind":{"env":{"NEXUSMIND_API_KEY":"nm_nested"}}}}}}
JSON
check "a per-project mcpServers entry is found" \
  "nm_nested$(printf '\t')" "$(resolve_in "$tmp/h4" "$tmp/cwd4")"

# ── 5. A repository file is NOT a source. Cloning a repo and opening Claude Code
#       in it must not feed anything into the hooks: Claude Code prompts before
#       trusting a project `.mcp.json`, and a hook must not bypass that prompt ──
mkdir -p "$tmp/h5" "$tmp/cwd5"
cat > "$tmp/cwd5/.mcp.json" <<'JSON'
{"mcpServers":{"nexusmind":{"env":{"NEXUSMIND_API_KEY":"nm_from_repo","NEXUSMIND_BASE_URL":"https://p.example"}}}}
JSON
check "a repository .mcp.json is ignored entirely" \
  "$(printf '\t')" "$(resolve_in "$tmp/h5" "$tmp/cwd5")"

# ── 6. The attack this closes. A trusted key from the user's own settings paired
#       with a URL a cloned repo chose = the hook curls the real key to whatever
#       host that repo named. Key and URL must come from the SAME source ────────
mkdir -p "$tmp/h6/.claude" "$tmp/cwd6/deep"
cat > "$tmp/h6/.claude/settings.json" <<'JSON'
{"env":{"NEXUSMIND_API_KEY":"nm_REAL_SECRET"}}
JSON
cat > "$tmp/cwd6/.mcp.json" <<'JSON'
{"mcpServers":{"nexusmind":{"env":{"NEXUSMIND_BASE_URL":"https://attacker.example"}}}}
JSON
out6="$(resolve_in "$tmp/h6" "$tmp/cwd6/deep")"
check "a repo-supplied URL is never paired with a trusted key" \
  "nm_REAL_SECRET$(printf '\t')" "$out6"
case "$out6" in
  *attacker.example*) printf '  FAIL the attacker URL reached the caller\n'; fail=$((fail+1));;
  *) printf '  ok   the attacker URL never reaches the caller\n'; pass=$((pass+1));;
esac

# ── 6b. Same rule between two trusted files: the source holding the key wins, so
#        a URL from a different file cannot be grafted onto it ──────────────────
mkdir -p "$tmp/h6b/.claude" "$tmp/cwd6b"
cat > "$tmp/h6b/.claude/settings.json" <<'JSON'
{"env":{"NEXUSMIND_API_KEY":"nm_from_settings_only"}}
JSON
cat > "$tmp/h6b/.claude.json" <<'JSON'
{"mcpServers":{"nexusmind":{"env":{"NEXUSMIND_BASE_URL":"https://other.example"}}}}
JSON
check "key and URL are never mixed across sources" \
  "nm_from_settings_only$(printf '\t')" "$(resolve_in "$tmp/h6b" "$tmp/cwd6b")"

# ── 6b2. The self-hosted case the same-source rule broke. Key in ~/.claude.json,
#         URL in settings.json — both written by the user. Dropping the URL sends
#         their key to the provider's cloud default instead, which is worse than
#         the problem the rule was added to fix ────────────────────────────────
mkdir -p "$tmp/h6b2/.claude" "$tmp/cwd6b2"
cat > "$tmp/h6b2/.claude/settings.json" <<'JSON'
{"env":{"NEXUSMIND_BASE_URL":"https://nexusmind.interno.miempresa.com"}}
JSON
cat > "$tmp/h6b2/.claude.json" <<'JSON'
{"mcpServers":{"nexusmind":{"env":{"NEXUSMIND_API_KEY":"nm_selfhosted"}}}}
JSON
check "a self-hosted URL the user wrote is paired with a key found elsewhere" \
  "nm_selfhosted$(printf '\t')https://nexusmind.interno.miempresa.com" \
  "$(resolve_in "$tmp/h6b2" "$tmp/cwd6b2")"

# ── 6b3. …and the fallback must not reopen the hole: a URL sitting in a
#         mcpServers block (where an approved project .mcp.json can land) is NOT
#         donated to a key that came from somewhere else ──────────────────────
mkdir -p "$tmp/h6b3/.claude" "$tmp/cwd6b3"
cat > "$tmp/h6b3/.claude/settings.json" <<'JSON'
{"env":{"NEXUSMIND_API_KEY":"nm_REAL_SECRET"}}
JSON
cat > "$tmp/h6b3/.claude.json" <<'JSON'
{"mcpServers":{"nexusmind":{"env":{"NEXUSMIND_BASE_URL":"https://approved-but-hostile.example"}}}}
JSON
out6b3="$(resolve_in "$tmp/h6b3" "$tmp/cwd6b3")"
check "an mcpServers URL is not donated to a key from another source" \
  "nm_REAL_SECRET$(printf '\t')" "$out6b3"
case "$out6b3" in
  *hostile*) printf '  FAIL the mcpServers URL was donated\n'; fail=$((fail+1));;
  *) printf '  ok   the mcpServers URL was not donated\n'; pass=$((pass+1));;
esac

# ── 6c. With no key anywhere there is nothing to leak, so a URL may still be
#        reported — it only decides which backend a later key would talk to ─────
mkdir -p "$tmp/h6c/.claude" "$tmp/cwd6c"
cat > "$tmp/h6c/.claude/settings.json" <<'JSON'
{"env":{"NEXUSMIND_BASE_URL":"https://only-a-url.example"}}
JSON
check "a URL with no key anywhere is still reported" \
  "$(printf '\t')https://only-a-url.example" "$(resolve_in "$tmp/h6c" "$tmp/cwd6c")"

# ── 6d. `$VAR` without braces is a placeholder too. Accepting it would put the
#        literal string on the wire as a bearer token ────────────────────────────
mkdir -p "$tmp/h6d/.claude" "$tmp/cwd6d"
cat > "$tmp/h6d/.claude/settings.json" <<'JSON'
{"env":{"NEXUSMIND_API_KEY":"$NEXUSMIND_API_KEY"}}
JSON
check "an unbraced \$VAR placeholder is not mistaken for a key" \
  "$(printf '\t')" "$(resolve_in "$tmp/h6d" "$tmp/cwd6d")"

# ── 6e. Only the real server name counts; "nexus-proxy" is somebody else's ─────
mkdir -p "$tmp/h6e" "$tmp/cwd6e"
cat > "$tmp/h6e/.claude.json" <<'JSON'
{"mcpServers":{"nexus-proxy":{"env":{"NEXUSMIND_API_KEY":"nm_wrong_server"}}}}
JSON
check "a look-alike server name does not supply the key" \
  "$(printf '\t')" "$(resolve_in "$tmp/h6e" "$tmp/cwd6e")"

# ── 7. Codex config.toml ─────────────────────────────────────────────────────
mkdir -p "$tmp/h7/.codex" "$tmp/cwd7"
cat > "$tmp/h7/.codex/config.toml" <<'TOML'
[mcp_servers.other.env]
NEXUSMIND_API_KEY = "wrong_section"

[mcp_servers.nexusmind.env]
NEXUSMIND_API_KEY = "nm_from_codex"
NEXUSMIND_BASE_URL = "https://x.example"
TOML
check "codex config.toml is read, and only the right section" \
  "nm_from_codex$(printf '\t')https://x.example" "$(resolve_in "$tmp/h7" "$tmp/cwd7")"

# ── 8. The process env wins — it is what the MCP server will actually send ───
mkdir -p "$tmp/h8/.claude" "$tmp/cwd8"
cat > "$tmp/h8/.claude/settings.json" <<'JSON'
{"env":{"NEXUSMIND_API_KEY":"nm_from_file"}}
JSON
check "the process env takes precedence over any file" \
  "nm_from_env$(printf '\t')" "$(resolve_in "$tmp/h8" "$tmp/cwd8" "nm_from_env")"

# ── 9. Corrupt JSON must degrade, never crash the hook ───────────────────────
mkdir -p "$tmp/h9/.claude" "$tmp/cwd9"
echo '{ this is not json' > "$tmp/h9/.claude/settings.json"
cat > "$tmp/h9/.claude.json" <<'JSON'
{"mcpServers":{"nexusmind":{"env":{"NEXUSMIND_API_KEY":"nm_after_bad_json"}}}}
JSON
check "a corrupt settings.json is skipped, not fatal" \
  "nm_after_bad_json$(printf '\t')" "$(resolve_in "$tmp/h9" "$tmp/cwd9")"

# ── 10. hydrate_nexusmind_env must actually export. This is the whole point of
#        the plugin fix, and the first version was a silent no-op: the python
#        writes no trailing newline, so `read` returns 1 at EOF and a `|| return 0`
#        swallowed both exports. Every hook kept deciding NexusMind was
#        unconfigured, which is the bug this was meant to close ─────────────────
mkdir -p "$tmp/h10/.claude" "$tmp/cwd10"
cat > "$tmp/h10/.claude/settings.json" <<'JSON'
{"env":{"NEXUSMIND_API_KEY":"nm_hydrated","NEXUSMIND_BASE_URL":"https://h.example"}}
JSON
hydrated="$( cd "$tmp/cwd10" && env -i HOME="$tmp/h10" PATH="$PATH" bash -c \
  "source '$SCRIPT_DIR/_helpers.sh'; hydrate_nexusmind_env; printf '%s|%s' \"\${NEXUSMIND_API_KEY:-}\" \"\${NEXUSMIND_BASE_URL:-}\"" )"
check "hydrate exports the key and URL into the environment" \
  "nm_hydrated|https://h.example" "$hydrated"

# ── 11. Hydrate must never overwrite what the process already has ─────────────
already="$( cd "$tmp/cwd10" && env -i HOME="$tmp/h10" PATH="$PATH" NEXUSMIND_API_KEY=nm_already bash -c \
  "source '$SCRIPT_DIR/_helpers.sh'; hydrate_nexusmind_env; printf '%s' \"\${NEXUSMIND_API_KEY:-}\"" )"
check "hydrate leaves an existing process key alone" "nm_already" "$already"

# ── 12. Hydrate must not fail the hook when nothing is configured; every hook
#        sources it under `set -euo pipefail` ──────────────────────────────────
mkdir -p "$tmp/h12" "$tmp/cwd12"
if ( cd "$tmp/cwd12" && env -i HOME="$tmp/h12" PATH="$PATH" bash -c \
     "set -euo pipefail; source '$SCRIPT_DIR/_helpers.sh'; hydrate_nexusmind_env; echo SURVIVED" ) \
     | grep -q SURVIVED; then
  printf '  ok   hydrate is safe under set -e with nothing configured\n'; pass=$((pass+1))
else
  printf '  FAIL hydrate aborts the hook when nothing is configured\n'; fail=$((fail+1))
fi

# ── 13. El caso que motivó todo: un workspace que NO es un repositorio. Sin
#        config, detect_project devuelve el nombre de la carpeta, que no es
#        ningún proyecto indexado, y el arranque apaga NexusMind ─────────────
ws="$tmp/ws"; mkdir -p "$ws/repoA/src" "$ws/repoB"
cat > "$ws/.nexusmind.yaml" <<'YAML'
version: 1
repository:
  id: ws
defaults:
  project: alpha
projects:
  alpha:
    project_id: alpha
    paths:
      - repoA
      - repoA/**
  beta:
    project_id: beta
    paths:
      - repoB
      - repoB/**
YAML
in_dir() { ( cd "$1" && bash -c "source '$SCRIPT_DIR/_helpers.sh'; detect_project" ); }
check "un subdirectorio mapeado resuelve a su proyecto"      "alpha" "$(in_dir "$ws/repoA")"
check "y también en profundidad"                              "alpha" "$(in_dir "$ws/repoA/src")"
check "otro subdirectorio resuelve al suyo"                   "beta"  "$(in_dir "$ws/repoB")"
check "la raíz del workspace usa defaults.project"            "alpha" "$(in_dir "$ws")"

# El default NO puede reclamar todo el árbol: un directorio sin mapear —un clon
# de otro repositorio, un directorio de trabajo— debe seguir con la inferencia,
# no heredar el proyecto por defecto del workspace.
mkdir -p "$ws/ajeno/deep"
check "un directorio sin mapear NO hereda el default"        "deep"  "$(in_dir "$ws/ajeno/deep")"

# ── 14. El config manda sobre la inferencia por git: dentro de un clon cuyo
#        nombre NO coincide con el proyecto, gana lo que dice el config ──────
gitws="$tmp/gitws"; mkdir -p "$gitws/vendor-checkout"
cat > "$gitws/.nexusmind.yaml" <<'YAML'
version: 1
repository:
  id: gitws
projects:
  el-nombre-real:
    project_id: el-nombre-real
    paths:
      - vendor-checkout
      - vendor-checkout/**
YAML
( cd "$gitws/vendor-checkout" && git init -q . 2>/dev/null && git remote add origin https://github.com/x/nombre-enganoso.git 2>/dev/null ) || true
check "el config gana a la inferencia por remoto de git" \
  "el-nombre-real" "$(in_dir "$gitws/vendor-checkout")"

# ── 15. Sin config no cambia nada: la inferencia de siempre ─────────────────
plain="$tmp/plain/mi-repo"; mkdir -p "$plain"
check "sin config, sigue infiriendo del directorio" "mi-repo" "$(in_dir "$plain")"

# ── 16. Un config ilegible no puede tumbar el arranque de sesión ────────────
broken="$tmp/broken"; mkdir -p "$broken/sub"
printf 'esto: no es\n  yaml: [valido\n' > "$broken/.nexusmind.yaml"
got="$(in_dir "$broken/sub" 2>/dev/null)"
if [[ -n "$got" ]]; then
  printf '  ok   un config roto degrada a la inferencia (%s)\n' "$got"; pass=$((pass+1))
else
  printf '  FAIL un config roto deja a detect_project sin respuesta\n'; fail=$((fail+1))
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
