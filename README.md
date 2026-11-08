# task-manager

A local autonomous task manager, implemented in Swift. See [SPEC.md](SPEC.md) and [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) for the intended system.

The current implementation supports manually driven child workers through a TUI: create tasks, watch progress, send messages during a turn, answer questions, and pause/resume work. A background coordinator owns the workers and durable SQLite state. Tasks can use a mock worker or real Codex in an isolated git worktree. GitHub reads are available separately; automatic source polling and master-agent triage are still to come.

## Build and verify

Requires macOS 14 or later and Swift 6.2 or later. Tested with Swift 6.2.4 and Codex CLI 0.167.0. There are no third-party package dependencies; SQLite and ncurses are linked from the system SDK.

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

## Try the TUI first

From this repository, launch with the todo-list checkout as the repository for new tasks:

```sh
.build/debug/task-manager --state-dir .state/dev tui \
  /Users/shyamkumar/Developer/todo_list_task_manager_test
```

The TUI starts or attaches to a coordinator for that state directory. It opens in **CODEX** mode: new tasks execute with real Codex workers in isolated worktrees. Press Tab to explicitly select **MOCK** for simulated progress, follow-ups, and questions without model calls or file changes. Switching modes affects new tasks only; existing mock tasks remain mock tasks.

| Key | Action |
| --- | --- |
| `n` | Enter a goal and create a task |
| `m` | Send a follow-up to the selected child |
| `a` | Answer the selected child's pending question |
| `p` | Pause or resume the selected child |
| `r` | Retry/continue a completed, failed, or paused task |
| `x` | Cancel the selected task, preserving its local work |
| `Tab` | Switch new tasks between MOCK and CODEX |
| Up/Down or `j`/`k` | Select a task |
| PageUp/PageDown | Scroll its conversation |
| `q` or Ctrl-C | Detach the UI; workers continue |

In an input form, Enter sends, Ctrl-N inserts a newline, and Esc cancels. Resize is handled by ncurses; the minimum layout is 76 columns by 16 rows. Transcript controls are stripped before rendering.

To start a **real child**, press `n` with CODEX shown in the header. Try this goal:

> Read SPEC.md without changing files, then ask me which command name the todo CLI should use.

Answer with `a`; it resumes the same saved Codex thread. To test in-flight updates, start a task that takes some time (for example, ask it to run `sleep 20` before inspecting the spec), then send an instruction with `m`. Messages show QUEUED until Codex accepts `turn/steer`, then ACCEPTED. A message that loses the race with turn completion remains queued for the next turn.

Real coding tasks get branches named `task-manager/TASK_ID` and worktrees under the state directory's `worktrees/`. The user's original checkout and uncommitted changes are preserved; work starts from committed HEAD. Use `show TASK_ID` to see the full workspace path and thread ID, and inspect that worktree with git as needed. Completed worktrees are retained.

The coordinator runs up to two workers at once. Waiting for a question releases the worker slot. Closing the UI keeps the coordinator alive; reopen the same command to reattach. To stop it deliberately:

```sh
.build/debug/task-manager --state-dir .state/dev coordinator-stop
```

Stopping pauses active work. After a coordinator crash, previously running tasks reopen **paused** for inspection; press `p` to resume using their saved workspace, thread, transcript, and inbox. The UI and coordinator currently coordinate through SQLite, avoiding an additional socket protocol for this prototype.

Codex workers use full access and no runtime approval prompts, as requested. They are instructed to work locally and not publish or mutate external systems. That instruction is not a sandbox-enforced guarantee. The application's external action executor remains disabled.

For scripts or a separate terminal, `serve` runs the coordinator in the foreground, `agent-add mock|codex REPO GOAL` queues a task, and `transcript TASK_ID` prints saved output. These use the same state and workers as the UI.

## Core CLI walkthrough

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

The `add` command above creates an unbound task for exercising storage/routing; it does not launch an agent. Use the TUI or `agent-add` to create worker-bound tasks. An answer creates a durable inbox message and requeues only the affected task. Answering while paused preserves the pause. `resume TASK_ID` restores a pending question when necessary. Cancelled tasks retain history and reject new messages and approvals.

## GitHub reads

The adapter uses GitHub CLI (`gh`) for GitHub.com reads and authentication. Install `gh` and authenticate with `gh auth login` if you have not already done so. List your open PRs with:

```sh
.build/debug/task-manager --state-dir .state github-prs OWNER/REPO YOUR_LOGIN
```

To import all current discussion, inline comments, and submitted review bodies for an explicitly selected PR:

```sh
.build/debug/task-manager --state-dir .state github-import OWNER/REPO PR_NUMBER
```

Authentication stays in `gh`, which uses your saved login or its supported token environment variables (`GH_TOKEN`/`GITHUB_TOKEN`). The application invokes `gh api --hostname github.com --method GET --include` directly, without a shell or credentials in command arguments. It reads pagination headers and fetches bounded pages rather than delegating unlimited pagination to `gh`. A failed batch is not partially ingested. Rate-limit errors report retry metadata; automatic retry/backoff is not implemented yet. Process timeout/cancellation and bounded stdout prevent hung or oversized responses from stalling the caller; stderr is drained without being persisted.

Repeated imports deduplicate identical revisions. Established task source associations route automatically. Unknown associations remain pending for future master triage. This manual command imports history; automatic first-run baselining and continuous polling are still to come.

The test checkout is `/Users/shyamkumar/Developer/todo_list_task_manager_test`, with remote `shyamkumar703/todo_list_test_task_manager`. Real Codex tasks modify their own worktrees; the mock/fixture tests do not modify application code.

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
