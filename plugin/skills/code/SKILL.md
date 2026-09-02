---
name: nexusmind-code
description: NexusMind semantic code search — how to find and understand code without scanning the tree. Triggers whenever you need to locate where something is defined, how a pattern is implemented, what handles a concern, or which files are relevant to a change — i.e. before reading files or reaching for grep/rg/find. Encodes the "locate first, read second" discipline and the index-then-search flow the plain tool descriptions cannot convey on their own.
---

# NexusMind Code Search — Protocol

This project's code is indexed in NexusMind. Finding code is therefore a **semantic lookup**, not a filesystem scan. Reaching for `grep`/`rg`/`find` (or the `Grep` tool) to discover code reads files the index already knows about and burns context for nothing — and the PreToolUse hook will deny those calls and send you back here.

## The rule

**To find or understand code, call NexusMind first. Do not grep the tree.**

| Need | Tool | Returns |
|------|------|---------|
| "Which file(s) do I read for X?" | `mcp__nexusmind__locate_code` | Ranked **file paths** (no bodies) — token-cheap |
| "Show me the code for X" | `mcp__nexusmind__search_code` | Ranked **code chunks** |
| "Is this project indexed / what's in it?" | `mcp__nexusmind__list_code_files` | Indexed file paths |
| "Index it first" | `mcp__nexusmind__index_project` | Builds the index (once, or after big changes) |

## The flow

1. **Locate, then read.** For any "where is…/how does…/what handles…" question, call `locate_code` with a natural-language query, then `Read` only the files it ranks. Use `search_code` when you want the code chunks directly.
2. **Not indexed yet?** If a code tool reports the project is not indexed, call `index_project` (local `root_path` or a `repo_url`) once, then search.
3. **Reading a specific known file** is fine — `Read` it directly. The rule is about *discovery*, not about opening a file you already know.

## When grep is legitimately right

Semantic code search is for code. For a genuine **non-code** text hunt — log files, data fixtures, a one-off string in generated output — grep is the right tool. In that case either export `NEXUSMIND_ALLOW_GREP=1` for the session or add `# nexusmind:allow` to the command, and the hook will step aside. Do not use this to route around code discovery.
