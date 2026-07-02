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
2. Lifecycle hooks (SessionStart, UserPromptSubmit, SubagentStop, Stop)
3. The `memory` skill with the full memory protocol

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
