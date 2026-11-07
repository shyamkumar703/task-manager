# task-manager

A local autonomous task manager, implemented in Swift. See [SPEC.md](SPEC.md) and [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) for the intended system.

The current implementation is the foundation: durable task state, questions and answers, incoming event deduplication and routing, local action proposals, a Codex stdio client, and a read-only GitHub adapter. Background scheduling, autonomous triage/workers, worktree management, and the TUI are not yet enabled. The CLI exercises the core while those components are built.

## Build and verify

Requires macOS 14 or later and Swift 6.2 or later. Tested with Swift 6.2.4. There are no third-party package dependencies; SQLite is linked from the system SDK.

```sh
./scripts/test.sh
./scripts/smoke.sh
.build/debug/task-manager help
```

The test script keeps caches in `.build` and disables only SwiftPM's build-time sandbox so it can run in a restricted development environment. This does not configure or disable a Codex worker sandbox.

The smoke test runs a sequence of fresh CLI processes against a temporary on-disk database. It checks event retries, question persistence, answer delivery, approval records, and SQLite integrity. Its feedback is synthetic; it never contacts GitHub or modifies the test repository.

To exercise the core from the actual test checkout, leaving an inspectable database and JSON reports there:

```sh
./scripts/test-repository.sh /Users/shyamkumar/Developer/todo_list_task_manager_test
```

Each run creates `.task-manager-state/run.XXXXXX/` in that checkout. `RESULTS.txt` records the checks and IDs; `state/state.sqlite` contains the persisted data. The fixture is synthetic, so this does not require a real PR or run an agent. Ignore `.task-manager-state/` in the test repository.

## Local walkthrough

Use `.state` for disposable development state. The default persistent location is `~/Library/Application Support/AutonomousTaskManager`; `TASK_MANAGER_STATE_DIR` or `--state-dir` overrides it.

```sh
.build/debug/task-manager --state-dir .state init
.build/debug/task-manager --state-dir .state add \
  'Investigate empty todo titles' \
  'github:shyamkumar703/todo_list_test_task_manager:pr:1'
.build/debug/task-manager --state-dir .state ingest fixtures/github-feedback.json
.build/debug/task-manager --state-dir .state route
.build/debug/task-manager --state-dir .state list
```

Copy the task ID from the JSON output:

```sh
.build/debug/task-manager --state-dir .state show TASK_ID
.build/debug/task-manager --state-dir .state status TASK_ID running
.build/debug/task-manager --state-dir .state ask TASK_ID 'Should whitespace-only titles be rejected?'
.build/debug/task-manager --state-dir .state questions
.build/debug/task-manager --state-dir .state answer QUESTION_ID 'Yes, trim before validation.'
.build/debug/task-manager --state-dir .state journal
```

Status changes here are manual state transitions; setting a task to `running` does not launch an agent. An answer creates a durable inbox message and requeues only the affected task. Answering while paused preserves the pause. `resume TASK_ID` restores a pending question when necessary. Cancelled tasks retain history and reject new messages and approvals.

## GitHub reads

The adapter supports GitHub.com. To import all current discussion, inline comments, and submitted review bodies for an explicitly selected PR:

```sh
.build/debug/task-manager --state-dir .state github-import OWNER/REPO PR_NUMBER
```

It uses `GITHUB_TOKEN` from the environment if present, otherwise unauthenticated reads. Supply credentials through your existing secret-management mechanism. Tokens and HTTP response bodies are not written to the journal. Requests are GET-only, redirects are refused, and pagination is bounded. A failed batch is not partially ingested. Rate-limit errors report retry metadata; automatic retry/backoff is not implemented yet.

Repeated imports deduplicate identical revisions. Established task source associations route automatically. Unknown associations remain pending for future master triage. This manual command imports history; automatic first-run baselining and continuous polling are still to come.

The test checkout is `/Users/shyamkumar/Developer/todo_list_task_manager_test`, with remote `shyamkumar703/todo_list_test_task_manager`. The task manager does not modify application code in that checkout in this release.

## Codex connection check

```sh
.build/debug/task-manager codex-probe
# Or supply the path to a particular Codex executable:
.build/debug/task-manager codex-probe /absolute/path/to/codex
```

This starts an app-server, performs the initialization handshake, prints the server's identity, and shuts it down. It does not create a thread, run a turn, or send a model request. Codex still requires access to its own state directory to start. See [docs/CODEX_TRANSPORT.md](docs/CODEX_TRANSPORT.md) for the compatibility and isolation status.

## Approval records

`propose-comment TASK_ID PR_URL HEAD TEXT`, `proposals`, and `decide PROPOSAL_ID approve|reject` exercise immutable proposal payloads and one-time decisions. These commands **never publish**: no external write executor exists yet. Approval records are not a substitute for runtime sandbox isolation, remote-head revalidation, or recovery of ambiguous external operations; those must be implemented before publication is enabled.

SQLite uses WAL, foreign keys, explicit migrations, and full synchronous durability. State and journal updates share transactions. For a consistent development backup while no process is using the database, copy the entire state directory including any WAL files. A supported online backup command will be added with the coordinator.
