---
name: nexusmind-harness
description: NexusMind shared-harness workflow — how and when to recommend, install, create, and share reusable AI tooling setups (skills, agents, commands, hooks, plugins) across Claude Code, Codex, and Cursor. Triggers when the user wants to discover or recommend a harness, install/download one to their tool, package and publish their own setup, or share a redacted config for review. Enforces the approval-first, never-silent install discipline that the individual MCP tool descriptions cannot convey on their own.
---

# NexusMind Harnesses — Usage Protocol

You have NexusMind **harness** tools available. A *harness* is a versioned, hash-pinned bundle of reusable AI tooling — a skill, agent, command, hook, output style, Claude Code plugin, or theme — that a team publishes once and installs into Claude Code, Codex, or Cursor.

This skill tells you **when** to reach for each tool, **how** to sequence them, and **why** the sequence is non-negotiable. The per-tool descriptions only explain a single tool in isolation; the workflow below is what makes them safe.

## The one rule that governs everything

**Never mutate the user's local files silently.** The backend never writes to disk — only the local install tool does, and only after the user has seen a diff and explicitly confirmed. Every install is two phases: **plan (writes nothing) → user confirms → apply (writes)**. If you ever find yourself about to write to `~/.claude`, `.cursor`, or `~/.codex` without having shown the user a diff first, stop.

## Tools at a glance

| Group | Tool | Use it to |
|-------|------|-----------|
| Discover | `recommend_harnesses` | Suggest relevant harnesses (metadata only — no download) |
| Discover | `list_harnesses` | Browse the catalog the user can access |
| Discover | `get_harness_version` | Read a specific version's manifest for preview (no approval needed) |
| Discover | `list_harness_config_reviews` | List shared config-review snapshots |
| Install | `plan_harness_install` | Produce a per-file diff for a target tool — **writes nothing** |
| Install | `apply_harness_install` | Record approval, materialize files, record result — **only after confirmation** |
| Publish | `build_harness_manifest_from_path` | Turn a local folder into a valid manifest (sha256, secret-scan) |
| Publish | `create_harness` | Create a new harness entry |
| Publish | `publish_harness_version` | Publish an immutable version |
| Share | `create_harness_config_review` | Share a redacted config snapshot for team review |

## Workflow 1 — Recommend / discover

When the user asks "is there a harness for X?", "what setups does my team have?", or is starting a task a shared harness might cover:

1. Call `recommend_harnesses` (optionally with `target` = `claude` \| `codex` \| `cursor`) or `list_harnesses`.
2. Present name, description, owner, format, and target tools. This is **metadata only** — do not download or install.
3. If the user wants details, use `get_harness_version` to show the manifest contents (safe, no approval required).
4. Stop there unless the user asks to install. Recommending ≠ installing.

## Workflow 2 — Install to the user's tool (the careful path)

When the user says "install that", "add it to my Claude/Cursor/Codex":

1. **Plan first.** Call `plan_harness_install` with `harness_id`, `version`, `target_tool`, and `scope`. It returns a `DiffEntry[]`: for each file, the destination path, whether it's a `create` or `overwrite`, and any warning. It writes nothing.
2. **Show the diff to the user.** Especially call out any `overwrite` entries (an existing local file will change) and any executable formats (`hook`, `claude_code_plugin`).
3. **Get explicit confirmation.** Do not proceed on a vague "ok" if there are overwrites or executables — name what will change.
4. **Apply.** Call `apply_harness_install` with the confirmation. Two gates you MUST satisfy:
   - `warning_acknowledged: true` is **required** for executable formats (`hook`, `claude_code_plugin`) — never set it without the user actually acknowledging the executable risk.
   - `overwrite_confirmed: true` is **required** if any diff entry is an `overwrite`. Without it, apply refuses with zero writes.
5. **Read the result.** `result_status` will be one of `installed`, `failed`, `hash_mismatch`, or `overwrite_not_confirmed`. On `hash_mismatch` the manifest changed since you planned — re-run `plan_harness_install` and re-confirm; do not retry apply blindly.

## Workflow 3 — Create and publish a harness

When the user wants to package their own skill/agent/hook/etc. and share it:

1. `build_harness_manifest_from_path(path, format, targets)` reads the local files, computes sha256, inlines content (≤64 KiB per file), and runs a **secret scan**. If the scan finds a secret, the build **refuses** — no partial manifest. Fix the leak (or exclude the file) before retrying; never try to force-publish past a secret finding.
2. `create_harness` to register the entry (slug, name, description, visibility, targets).
3. `publish_harness_version` to publish the immutable, hashed version.
4. `targets` must be `claude`, `codex`, and/or `cursor`. `cursor` is a first-class target (it replaced the old `opencode`).

## Workflow 4 — Share a config for review

When the user wants feedback on their config without leaking secrets: `create_harness_config_review` redacts secrets locally and produces a preview + redaction report **before** upload. Always show the user the redaction report so they can confirm nothing sensitive leaks.

## Per-tool destinations & the format matrix

Installs land in tool-specific locations; not every format installs to every tool.

| | Claude Code (`~/.claude/`) | Cursor (`.cursor/`) | Codex (`~/.codex/`) |
|---|---|---|---|
| `agent`, `command` | ✅ | ✅ | ✅ (conservative default) |
| `hook`, `claude_code_plugin` | ✅ | mcp.json / settings | limited |
| `skill`, `output_style` | ✅ | ❌ Claude-only | ❌ Claude-only |
| `theme` | ✅ | partial | n/a |

`skill` and `output_style` are Claude-centric — if the user asks to install one to Cursor or Codex, `plan_harness_install` will refuse the unsupported pair. Explain that rather than trying to force it. Codex destinations are a conservative default pending better upstream docs; flag that when relevant.

## Gotchas

- **Recommend, don't auto-install.** Surfacing a harness never implies permission to download or write it.
- **The plan is the contract.** If the manifest hash drifts between plan and apply, re-plan — the user must re-see what changed.
- **Secret scan is a hard gate, not a warning.** A build that hits a secret produces no manifest.
- **One publish reaches all clients.** Claude Code, Codex, and Cursor consume the same MCP server; there is no per-client tool wiring to update.
