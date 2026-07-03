#!/usr/bin/env bash
# _helpers.sh — shared helper functions for NexusMind Claude Code plugin scripts

# detect_project: determines the project name from git or directory context.
# Priority: git remote origin repo name → git root basename → cwd basename.
detect_project() {
  local project=""

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
