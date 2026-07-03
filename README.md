# NexusMind — Claude Code Plugin

Team memory for AI coding agents. Store decisions, bugs, and conventions — shared across the whole team.

## What it does

- Injects your team's recent memories into every Claude Code session as context
- Provides `store_memory`, `search_memory`, and `list_memories` tools via MCP
- Reminds Claude Code to save decisions proactively throughout the session
- Passively captures subagent output for team context

## Requirements

- Node.js 18+
- A NexusMind API key (`NEXUSMIND_API_KEY`)
- Claude Code

## Install

```bash
claude plugin marketplace add smart-coder-labs/nexus-mind
claude plugin install nexusmind
```

The marketplace install is the only supported path. The plugin registers the
`nexusmind` MCP server itself via its bundled `plugin/.mcp.json` — do **not**
also run `claude mcp add nexusmind` (or the MCP package's `setup` for Claude
Code). A user-level registration on top of the plugin double-registers the
server and roughly doubles the MCP tool-schema token cost on every session.

If you previously registered the server at the user level, remove it:

```bash
claude mcp remove nexusmind
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `NEXUSMIND_API_KEY` | — | Your NexusMind API key (required) |
| `NEXUSMIND_BASE_URL` | `https://nexusmind-backend.fly.dev` | Backend URL (optional, for self-hosting) |

Set these in your shell profile or pass them before running Claude Code:

```bash
export NEXUSMIND_API_KEY=your-key-here
```

## What gets installed

The plugin bundles everything:
1. The `nexusmind` MCP server, registered via the plugin's own `plugin/.mcp.json`
2. Lifecycle hooks (SessionStart, PreCompact, PostCompact, SessionEnd, UserPromptSubmit, SubagentStop, Stop)
3. The `memory` skill with the full memory protocol

### Lifecycle hooks

| Hook | Event | Behavior |
|------|-------|----------|
| `session-start.sh` | `SessionStart` (`startup`/`clear`) | Injects recent + project memories as context at session start. |
| `post-compaction.sh` | `PostCompact` | Emits recovery context right after compaction completes (previously ran on `SessionStart` with matcher `compact` — moved to the dedicated `PostCompact` event). `PostCompact` does not auto-inject plain stdout the way `SessionStart` does, so the hook wraps its output in the `{"hookSpecificOutput":{"hookEventName":"PostCompact","additionalContext":"..."}}` envelope. |
| `pre-compact.sh` | `PreCompact` | Runs synchronously before compaction destroys context; persists a snapshot of the last ~15 assistant messages to NexusMind (upserted per session via `topic_key: session-snapshot/{session_id}`) so nothing is lost even if the model doesn't save first. |
| `session-end.sh` | `SessionEnd` | Fallback: if the session ends and the model never saved a `session_summary`, auto-captures one from the last ~15 assistant messages. Shares `pre-compact.sh`'s `topic_key: session-snapshot/{session_id}` namespace so both upsert into one record per session instead of leaving duplicate near-identical entries. |
| `user-prompt-submit.sh` | `UserPromptSubmit` | Injects recall context on recall-intent prompts (mode-controlled). |
| `subagent-stop.sh` | `SubagentStop` (async) | Passively captures subagent output that looks decision-like. |
| `session-stop.sh` | `Stop` | Gate (runs synchronously, not async, so it can block): if the turn since the last real user message looks like it produced a decision/fix/discovery and nothing was saved via `store_memory`, blocks once per session with a reminder to save. Set `NEXUSMIND_STOP_GATE=off` to disable. |

The `NEXUSMIND_API_KEY` and `NEXUSMIND_BASE_URL` environment variables are
read from your shell environment — set them in your shell profile.

## MCP Tools

| Tool | When to use |
|------|-------------|
| `store_memory` | Save a decision, bug fix, convention, or discovery (`auto_tag` for automatic classification) |
| `search_memories` | Search or browse memories (with `query` = semantic search; without = filtered listing) |
| `get_memory` | Fetch full untruncated content by id |
| `get_context` | Bootstrap a session with project context (`mode: compact\|full`) |

## Uninstall

```bash
claude plugin uninstall nexusmind
```

Remove the `NEXUSMIND_API_KEY` and `NEXUSMIND_BASE_URL` exports from your shell profile.
If you ever registered the server at the user level, also run `claude mcp remove nexusmind`.
