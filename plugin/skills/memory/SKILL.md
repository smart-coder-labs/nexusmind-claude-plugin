---
name: nexusmind-memory
description: NexusMind persistent team memory protocol — the single source of truth for recalling past work, saving decisions/conventions/bug fixes, and answering memory-protocol questions. Triggers on recalling past work or prior decisions, saving a decision/convention/bug fix/discovery, session start or post-compaction recovery, or any question about how the NexusMind memory protocol works.
---

# NexusMind Memory — Protocol

You have NexusMind memory tools available. Use this protocol whenever you recall past work, save something worth remembering, or need the full behavioral detail that the hook scripts only summarize.

## Core Tools

| Tool | Purpose |
|------|---------|
| `store_memory` | Save decisions, bugs, discoveries, conventions — PROACTIVELY, without being asked |
| `search_memory` | SEMANTIC search by topic. Pass the project via the `project` filter, never as the query. Never search the project name itself. |
| `list_memories` | List a project's memories via the `project` filter — the right tool for "show me this project's context" |
| `get_context` | Recover a project's accumulated context |
| `get_memory` | Full untruncated content by id — previews are not enough |
| `delete_memory` | Only when the user explicitly asks; requires `confirm: true` |

## Proactive Save Rule

Call `store_memory` IMMEDIATELY after ANY of the following — do NOT wait to be asked:

- Architecture or design decision made
- Bug fixed (include root cause and what broke)
- Convention documented or established
- Tool or library choice made with reasoning
- Non-obvious discovery, gotcha, or edge case found
- Pattern established (naming, structure, approach)
- Feature implemented with a non-obvious approach
- Any configuration or environment change

Always pass `tool="claude-code"` and set `project` to the detected project name.

**Self-check after EVERY task**: "Did I make a decision, fix a bug, learn something non-obvious, or establish a convention? If yes, call store_memory NOW."

### Type taxonomy

ALWAYS set `type` on `store_memory` — pick the closest match:

- `architecture` — design decisions, patterns, system structure
- `bugfix` — bug fixes (include root cause)
- `decision` — explicit choices made (library, approach, tradeoff)
- `discovery` — non-obvious findings, gotchas, edge cases
- `config` — environment, tooling, infrastructure changes
- `pattern` — naming conventions, code patterns, team standards
- `feedback` — user corrections or confirmations of your approach
- `preference` — user style or workflow preferences
- `session_summary` — end-of-session summary
- `feature` — completed feature implementations
- `refactoring` — structural code changes without behavior change

ALWAYS provide `title` — short (5-10 word) searchable title.
Use `topic_key` for evolving topics — the same key updates the existing memory instead of creating a duplicate.

## When to Search

- User's first message references a feature or problem → call `search_memory` with a **semantic query built from the topic** (e.g. "how login refreshes tokens"), scoping with the `project` filter
- Starting work on something that might have been done before → call `search_memory` by topic
- User asks to recall anything → call `search_memory` by topic
- About to make a non-trivial decision → call `search_memory` first
- You want the project's overall context (not a specific topic) → use `get_context` or `list_memories` with the `project` filter, **not** `search_memory("<project-name>")`

**Rule:** the query describes *what* you're looking for. The project is already scoped by the `project` filter — never put the project name in the query. Searching the project name returns noise and misses relevant memories.

## Session Close (MANDATORY)

Before saying "done" (or any equivalent in the user's language), call `store_memory` with `type="session_summary"`:

```
What was accomplished this session
Key decisions made and why
Files changed (with paths)
Next steps for the following session
```

This is NOT optional. Skipping this means the next session starts blind — no team context, no continuity.

## After Compaction

If you see a compaction message or "FIRST ACTION REQUIRED":

1. IMMEDIATELY call `store_memory` with `type="session_summary"` and a summary of what was being worked on before compaction
2. Call `get_context` (or `list_memories` with the `project` filter) to recover this project's context — not `search_memory("<project-name>")`
3. Only THEN continue working

Do not skip step 1. Without it, everything done before compaction is lost.

## Relationship to the hook scripts

`session-start.sh`, `post-compaction.sh`, and `user-prompt-submit.sh` only inject short pointers to this skill (tool list, proactive-save rule, search rule, session-close mandate) to keep per-session and per-prompt token cost low. This file is the single source of truth for the full protocol — if a hook's short pointer and this file ever seem to disagree, this file wins.
