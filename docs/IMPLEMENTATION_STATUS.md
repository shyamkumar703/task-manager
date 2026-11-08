# Implementation checkpoints

## 2026-11-07

Implemented the initial Swift package and three reviewable groups of work:

1. **Durable task core:** SQLite schema/migrations, actor-confined storage, task transitions, source associations, ordered inboxes, questions/answers, immutable action proposals, and transactional journal records.
2. **Codex transport:** stdio JSON-RPC client, initialization probe, asynchronous pipe IO, bounded output, response correlation, timeouts/cancellation, and rejection of server requests that could grant capabilities.
3. **GitHub read adapter and CLI:** bounded pagination for PR feedback, author filtering for open-PR discovery, normalization/revision hashing, explicit manual imports, deterministic association routing, synthetic fixture, and a fresh-process smoke test.

Initial validation: 18 Swift Testing tests and the offline CLI smoke test. During the original restricted session, the live Codex handshake was blocked by read-only access to the installed runtime's state directory. No live GitHub API call or external mutation was performed during that initial validation. See the full-access follow-up below for the resolved state.

The original restricted session could not create commits: Git initialization and later `.git/index.lock` writes were denied. The user subsequently restarted with full access; the foundation is now committed as `a6c54fd`. No Git metadata was relocated and nothing was pushed.

Next work, in dependency order:

1. Complete live Codex thread/turn lifecycle, recovery, and execution-policy validation. Startup and initialization are verified; agent execution is not yet implemented.
2. Prototype and select the Swift TUI framework, including focus, multiline input, streamed output, resize, and terminal restoration.
3. Add the independent coordinator process, single-owner lock, versioned local socket protocol, worker leases, persisted runs, crash reconciliation, and TUI attachment.
4. Add configured GitHub scopes, bootstrap baselines/cursors/backoff, bounded master triage, and worktree execution against the supplied test repository.
5. Connect questions and manual steering to workers, then implement approval-bound publication with remote-state checks and ambiguous-result recovery.

The implementation plan remains the acceptance checklist. These foundations do not complete its runtime, coordinator, TUI, or end-to-end workflow milestones.

## Test checkout validation

Ran `scripts/test-repository.sh /Users/shyamkumar/Developer/todo_list_task_manager_test` with the CLI working directory and SQLite state inside the supplied test checkout. Passed deduplication, association routing, durable questions, independent task state, paused-answer/resume behavior, duplicate-answer rejection, persistent message ordering/count, rejected local proposal, and SQLite integrity checks across fresh CLI processes.

Retained evidence at `/Users/shyamkumar/Developer/todo_list_task_manager_test/.task-manager-state/run.jAh6DE/`, including `RESULTS.txt`, JSON snapshots, and `state/state.sqlite`. Added an ignore entry for `.task-manager-state/` in the test checkout. Existing application files and the preexisting README deletion were preserved.

The fixture refers to a synthetic PR; no real PR existence is assumed. A read-only `gh pr list` attempt failed to connect to `api.github.com`, so live GitHub access was not verified. The checkout contains a project spec but no Swift application yet; no todo-list code or autonomous agent workflow was exercised.

## Full-access follow-up and gh integration

After the user restarted with full access, Git staging/committing, GitHub connectivity, and Codex initialization all succeeded. Committed the tested foundation as `a6c54fd`.

Replaced direct URLSession HTTP with `gh api`, reusing gh authentication. Added a finite subprocess runner with simultaneous stdout/stderr draining, bounded stdout, cancellation, and timeout. The transport explicitly selects GitHub.com and GET, preserves status/retry/pagination headers even on HTTP errors, and never passes credentials as command arguments. Added `github-prs OWNER/REPO AUTHOR` for live discovery checks.

Validation: 24 tests passed. The application's `github-prs shyamkumar703/todo_list_test_task_manager shyamkumar703` command successfully contacted GitHub and returned an empty list, consistent with `gh pr list`. No open PR exists to exercise real feedback ingestion. The live `codex-probe` handshake passed without creating an agent thread. Reran the repository-local persistence/routing smoke test successfully; retained evidence at `.task-manager-state/run.Pn8uwm/` in the test checkout. No remote changes were made.
