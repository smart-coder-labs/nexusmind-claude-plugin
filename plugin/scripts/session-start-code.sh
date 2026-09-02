#!/usr/bin/env bash
# SessionStart hook: put code discovery on NexusMind from the first turn.
#
# The PreToolUse hook already denies grep/rg/find for code, but a denial costs a
# wasted turn: the agent greps, gets blocked, then pivots. Stating the rule up
# front as session context makes locate_code/search_code the agent's FIRST move,
# so the block is a backstop rather than the normal path.
#
# SessionStart hook stdout is injected into the session as additional context.
set -euo pipefail

cat <<'CTX'
## NexusMind — Code Search

This project's code is indexed in NexusMind. To find or understand code — where
something is defined, how a pattern is implemented, which files a change touches —
call `mcp__nexusmind__locate_code` (ranked file paths) or
`mcp__nexusmind__search_code` (ranked code chunks) FIRST, then read only what they
point to. Do NOT use grep/rg/find or the Grep tool for code discovery — those
calls are denied by a hook. If the project is not indexed, call
`mcp__nexusmind__index_project` first. Full detail: the nexusmind-code skill.
CTX
