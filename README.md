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

Choose **one** install path below — do not combine them. Options 1 and 2 both
register the `nexusmind` MCP server at the user level (`~/.claude.json`).
Option 3 (marketplace) auto-registers it via the plugin's own
`plugin/.mcp.json` instead. Running a user-level `claude mcp add` on top of a
marketplace install double-registers the server and roughly doubles the MCP
tool-schema token cost on every session.

Note: `install.sh` (used by Options 1 and 2) lives in the separate
[`smart-coder-labs/nexus-mind`](https://github.com/smart-coder-labs/nexus-mind)
repository, not in this repo. This repo's own tooling (Option 3, the
marketplace install) does not detect or prevent a prior user-level
registration — the warning above is manual guidance, not an automated guard.

### Option 1 — one-liner

```bash
curl -fsSL https://raw.githubusercontent.com/smart-coder-labs/nexus-mind/main/plugin/claude-code/install.sh | bash
```

### Option 2 — clone and run

```bash
git clone https://github.com/smart-coder-labs/nexus-mind.git
bash nexus-mind/plugin/claude-code/install.sh
```

### Option 3 — Claude plugin marketplace

```bash
claude plugin marketplace add smart-coder-labs/nexus-mind
claude plugin install nexusmind
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

The installer (Options 1/2, from the `smart-coder-labs/nexus-mind` repo):
1. Adds the `nexusmind` MCP server to `~/.claude.json` (user scope)
2. Adds lifecycle hooks (SessionStart, UserPromptSubmit, SubagentStop, Stop) to `~/.claude/settings.json`
3. Writes `NEXUSMIND_API_KEY` and `NEXUSMIND_BASE_URL` to `~/.bashrc` and `~/.zshrc`

## MCP Tools

| Tool | When to use |
|------|-------------|
| `store_memory` | Save a decision, bug fix, convention, or discovery |
| `search_memory` | Look up past decisions or context |
| `list_memories` | Browse recent team memories |

## Uninstall

Remove the `nexusmind` entry from `~/.claude.json` (`mcpServers`) and from
`~/.claude/settings.json` (`hooks`).
Remove the `NEXUSMIND_API_KEY` and `NEXUSMIND_BASE_URL` exports from your shell profile.
