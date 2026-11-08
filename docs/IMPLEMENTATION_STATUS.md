# Implementation checkpoints

## 2026-11-07

Implemented the initial Swift package and three reviewable groups of work:

1. **Durable task core:** SQLite schema/migrations, actor-confined storage, task transitions, source associations, ordered inboxes, questions/answers, immutable action proposals, and transactional journal records.
2. **Codex transport:** stdio JSON-RPC client, initialization probe, asynchronous pipe IO, bounded output, response correlation, timeouts/cancellation, and rejection of server requests that could grant capabilities.
3. **GitHub read adapter and CLI:** bounded pagination for PR feedback, author filtering for open-PR discovery, normalization/revision hashing, explicit manual imports, deterministic association routing, synthetic fixture, and a fresh-process smoke test.

Initial validation: 18 Swift Testing tests and the offline CLI smoke test. During the original restricted session, the live Codex handshake was blocked by read-only access to the installed runtime's state directory. No live GitHub API call or external mutation was performed during that initial validation. See the full-access follow-up below for the resolved state.

The original restricted session could not create commits: Git initialization and later `.git/index.lock` writes were denied. The user subsequently restarted with full access; the foundation is now committed as `a6c54fd`. No Git metadata was relocated and nothing was pushed.

The implementation plan remains the acceptance checklist. The initial foundation preceded the manual UI/worker implementation described below.

## Test checkout validation

Ran `scripts/test-repository.sh /Users/shyamkumar/Developer/todo_list_task_manager_test` with the CLI working directory and SQLite state inside the supplied test checkout. Passed deduplication, association routing, durable questions, independent task state, paused-answer/resume behavior, duplicate-answer rejection, persistent message ordering/count, rejected local proposal, and SQLite integrity checks across fresh CLI processes.

Retained evidence at `/Users/shyamkumar/Developer/todo_list_task_manager_test/.task-manager-state/run.jAh6DE/`, including `RESULTS.txt`, JSON snapshots, and `state/state.sqlite`. Added an ignore entry for `.task-manager-state/` in the test checkout. Existing application files and the preexisting README deletion were preserved.

The fixture refers to a synthetic PR; no real PR existence is assumed. A read-only `gh pr list` attempt failed to connect to `api.github.com`, so live GitHub access was not verified. The checkout contains a project spec but no Swift application yet; no todo-list code or autonomous agent workflow was exercised.

## Full-access follow-up and gh integration

After the user restarted with full access, Git staging/committing, GitHub connectivity, and Codex initialization all succeeded. Committed the tested foundation as `a6c54fd`.

Replaced direct URLSession HTTP with `gh api`, reusing gh authentication. Added a finite subprocess runner with simultaneous stdout/stderr draining, bounded stdout, cancellation, and timeout. The transport explicitly selects GitHub.com and GET, preserves status/retry/pagination headers even on HTTP errors, and never passes credentials as command arguments. Added `github-prs OWNER/REPO AUTHOR` for live discovery checks.

Validation: 24 tests passed. The application's `github-prs shyamkumar703/todo_list_test_task_manager shyamkumar703` command successfully contacted GitHub and returned an empty list, consistent with `gh pr list`. No open PR exists to exercise real feedback ingestion. The live `codex-probe` handshake passed without creating an agent thread. Reran the repository-local persistence/routing smoke test successfully; retained evidence at `.task-manager-state/run.Pn8uwm/` in the test checkout. No remote changes were made.

## Manual UI and child workers

The user prioritized interaction testing before live PR/source workflows. Implemented a Swift/ncurses TUI with task creation, task selection, conversation output, message delivery badges, question answering, pause/resume, retry, cancellation, and runtime selection. The TUI starts/attaches a background coordinator and can detach while workers continue. SQLite is the local coordination boundary for this prototype; a socket protocol is deferred.

Mock workers exercise progress, follow-ups, and questions without model calls. Real Codex workers use isolated worktrees, persisted threads, structured question/completion outcomes, and in-flight `turn/steer`. Messages acknowledge only after runtime acceptance; a completion/steering race preserves the pending message for the next turn. Pause interrupts a turn; resume uses the saved thread. Cold coordinator recovery pauses interrupted tasks for inspection. Schema v2 adds sessions and transcripts and upgrades v1 databases without discarding task state.

Committed the first UI/runtime implementation as `32e5f6b`. Subsequent hardening checks worktree repository/branch ownership, pause/resume behavior, schema upgrades, and completion-before-response races.

Validation:

- **34 automated tests pass**, including coordinator ownership, transcript/session durability, peer progress while another worker waits, live-driver steering with a fake transport, deferred delivery races, mock pause/resume, Codex interruption and saved-thread resume, eager completion, schema migration, and worktree ownership/dirty-checkout preservation.
- **Real TUI/Codex test passed:** created a child from the UI against the todo-list test repo; sent a follow-up while its `sleep 20` command was running; saw it accepted; the child changed its outcome to a question; answered through the UI; the same thread resumed to completion with no pending messages. No child file changes or remote mutations occurred. Evidence: `.state/ui-live/RESULTS.txt` and its database.
- **TUI detachment passed:** detached while a mock worker was running; it continued to completion in the background.
- **Forced process crash passed:** killed a coordinator during a running mock task, saved a message while stopped, restarted, and verified the task reopened paused with the message still pending. Evidence: `.state/recovery-smoke/RESULTS.txt` and its database.
- Original offline smoke test and test-checkout smoke test pass. Latest checkout evidence: `.task-manager-state/run.syPsvU/`.

Remaining product work: user testing/refinement of the manual UI, automatic master triage, continuous source polling/baselines/backoff, structured external action proposals from workers, publication with explicit approval/reconciliation, online backup/log rotation, stronger subprocess-tree recovery, and optional launchd management. Full-access workers are instructed not to publish; that is not an OS-enforced barrier.

## Worktree terminals and task removal

Added `t` to pause/release a selected child and open an interactive shell in its worktree, returning to the TUI on `exit`. The shell has task/worktree/thread environment variables and displays the saved Codex resume command. Committing and pushing remain manual user actions. Foreground process-group transfer and terminal restoration were verified in a real PTY by running `pwd` and `git branch --show-current`, then exiting back to the TUI.

Added `d` to archive tasks and hide them across restarts. Archiving pauses active work and hides unanswered questions while retaining task state, transcripts, inbox, source history, worktree, and branch. Archived tasks reject mutations and source reactivation. `list --all`, `archive`, and `restore` support retained history; restore does not start work automatically.

Schema v3 adds archival timestamps and worker/manual workspace ownership. Worker startup claims execution atomically; releasing a runtime clears its ownership after stopping the connection. A manual terminal reservation excludes workers until the shell closes. CLI `terminal` and `release-terminal` support manual access and explicit stale-ownership recovery. Reopening a rebuilt TUI gracefully upgrades an incompatible coordinator before exposing ownership-dependent controls.

Validation: **40 tests pass**. Added coverage for archive persistence, retained history, archived-question filtering/restoration, source/approval/message guards, active-worker shutdown on archive, terminal handoff waiting, exclusive ownership, and timeout cleanup. Real PTY checks verified shell cwd/branch, return to TUI, immediate task removal, and retained `list --all` history. A compatibility-marker test verified graceful replacement of an older coordinator. Original smoke and repository-local smoke tests also pass. No pushes were performed.
