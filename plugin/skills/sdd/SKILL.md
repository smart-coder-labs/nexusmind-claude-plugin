---
name: nexusmind-sdd
description: NexusMind SDD artifact protocol — how agents save, read, version and link the documents of a spec-driven change (proposal, spec, design, tasks, verify-report). Triggers when running any SDD phase, reading a prior phase's artifact, resuming a change after compaction or on a fresh machine, checking what changes are in flight, or any question about save_sdd_artifact / get_sdd_artifact / the `nexusmind` persistence mode. Encodes the dual-persistence contract and the both-writes-or-fail rule that the individual MCP tool descriptions cannot convey on their own.
---

# NexusMind SDD Artifacts — Persistence Protocol

You have NexusMind **SDD artifact** tools available. An *SDD change* is one `openspec/changes/{name}/` folder: a proposal, its delta specs, a design, a task list, and the reports the phases produce. This skill is how those documents are persisted, read back, and linked.

This is the **artifact protocol**, not the phase workflow. The `sdd-*` phase skills (`sdd-propose`, `sdd-design`, `sdd-tasks`, …) are a separate **harness**, installed from the harness library — they decide *what* to write. This skill decides *where it goes and how it comes back*.

## The one rule that governs everything

**Both writes succeed, or the phase fails loudly.**

An artifact lives in two places on purpose:

| | git (`openspec/`) | NexusMind |
|---|---|---|
| authoritative for | the reviewable text, in a PR, on a branch | the queryable, linkable, cross-session record |
| gives you | diff review, blame, offline, rollback | search, the admin UI, task/sprint/memory links, recovery after compaction |

Neither is a cache of the other. Write the file **and** call `save_sdd_artifact`. If either leg fails, the phase is **FAILED** — not "partially done". Silent degradation to single persistence is the exact failure this whole system exists to prevent: it is how you end up with a design document that exists on one laptop and nowhere else.

## Tools at a glance

| Tool | When |
|------|------|
| `save_sdd_artifact` | After writing any artifact file. Every phase, every time. |
| `get_sdd_artifact` | Before a phase that depends on an earlier one. **This is the cross-phase read.** |
| `get_sdd_change` | Resuming a change — the artifact inventory *is* the recoverable state. |
| `list_sdd_changes` | "What's in flight?" — powers `/sdd-status`. |
| `update_sdd_change` | Phase and status transitions. |
| `search_sdd_artifacts` | "Which spec covers rate limiting?" — full-text, across every change in the org. |
| `link_sdd_change_memory` | Tie a decision or bugfix back to the change that produced it. |

## Saving (`save_sdd_artifact`)

Call it **unconditionally**, after every artifact write. Do **not** add a "did the content change?" guard — the backend already de-duplicates by content hash: re-saving identical content creates **no revision**, touches no index, and does not bump any timestamp. Your defensive check would be dead code that can only introduce bugs.

Required: `project`, `change_name`, `kind`, `content`. Strongly recommended: `path` (the repo-relative file path, so the store knows where the file lives).

The `kind` strings are the **on-disk filename stems**, and three of them are hyphenated:

```
exploration  proposal  spec  design  tasks
apply-progress   verify-report   archive-report   state
```

`apply_progress` is **rejected**. The DB and the filesystem have to agree about the identity of the same document.

`spec` is the only kind that repeats within a change — once per capability, from `specs/{capability}/spec.md`. Pass `capability` for it, and only for it.

**Re-running a phase appends a revision; it never overwrites.** Content A → B → A appends *revision 3* — a revert is an event and belongs in the history. There is no way to lose an earlier version.

## Reading (`get_sdd_artifact`) — the part that matters

When a phase depends on an earlier one, fetch it with `get_sdd_artifact`. It returns the **complete document**.

This is the whole point of the tool. Do **not** reach for `search_memory` to recover an artifact: memory search returns a *truncated preview*, and a design document is tens of kilobytes. A phase that plans against a truncated design plans against a document it has not read.

A missing artifact reports **not-found** — never an empty string. `Ok(None)` means *"there is no design yet"*, which is different from *"the design is empty"*. If a required dependency is absent, **stop and report blocked**. Do not proceed on a blank document.

## Resuming (`get_sdd_change`)

After a compaction, on a fresh machine, or with no checkout at all: `get_sdd_change` returns the change with its full artifact inventory. **That inventory is the state.** You do not need `state.yaml`, and you do not need the repo — you can tell exactly which phases have run by which artifacts exist.

## Phase transitions (`update_sdd_change`)

Phase is **advisory metadata**, not a write gate. Saving a `verify-report` to a change still in `propose` is accepted — the artifact inventory is the ground truth, and out-of-order work is legitimate. But keep the record honest: advance the phase explicitly with `update_sdd_change`.

`update_sdd_change` takes a **change id**, not a name. Resolve it first (`get_sdd_change` / `list_sdd_changes`), then transition. Never encode state by editing an artifact's content.

Phases: `explore → propose → spec → design → tasks → apply → verify → archive`.
Statuses: `active | archived | abandoned`.

## Linking

- `link_sdd_change_memory` — when a phase records a decision or a bugfix, link it to the change. Idempotent; re-linking with a different `relation` (`produced` / `informed`) updates it, so call it freely.
- Tasks link to changes by **name**, through the existing `link_task_spec` tool (see the `nexusmind-tasks` skill). A change and its tasks find each other through that name — there is no second foreign key to maintain.

## Gotchas

- **The 1 MB cap is atomic.** An oversized `content` is rejected with 422 and leaves *no* change, *no* artifact and *no* revision behind. It does not half-create anything.
- **Content is never returned by list endpoints.** `list_sdd_changes` and the revision list carry metadata only. Ask for content per artifact or per revision.
- **Artifacts are read-only from the admin UI.** The admin curates (phase, status, sprint, memory links); it never authors artifact content. You and git are the only writers.
- **An archived change is still a valid link target.** Archiving hides a change from the default list; it does not withdraw its artifacts or break its task links.

## Related

- `nexusmind-memory` — decisions, bugfixes and discoveries. **Artifacts are not memories.** Never save a design document as a memory: that is what this tool set replaced, and it is why memory search used to be full of spec fragments.
- `nexusmind-tasks` — filing and advancing the tasks a change spawns, and `link_task_spec`.
- `nexusmind-harness` — installing the `sdd-*` phase skills, which drive the workflow this protocol persists.
