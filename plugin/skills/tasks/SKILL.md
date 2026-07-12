---
name: nexusmind-tasks
description: NexusMind team task convention — how agents create, label, assign, link, and advance tasks so the tracker stays usable. Triggers when creating or updating a task, filing follow-up work, picking up or finishing a task, opening a PR for tracked work, linking a task to an openspec change, working within a sprint, or any question about task labels, priorities, or the status workflow. Encodes the create-then-enrich sequence and the status discipline that the individual MCP tool descriptions cannot convey on their own.
---

# NexusMind Tasks — Convention

You have NexusMind **task** tools available. This skill is the convention for using them: **what a task must contain before you consider it filed, and who moves it forward afterwards (you).**

It exists because the tracker shipped labels, sprints, due dates, spec links and a status state machine — and nothing ever told agents to fill them. Agents create most of the tasks in the system, and they arrive unlabeled, unassigned, sprintless, and then sit in `backlog` forever because the same agent that created the task never advanced it. Every filter built on top of those fields — `list_tasks(label:)`, `list_tasks(sprint:)`, the admin board's status columns — is dead weight for exactly the tasks agents create most. A task nobody can filter, and whose status is a lie, is worse than no task at all.

## The one rule that governs everything

**`create_task` is the first call, never the last.** It accepts no labels, no assignees, no status — those are separate calls, and an agent that stops after `create_task` has produced a task that fails every filter in the admin. A task is not filed until it has an assignee and at least two labels. And a task you are working on is not done being maintained until its status says so.

## Tools at a glance

| Group | Tool | Use it to |
|-------|------|-----------|
| Read | `list_tasks` | Filter by project, status, sprint, label, assignee |
| Read | `list_my_tasks` | The caller's own tasks — identity comes from the API key, never pass a user id |
| Read | `get_task` | Full detail: assignees, labels, spec links, comment/subtask counts |
| Write | `create_task` | Create — `project` + `title` only; **no labels/assignees/status inline** |
| Write | `update_task` | Title, description, **status**, priority, due date, sprint |
| Write | `assign_task` | Attach user ids (`list_users` / `get_project_members` to resolve them) |
| Write | `add_task_label` | One free-text label per call, idempotent |
| Write | `add_task_comment` | Progress notes, blockers, PR links |
| Write | `link_task_spec` | Link to an openspec change folder (kebab-case) |
| Write | `resolve_tasks_for_spec` | Close every task linked to a change — for the sdd-verify/sdd-archive flow |
| Sprint | `list_sprints` | Find the active sprint **before** creating a task |
| Sprint | `create_sprint`, `create_sprint_retrospective` | Sprint management (`task:manage`) |
| Delete | `delete_task` | Only when the USER explicitly asks; requires `confirm: true` |

## When to create a task at all

Create a task when work is **deferred, delegated, or tracked by someone other than you in this turn**:

- Follow-up work you found but are not doing now (a TODO you are leaving behind)
- Work that will span more than one PR, or belongs to a sprint
- A bug you discovered while doing something else
- Work the user asked you to file rather than do
- Any unit of work that maps to an openspec change

Do **NOT** create a task for:

- Something you are about to do in this same turn and finish — just do it
- Trivia: typo fixes, one-line cleanups, an obvious refactor you already did
- Anything already captured by an existing task — `list_tasks` (filter by label/project) before filing a near-duplicate
- A decision, gotcha, or convention — that is a **memory**, not a task. Use `store_memory` (see the `nexusmind-memory` skill)

The tracker is a work queue, not a notebook. Spamming it with trivia is a different failure than leaving it empty, and it is just as bad.

## The create sequence (MANDATORY)

Every agent-created task gets **all** of the following. This is 3–5 tool calls, not one.

1. **`create_task`** — `project`, `title`, `description`, `priority`.
   - `title` = **verb + what**: "Add label filter to admin task list", not "Label filter" or "Admin".
   - `description` = enough for a teammate who wasn't here: what, why, where (file paths), and what "done" looks like.
   - `priority` = `low` | `medium` | `high` | `urgent` (defaults to `medium` — set it deliberately anyway).
   - Optional here: `due_date` (ISO-8601), `parent_id`, `sprint_id`.
   - The task comes back with an `id`. Every call below needs it.
2. **`assign_task`** — never leave a task unassigned. If the user is doing the work, assign them; if an agent/owner is implied, assign that user. Resolve ids with `get_project_members` or `list_users`. If you genuinely cannot determine an owner, say so and ask — do not silently skip.
3. **`add_task_label`** — **at least two labels**, one call each:
   - **A kind label**: `feature` | `bug` | `refactor` | `docs` | `chore`
   - **An area label**: `backend` | `admin` | `mcp` | `harness` | `landing` | `infra`
   - Both lists are conventions, not enums — labels are free text and the vocabulary is extensible. Extend it deliberately: reuse an existing label whenever one fits, because a one-off label is invisible to every filter that matters.
4. **`link_task_spec`** — if an openspec change exists (or is being written) for this work, link it: `spec_change_name` is the kebab-case change folder name. This is what lets `resolve_tasks_for_spec` close the task automatically when the change is archived.
5. **`sprint_id`** — if the project has an **active** sprint and this work belongs to it, attach it. Call `list_sprints(project, status: "active")` first; pass `sprint_id` to `create_task`, or set it later with `update_task`. Do not invent sprint ids, and do not park in-sprint work outside the sprint.

## Status discipline (the failure this skill exists to prevent)

New tasks start in **`backlog`**. `create_task` cannot set a status — only `update_task` moves it. The recurring failure is agents creating tasks and never touching them again, so the board reads "nothing has ever been started" while the work is merged and shipped.

If you are doing the work, **you** move the task:

| Moment | Call |
|--------|------|
| Queued for this cycle, not started | `update_task(status: "todo")` |
| You start the work | `update_task(status: "in_progress")` — **do this before writing code** |
| You open the PR | `update_task(status: "in_review")` + `add_task_comment` with the PR link |
| PR merged | `update_task(status: "done")` |
| Work abandoned / obsolete | `update_task(status: "cancelled")` |

If you pick up an existing task, the first thing you do is set it to `in_progress`. If you finish work that a task tracks, the last thing you do is close it. "I'll update it later" is how the board rotted in the first place.

### Legal transitions

The backend enforces a state machine; an illegal transition is rejected and nothing changes. Same-state is a no-op and always allowed.

| From | Allowed next |
|------|--------------|
| `backlog` | `todo`, `in_progress`, `cancelled` |
| `todo` | `backlog`, `in_progress`, `cancelled` |
| `in_progress` | `backlog`, `todo`, `in_review`, `done`, `cancelled` |
| `in_review` | `in_progress`, `done`, `cancelled` |
| `done` | `in_progress` (reopen) — nothing else |
| `cancelled` | `backlog` — nothing else |

Consequences worth internalizing: you **cannot** jump `backlog`/`todo` → `in_review` or → `done`. Everything reaches review or done **through `in_progress`**. So if you did the work without ever marking it started, you cannot close the task in one call — set `in_progress` first, then `done`. Marking `in_progress` up front is not paperwork; it is the only path to a closable task.

`resolve_tasks_for_spec` is the one exception: it bypasses the matrix to force every task linked to an archived change to `done` (a system transition, idempotent, terminal tasks skipped). It is for the sdd-verify/sdd-archive flow — do not reach for it to dodge a transition you should have made yourself.

## Decomposition (parent_id)

Work that spans multiple PRs gets a **parent task plus one subtask per PR**, not one vague epic and not a flat pile of unrelated tasks:

1. Create the parent (verb + what, describing the whole change; link the spec here).
2. Create each subtask with `parent_id` = parent id. Subtasks carry their own labels, assignee, and status — a subtask is a real task, treat it like one.
3. Advance subtasks as their PRs land. Move the parent to `done` only when every subtask is `done` or `cancelled`.

One PR of work = one task. Do not decompose a single PR into subtasks.

## Deletion (refusal rule)

**Never call `delete_task` on your own initiative.** The USER must explicitly ask for the deletion. The tool requires `confirm: true` and refuses without it — that guard is a backstop, not permission. Work that turned out to be unnecessary is `cancelled`, not deleted: cancellation preserves the record that it was considered.

## Gotchas

- **`create_task` takes no labels, no assignees, no status.** This is the single most common way agents file a broken task. Budget the follow-up calls.
- **There is no `remove_task_label` MCP tool.** `add_task_label` is idempotent (adding twice is a no-op), but a wrong label can only be removed from the admin UI. Think before you label.
- **`add_task_label` adds one label per call.** Two labels = two calls.
- **`list_tasks` / `list_my_tasks` do not hydrate labels or assignees** — the list endpoint returns them empty to avoid N+1 queries. Never conclude "this task has no labels" from a list; call `get_task` for the truth. (Filtering by `label` in `list_tasks` still works — that filter runs server-side.)
- **An illegal status transition is a `422 invalid_transition`** — the write is rejected outright, not clamped. Check the matrix above rather than retrying.
- **`list_my_tasks` never takes a user id** — "me" is resolved server-side from the API key. To see someone else's tasks, use `list_tasks(assignee: <user_id>)`.
- **Every tool is permission-gated** (`task:read` / `task:write` / `task:assign` / `task:delete` / `task:manage`). A denied call is an error, not a silent no-op — read it and tell the user, don't retry blindly.
- **`generate_daily_standup` reads memories, not tasks.** It summarizes yesterday's stored memories; it will not tell you the state of the board. Use `list_tasks` / `list_my_tasks` for that.
- **Tasks are not memories.** File the *work* as a task; save the *knowledge* (decision, root cause, convention) with `store_memory`. A bug fix usually deserves both.
