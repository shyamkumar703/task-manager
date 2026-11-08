# Autonomous task manager implementation plan

## Goal and agreed scope

Build a persistent application on the user's laptop that proactively identifies work, delegates it to Codex agents, and keeps the user informed through a TUI. Start with GitHub PR feedback; extend to Slack and Linear through adapters later.

Agreed decisions:

- Codex is the initial agent runtime.
- Durable state allows recovery after process failure, laptop restart, and sleep.
- The system may discover and start relevant local work without a direct assignment.
- Actions that change external systems require explicit user approval. Routine configured reads and Codex inference are allowed; publishing, messaging, and remote mutations are gated.
- Children finish with local results and verification evidence. They never push code automatically.
- The first interface is a TUI. A blocked child must not block ingestion, triage, or other children.
- GitHub PR feedback is the first complete workflow. The user will supply a test repository.

## Proposed stack

Use Swift with Swift Package Manager for the application, structured concurrency and actors for coordinator ownership, and SQLite on disk for state. Use separate package targets for domain types, persistence, Codex transport, integrations, coordinator, and TUI. Keep the domain model independent of the terminal library and agent transport. Use Codable types at protocol boundaries and explicit validation for domain invariants.

The initial TUI uses the system ncurses library through a small C wrapper, with Swift owning its state and task interactions. This keeps the prototype dependency-free and supports keyboard input, multiline composition, output scrolling, resize, and terminal restoration. A larger Swift view framework can be evaluated if the interface outgrows this implementation.

Swift-specific tradeoffs: expect more custom transport/integration code and terminal UI evaluation than with the original Python/Textual proposal. Drain subprocess stdout and stderr concurrently, bound output buffers, and explicitly terminate child processes on cancellation. Actors protect in-memory ownership but do not replace database transactions, durable queues, or crash recovery. Avoid holding a database transaction across an awaited network or agent operation. Keep database operations off UI rendering paths and persist state before broadcasting updates.

Integrate with the local `codex app-server` through a narrow JSON-RPC adapter over stdio. This gives the application control over lifecycle events and interaction requests without scraping terminal output. Verify and pin a compatible Codex version in the first milestone; generate or validate protocol types against that version.

The official [Codex App Server documentation](https://learn.chatgpt.com/docs/app-server) describes thread persistence/resume, turn execution, active-turn steering, and approval interactions. The adapter will encapsulate those capabilities; the application remains responsible for its own durable task state. Check the installed version before relying on particular protocol fields.

Use `gh` behind the GitHub integration interface, reusing its existing local authentication rather than implementing direct HTTP/token management. Invoke `gh api` with explicit host/method and parse its included response headers, retaining bounded pagination and normalized events in the adapter. Start with polling, avoiding an inbound webhook service on the laptop.

## Process architecture

```text
GitHub polling -> durable event inbox -> routing/master -> task inboxes
                         |                    |                |
                         +-------------- SQLite --------------+
                                              |                |
TUI <-> durable task state/inboxes/questions              scheduler
                                                               |
                                                       Codex workers
                                                               |
                                                       local worktrees
```

Run a background coordinator independently of the TUI. In the first implementation, the UI writes durable task state and inboxes directly through Store, and the coordinator watches them. A single-owner file lock prevents competing coordinators. Defer a versioned local socket protocol until needed. Closing the TUI detaches the interface; it does not stop work. Provide explicit commands for coordinator start, stop, and TUI attachment. Add optional macOS launchd installation after recovery works; installation is a user action.

The coordinator owns persistence and scheduling. The master is a Codex-backed decision maker invoked for bounded triage batches, with relevant task summaries and read-only source context. It returns schema-validated decisions: create task, append to task, ignore, or request clarification. Code validates and applies decisions transactionally. The master cannot directly spawn untracked processes or mutate external systems.

Route known PR/thread associations deterministically before calling the master. Record a reason for every decision, including ignored events. An ambiguous event can remain pending without blocking unrelated events.

## Durable model and recovery

Use SQLite migrations, WAL mode, foreign keys, and durability settings appropriate for committed state surviving a crash. SQLite is the source of truth; memory contains only rebuildable caches. Store larger transcripts/artifacts in an application state directory and reference them from the database.

Initial records:

| Record | Purpose |
| --- | --- |
| Integrations and cursors | Configuration identity, last successful ingestion position, backoff state |
| Source events | Original source IDs, revisions, links, payload, timestamps, deduplication key |
| Routing decisions | Disposition, task association, rationale, decision version |
| Tasks and associations | Goal, status, source PR/thread links, repository, parent relationship |
| Task messages | Durable inbox, sender, ordering, delivery attempts and acknowledgment |
| Agent runs | Task, Codex thread/turn IDs, runtime version, progress, outcome, lease |
| Workspaces | Repository, worktree path, local branch, base/head SHA, owning task |
| Questions and answers | Task, prompt, choices, response, delivery status |
| Action proposals | Exact external operation, payload, target, expected remote state, approval |
| Action attempts | Execution status, remote result, reconciliation information |
| Journal and artifacts | State transitions, errors, summaries, verification and diff references |

Keep state transitions and corresponding journal entries in the same transaction. Commit ingested pages before advancing their cursor. Use overlapping poll windows and source revision keys to handle retries and edited comments.

Task lifecycle: `queued -> running -> completed`, with `waiting_for_user`, `waiting_for_approval`, `paused`, `failed`, and `cancelled` states. Inbox arrivals can reopen completed work after routing. Track individual run attempts separately from task status. A completed investigation may have a pending optional publication proposal without keeping the worker occupied.

Recovery procedure:

1. Acquire a single-coordinator lock; reconcile expired worker leases and any surviving child processes before assigning ownership.
2. Validate recorded worktrees without deleting or resetting user changes.
3. Reopen interrupted work paused for inspection. On user resume, continue its saved Codex thread with outstanding inbox messages and persisted context. If resume fails, show the error and preserve the worktree/inbox; a future explicit thread-replacement operation can rebuild context from saved artifacts.
4. Reconcile uncertain external action attempts before retrying. Never blindly replay a push or posted comment.
5. Restore unanswered questions and approval proposals. Runtime-specific request IDs from a dead process are not reusable; recreate the interaction when necessary.
6. Catch up integrations with pagination and overlap, then resume scheduling within configured limits.

Delivery is at least once with deduplication. A process can die between sending input and recording acknowledgment; preserve message IDs in prompts and reconcile runtime history where possible. Do not claim exactly-once agent execution or remote mutations.

## Codex worker behavior

- Start a persisted thread in the assigned worktree and save its identifier before starting task execution.
- Stream progress to the coordinator without blocking its ingestion loop.
- Drain durable task messages between turns. Support manual active-turn steering where the pinned runtime supports it; handle turn-completion races by retaining undelivered input for the next turn.
- Expose structured task outcomes: progress/checkpoint, question, action proposal, completion, and failure. Validate these instead of inferring completion from conversational phrasing.
- When asking the user, save the question and yield. Other tasks continue. On an answer, resume the child with the original question and response.
- Require completion to include findings, changed files, verification commands/results, limitations, and relevant source links. A turn ending alone does not mean the task is finished.
- Enforce configurable worker concurrency, triage limits, execution time/turn budgets, and retry backoff. Surface exhausted budgets for user direction rather than looping indefinitely.
- Allow manual messages, pause, resume, cancel, and retry through the coordinator. Pause/cancel interrupts work and preserves the worktree.

## External actions and local execution boundaries

Implement a central action broker. A proposal contains the exact operation, destination, payload or diff, and remote preconditions. Approval is bound to that proposal revision; editing it or changing relevant remote state requires another approval. Rejection records the decision and informs the child.

The first release supports a proposed GitHub comment as the initial approved write operation. Push, merge, PR creation, issue mutation, Slack messages, and other writes remain unavailable until implemented through the same broker. An approved comment is sent by the coordinator, not by giving the child a write credential.

The user subsequently selected full-access Codex workers with runtime approvals disabled. The manual-worker prototype uses that policy and instructs children to work locally without publishing or mutating external systems. The application's publication executor remains unavailable. Full-access commands are not constrained by an OS-enforced external-action boundary; instruction compliance is required in this mode.

If a hard approval boundary becomes necessary, add a mediated/credential-isolated mode before claiming it is enforced. A git hook or forbidden-command list is insufficient. Treat repository code and incoming comments as untrusted inputs; they do not authorize publication or policy changes.

## GitHub first workflow

Configuration explicitly lists repositories to observe and their local checkout paths. Proactive discovery operates within that scope, initially on the user's open PRs and their discussion/review activity. Expanding to all repository work is configurable later.

Poll PR metadata, conversation comments, reviews, and inline review comments, including pagination and rate-limit handling. Bootstrap with a saved baseline and bounded recent context so first launch does not execute an entire historical backlog. Exclude the application's own published output from self-triggering loops.

For each actionable event:

1. Resolve repository, PR number, thread/comment identity, and current PR head SHA.
2. Append to an existing associated task when appropriate. Serialize work for a PR workspace; related independent investigations may use separate workspaces.
3. Otherwise let the master decide whether feedback warrants investigation or local changes, using PR context and the user's preferences. Keep the decision visible and reversible.
4. Create a worktree on a unique local branch from the observed PR head. Do not check out the same branch in multiple worktrees or alter the user's main checkout.
5. Have the worker investigate, make local changes if justified, and run relevant checks.
6. Show the result, diff, and verification in the TUI. Preserve the worktree for inspection. A suggested reply can be submitted as an approval proposal.

Revalidate the PR head before applying stale assumptions or publishing a reply. If it moved, fetch context and reconcile explicitly. Use task/workspace ownership locks to prevent concurrent edits. Never automatically delete completed worktrees containing results; cleanup is an explicit operation.

## TUI

Provide task list, task detail, and attention views with keyboard navigation:

- Task list: status, goal, repository/PR, recent activity, waiting reason.
- Task detail: progress, source links, messages, worktree location, diff and verification results.
- Attention inbox: persisted questions and exact action previews with answer/approve/reject controls.
- Activity view: ingestion health, routing decisions, ignored events, errors, retries, worker utilization.
- Controls: manually create a task, message a child, correct routing, pause/resume/cancel, inspect results, reconnect.

Show pending counts prominently. Never interpret closing a dialog, disconnecting, or timing out as approval. Store answers and decisions before acknowledging them in the interface. Reconnecting reconstructs views from persisted state; stream events carry sequence numbers so the TUI can catch up after gaps.

## Integration configuration

Use a validated TOML file with credential references, repository scopes and local paths, polling intervals, concurrency/budget settings, and prose triage instructions. Keep credentials out of config examples, prompts, and logs. Document default paths and how to back up SQLite consistently together with referenced artifacts and the Codex thread storage needed for full resume.

Adapters implement polling, normalization, context lookup, cursor handling, health reporting, and supported action proposal/execution methods. Adding an integration should not require changing the scheduler or task model. Defer a custom configuration language, marketplace, embeddings, distributed execution, and multi-user support.

## Delivery milestones and acceptance criteria

### 1. Runtime and terminal foundation

Scaffold the Swift package and verify the installed Codex protocol. Prototype the terminal interactions and select the terminal implementation. Demonstrate start, streamed progress, question handling, interruption, and saved-thread resume. Validate subprocess output handling and cancellation. Record Swift/macOS/Codex version requirements and the explicitly selected full-access execution policy. Keep automatic source-driven execution separate until the manual workflow works.

### 2. Durable coordinator

Implement schema/migrations, event inbox, journal, task state machine, task messages, persisted sessions/transcripts, and single-coordinator ownership. Use fake integrations and workers. Demonstrate recovery from a forced coordinator kill without losing committed events, thread/workspace identity, or pending questions. Interrupted tasks recover paused. Repeated input must not create duplicate tasks.

### 3. TUI and manual Codex tasks

Attach/detach the TUI, run a manually created task through the worker, answer a question, send follow-up information, pause/resume, and inspect completion. Verify two workers can progress while a third waits for input, within configured concurrency. Closing and reopening the TUI must preserve work.

The immediate product milestone is this manual UI loop, before live source testing. Support a mock worker alongside real Codex so interaction tests do not depend on a source integration or model calls.

### 4. Mock source triage, then live ingestion

First expose a mock incoming-source form in the TUI. The real master compares source content with scoped task goals and recent conversation, then routes, creates, ignores, or asks for clarification. Show decisions/reasons and downstream delivery status. Commit decisions, learned source associations, and task/inbox changes atomically. Verify relevance routing while an unrelated child is selected and the actual destination is running. Master questions must not block other events or workers.

Then connect live adapters with repository scope, source identity/revisions, bootstrap baselines, context lookup, and cursor/backoff handling. The GitHub read adapter already exists. In the test repo, feedback should produce one appropriate task without a direct assignment. A related follow-up updates it; irrelevant discussion is ignored with a recorded reason. Exercise pagination, edited events, overlapping polls, and transient/rate-limit failures using fixtures.

### 5. Worktree investigation and approval broker

Execute the complete PR-feedback workflow in an isolated worktree and display verified local results. Demonstrate stale-head handling and workspace serialization. Publish one exact proposed comment only after TUI approval. Verify rejection, payload changes, disconnects, and restarts cannot publish it accidentally; reconcile an ambiguous network result before retrying.

### 6. Laptop reliability and daily use

Exercise coordinator/worker crashes, a restart during an external operation, laptop sleep/wake, offline recovery, unavailable credentials, missing worktrees, and unavailable Codex threads. Add health reporting, log redaction/rotation, backup/restore instructions, graceful shutdown, and optional launchd setup. Document setup and the end-to-end test workflow.

Use targeted unit tests for state transitions and routing, adapter contract tests with recorded/synthetic fixtures, integration tests with temporary SQLite databases and git repositories, and a small live smoke test against the supplied GitHub repo. Fault injection should cover commit/acknowledgment boundaries, rather than relying only on happy-path demonstrations.

## Test repository handoff

Test repository supplied by the user:

- Local checkout: `/Users/shyamkumar/Developer/todo_list_task_manager_test`
- GitHub remote: `https://github.com/shyamkumar703/todo_list_test_task_manager.git`
- Observed local branch: `main`, tracking `origin/main`.
- Project specification: a todo list CLI written in Swift to exercise the task manager.
- Initial observation scope: this repository only. Confirm the authenticated GitHub identity during integration setup; repository ownership alone does not establish the current login.
- Initial inspection found a local deletion of `README.md`; preserve existing user changes.

Use a small program with a runnable test suite and one open PR. Seed review feedback that requires a code change, a related follow-up, an irrelevant comment, and a question requiring the user's answer. The user can create those remote fixtures manually; any application-created remote fixture requires approval.

The first release is complete when the application proactively handles that feedback, preserves and resumes work across a forced restart, accepts user steering through the TUI, produces a verified local diff, and performs no external mutation without explicit approval.
