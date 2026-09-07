---
name: nexusmind-code
description: NexusMind semantic code search — how to find and understand code without scanning the tree. Triggers whenever you need to locate where something is defined, how a pattern is implemented, what handles a concern, or which files are relevant to a change — i.e. before reading files or reaching for grep/rg/find. Encodes the "locate first, read second" discipline and the index-then-search flow the plain tool descriptions cannot convey on their own.
---

# NexusMind Code Search — Protocol

This project's code is indexed in NexusMind. Finding code is therefore a **semantic lookup**, not a filesystem scan. Reaching for `grep`/`rg`/`find` (or the `Grep` tool) to discover code reads files the index already knows about and burns context for nothing.

## The rule

**To find or understand code, call NexusMind first. Do not grep the tree.**

### `locate_code` first, always

`search_code` returns whole symbols and is roughly ten times more expensive per
call. Measured on a real session: `locate_code` averaged 2,422 characters per
call, `search_code` 25,108 — and one call returned 40,334. Over five calls that
was 125,540 characters, more than twice what the same session spent reading
files directly.

So: **locate first, then read the file.** `locate_code` (≈2.4k) plus a targeted
`Read` (≈2.1k) costs about a fifth of one `search_code`, and it is what you end
up doing anyway — that same session went on to read 13 files after searching.

Reach for `search_code` only when the paths alone did not answer it: you need to
see how something is written across several files, or you do not know which of
the ranked files holds the part you want.

**Never send the same query to both.** Observed and wasteful: a query went to
`locate_code` for 2,621 characters and then to `search_code` for 27,424 — ten
times the cost for a question already answered.

A trimmed `search_code` hit ends with the file and line range it came from. That
is not a defect to work around; it is the pointer. Read those lines if you need
the rest, rather than re-running the search with a wider net.

| Need | Tool | Returns |
|------|------|---------|
| Anything — **start here** | `mcp__nexusmind__locate_code` | Ranked **file paths** (no bodies) — token-cheap |
| The paths were not enough | `mcp__nexusmind__search_code` | Ranked **code chunks** |
| "Is this project indexed / what's in it?" | `mcp__nexusmind__list_code_files` | Indexed file paths |
| "Index it first" | `mcp__nexusmind__index_project` | Builds the index (once, or after big changes) |

## The flow

1. **Locate, then read.** For any "where is…/how does…/what handles…" question, call `locate_code` with a natural-language query, then `Read` only the files it ranks. Use `search_code` when you want the code chunks directly.
2. **Not indexed yet?** If a code tool reports the project is not indexed, call `index_project` (local `root_path` or a `repo_url`) once, then search.
3. **Reading a specific known file** is fine — `Read` it directly. The rule is about *discovery*, not about opening a file you already know.

## When grep is legitimately right

Semantic code search is for code. For a genuine **non-code** text hunt — log files, data fixtures, a one-off string in generated output — grep is the right tool and nothing stands in the way.

This used to be enforced by a PreToolUse hook that denied grep. It was removed after measurement: the denial did not stop the agent grepping, it made it cost more. The agent lost a round trip to the refusal and then ran the same search through the documented escape hatch — `NEXUSMIND_ALLOW_GREP=1` appeared ten times in one measured set. Removing the gate cut cost per task by 26.5%, with disjoint ranges on tool calls and context in two of three session shapes, and no change in correctness. The guidance above stands on its own merits; it is advice now, not a wall.
