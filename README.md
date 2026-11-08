# task-manager

A local autonomous task manager, implemented in Swift. See [SPEC.md](SPEC.md) and [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) for the intended system.

The current implementation supports child workers and source-message triage through a TUI: create tasks, watch progress, send messages during a turn, inject incoming source messages, answer questions, and pause/resume work. A real Codex master decides whether incoming messages affect existing tasks, require new work, need clarification, or can be ignored. A background coordinator owns workers and durable SQLite state. Tasks can use a mock worker or real Codex in an isolated git worktree. The coordinator automatically polls configured GitHub repositories for feedback on your open PRs.

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
| `t` | Open an interactive shell in the selected child's worktree |
| `d` | Remove the selected task from the list, retaining its history |
| `s` | Inject a mock source message for real master triage |
| `e` | Switch between tasks and incoming source events |
| `Tab` | Switch new tasks between MOCK and CODEX |
| Up/Down or `j`/`k` | Select a task |
| PageUp/PageDown | Scroll its conversation |
| `q` or Ctrl-C | Detach the UI; workers continue |

In an input form, Enter sends, Ctrl-N inserts a newline, and Esc cancels. Resize is handled by ncurses; the minimum layout is 76 columns by 16 rows. Transcript controls are stripped before rendering.

To start a **real child**, press `n` with CODEX shown in the header. Try this goal:

> Read SPEC.md without changing files, then ask me which command name the todo CLI should use.

Answer with `a`; it resumes the same saved Codex thread. To test in-flight updates, start a task that takes some time (for example, ask it to run `sleep 20` before inspecting the spec), then send an instruction with `m`. Messages show QUEUED until Codex accepts `turn/steer`, then ACCEPTED. A message that loses the race with turn completion remains queued for the next turn.

Real coding tasks get branches named `task-manager/TASK_ID` and worktrees under the state directory's `worktrees/`. The user's original checkout and uncommitted changes are preserved; work starts from committed HEAD. Use `show TASK_ID` to see the full workspace path and thread ID, and inspect that worktree with git as needed. Completed worktrees are retained.

Press `t` to use that worktree directly. An active worker pauses and releases ownership before your configured interactive shell opens in the existing terminal. Run `git status`, commit, or push manually there. `exit` returns to the TUI; press `p` if you want a paused child to continue. The terminal also shows the command to resume its saved Codex conversation interactively. Mock tasks have no worktree terminal.

The shell exports `TASK_MANAGER_TASK_ID`, `TASK_MANAGER_WORKTREE`, and `TASK_MANAGER_CODEX_THREAD_ID`. Its durable manual-ownership reservation prevents a coordinator from restarting the worker while the shell is open, even if another UI queues it. After a crashed shell, close any remaining manual session before clearing the reservation with `release-terminal TASK_ID`.

Press `d` to archive a task. Unlike cancellation, this removes it from the task list and attention count across restarts. Active work is paused; its database record, conversation, pending questions, branch, and worktree remain. Incoming feedback cannot reactivate an archived task. Use these CLI commands to inspect or restore it:

```sh
.build/debug/task-manager --state-dir .state/dev list --all
.build/debug/task-manager --state-dir .state/dev restore TASK_ID
```

Restoring returns it to the list without starting a worker. Previously active tasks remain paused; completed/cancelled tasks retain their status. `archive TASK_ID` and `terminal TASK_ID` provide the same actions from the CLI.

The coordinator runs up to two workers at once. Waiting for a question releases the worker slot. Closing the UI keeps the coordinator alive; reopen the same command to reattach. To stop it deliberately:

```sh
.build/debug/task-manager --state-dir .state/dev coordinator-stop
```

Stopping pauses active work. After a coordinator crash, previously running tasks reopen **paused** for inspection; press `p` to resume using their saved workspace, thread, transcript, and inbox. The UI and coordinator currently coordinate through SQLite, avoiding an additional socket protocol for this prototype.

After rebuilding, reopen the TUI to load new controls. It gracefully replaces older coordinators that do not support workspace ownership; any active tasks are paused and retained during that upgrade.

Codex workers use full access and no runtime approval prompts, as requested. They are instructed to work locally and not publish or mutate external systems. That instruction is not a sandbox-enforced guarantee. The application's external action executor remains disabled.

For scripts or a separate terminal, `serve` runs the coordinator in the foreground, `agent-add mock|codex REPO GOAL` queues a task, and `transcript TASK_ID` prints saved output. These use the same state and workers as the UI.

## Try source-driven routing

Create or resume a child, then press **`s`** and enter an incoming message. This is a mocked data source, not a direct message to the selected child. The real Codex master compares the message with task goals and recent conversation in the repository passed to `tui`; UI selection does not determine the destination.

For example, with a task investigating todo title validation, inject:

> Product update: whitespace-only titles must print "title is required" rather than creating an item. This also applies to tabs and newlines.

The master can route the update to an existing child, create a distinct task, ignore unrelated chatter, or ask a clarification question. Relevant findings and decisions can be routed even if they contain no direct request. Routing to a running Codex child uses the existing `turn/steer` path; paused/waiting tasks retain their state and keep the update in their inbox. Completed tasks can be continued. An existing destination keeps its runtime; the header's runtime selection applies only when the master creates a new task.

The incoming-events view shows the source text, decision, reason, destination, actual child runtime, and QUEUED/ACCEPTED delivery status. Press:

- **`e`** to inspect incoming events or return to tasks.
- **Enter** on a routed/created event to open its child.
- **`u`** on an ignored event to send the original message back through master triage, including initial baseline history. Existing user clarifications are preserved; reconsideration does not force a particular routing decision.
- **`a`** on a waiting event to answer the master's question; the original message and clarification are reconsidered together.
- **`r`** to retry failed triage.
- **`x`** to ignore an unapplied event. Already-delivered messages cannot be unsent.

Master clarification does not block other events or child workers. Decisions, learned source-thread links, task creation, and inbox messages persist transactionally. Duplicate source ID/revision pairs cannot create duplicate work. Messages targeting child workers always use the master, including known source-thread associations. Detected conflicts with current instructions or the stated approach become persistent user questions; the source update stays out of the child inbox until resolved. In the incoming view, press `a` to answer. Accepted changes are reconsidered with the user resolution; rejected changes can be ignored. The child continues its existing work while the question waits. Archived/cancelled associations require clarification before separate work can be created. Model failures back off for up to three attempts and remain visible for manual retry.

The master always uses Codex, even when new child tasks are configured as MOCK. It uses a read-only classification session with shell/apps/web search disabled and returns schema-validated decisions. It does not implement the work itself. The context currently includes up to 64 eligible tasks in the source repository and bounded recent conversation; unclear relevance should result in clarification. Live Slack/GitHub polling is not enabled by this input form.

CLI equivalents, with a coordinator running for the same state directory:

```sh
.build/debug/task-manager --state-dir .state/dev source-inject codex \
  /Users/shyamkumar/Developer/todo_list_task_manager_test \
  'Product update: reject whitespace-only todo titles.'
.build/debug/task-manager --state-dir .state/dev source-events
.build/debug/task-manager --state-dir .state/dev source-answer EVENT_ID 'The add command.'
```

`source-inject` optionally accepts an association key after the text to simulate repeated events in the same source thread. Future adapters can register normalized events with `Store.ingest(..., repository: ..., workerKind: ...)` to use this same triage pipeline. Legacy unscoped imports retain explicit-association routing but do not trigger model-based work creation without a configured local repository.

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

Authentication stays in `gh`, which uses your saved login or its supported token environment variables (`GH_TOKEN`/`GITHUB_TOKEN`). The application invokes `gh api --hostname github.com --method GET --include` directly, without a shell or credentials in command arguments. It reads pagination headers and fetches bounded pages rather than delegating unlimited pagination to `gh`. A failed batch is not partially ingested. Repository polling persists failures and retries with exponential backoff, honoring numeric Retry-After and rate-limit reset headers. Process timeout/cancellation and bounded stdout prevent hung or oversized responses from stalling the caller; stderr is drained without being persisted.

Repeated imports deduplicate identical revisions. Established associations to bound child workers are reviewed by the master before delivery; legacy tasks without workers retain explicit-association routing. Unknown associations remain pending for future master triage. This manual command imports history; use repository polling below for automatic discovery and first-run baselining.

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

### Durable GitHub polling cursor

Poll one PR using the same state directory as the TUI:

```sh
.build/debug/task-manager --state-dir .state/dev github-poll OWNER/REPO PR /absolute/path/to/local/repository
```

The first successful poll baselines existing issue comments, inline comments, and reviews as ignored history, without creating work. Subsequent calls queue new or edited feedback for the existing master triage pipeline. Already imported events retain their prior state. Run the coordinator/TUI to process queued feedback.

SQLite saves the cursor generation and all fetched events together. Failed fetches, incomplete pagination, and failed transactions leave the cursor unchanged. Restarting with the same state directory resumes from persisted history; repeated revisions cannot duplicate work. Concurrent stale polls must fetch again. Each PR is bound to one local repository and worker kind per state directory.

Each poll re-fetches the complete PR feedback snapshot and uses revision hashes to detect changes, including edited reviews whose submission timestamp stays unchanged. The cursor records successful generations rather than an API `since` timestamp. `github-poll` runs once; the repository scheduler below runs automatically. `github-import` remains a separate manual history import.

### Automatic repository polling

Open the TUI and press **`g`**, then **`n`** to discover repositories using your existing `gh` authentication. Setup detects your GitHub login, reads the current checkout’s `origin`, and places that repository first in the list. Use **↑↓** to select, **`/`** to filter by repository name (**`c`** clears), and **Enter** to enable polling. The current checkout needs no additional input; other repositories ask only for a local checkout path whose origin matches the selection. Polling defaults to 60 seconds. No new login is needed if `gh` is already authenticated; authentication errors point to `gh auth status`.

Repeat to add other accessible repositories. Archived/disabled repositories are omitted from the discovered account list. Press **`Esc`** to leave the picker, **`r`** to refresh, **`p`** to enable/disable a configured repository, or **`i`** to change its interval (10–86400 seconds). Configuration and health persist in SQLite. The repository view shows last success, next poll, and errors; **`e`** opens incoming events and **`g`** returns to tasks.

The persistent coordinator discovers your open PRs in each enabled repository and reads their conversation comments, inline comments, and reviews. Polling continues after **`q`** detaches the TUI. Stopping the coordinator stops polling; restarting resumes using saved intervals, baselines, and event revisions. Network fetches run separately from child workers and master triage, with at most two repository polls in flight. Failures in one repository do not stop the others. Failed repository polls preserve successful per-PR commits and retry with saved backoff.

The initial successful repository scan records existing feedback without starting historical work. After that scan, new/edited feedback—including feedback on newly discovered PRs—enters normal triage. Every newly seen PR is baselined while the repository's first scan remains incomplete. Closed/merged PRs are outside the initial discovery scope. Polling uses read-only GitHub requests; publishing remains a separate approval-controlled action.

Equivalent CLI configuration, using the same state directory as the TUI:

```sh
.build/debug/task-manager --state-dir .state/dev github-discover /absolute/path/to/local/repository
.build/debug/task-manager --state-dir .state/dev github-watch /absolute/path/to/local/repository
.build/debug/task-manager --state-dir .state/dev github-sources
.build/debug/task-manager --state-dir .state/dev github-disable SOURCE_ID
.build/debug/task-manager --state-dir .state/dev github-enable SOURCE_ID
```

The coordinator must be running (`tui` starts it, or use `serve`). Each remote repository has one configuration per state directory. Polling is independent of the new-task MOCK/CODEX toggle; automatically created source tasks use Codex.

`github-watch LOCAL_REPO [SECONDS]` detects the authenticated account and checkout origin. The older explicit `github-watch OWNER/REPO LOCAL_REPO AUTHOR SECONDS` form remains available for advanced configuration. Discovery never clones repositories or enables monitoring until you select one.

Ignored source events can also be reconsidered with `task-manager --state-dir PATH source-unignore EVENT_ID`. The original event is requeued in place; its prior decision remains in the journal. New initial-baseline events display an explicit baseline reason in the incoming view.

### Slack authorization setup

Run `task-manager --state-dir PATH slack-connect` to open a native macOS secure token dialog. Paste the Slack **User OAuth Token** (`xoxp-`); the command checks the authenticated workspace/user with Slack and saves the credential in macOS Keychain. Tokens are not accepted as command arguments or saved in SQLite, JSON, or logs. Only workspace/user metadata is written to `slack-connections.json` in the state directory. The persistent coordinator automatically discovers and monitors all accessible conversations after connecting.

### Automatic Slack polling

Connected Slack workspaces are monitored automatically by the persistent coordinator. No channel selection or project-path setup is required. It discovers every accessible, non-archived conversation returned by Slack—public channels (including channels you have not joined), private channels, DMs, and group DMs—and repeats discovery every minute to enroll newly available conversations. Access is limited by your authorized Slack user token and workspace policies. Start the TUI or run `coordinator-start`; a newly saved `slack-connect` connection is picked up automatically while the coordinator is running.

Press **`l`** to inspect discovery and polling health. Polling defaults to 60 seconds per conversation. **`p`** pauses/resumes a conversation and **`i`** changes its interval; these overrides survive rediscovery and restarts. These controls are optional. **`e`** opens incoming messages and routing decisions. Polling continues after **`q`** detaches the TUI.

Automatically discovered conversations are not assigned to the TUI's current checkout. The master compares incoming messages with tasks across known local projects and follows learned thread associations. Relevant updates reach existing children, and instruction/approach conflicts become questions. For new work, it may choose a known project when clearly identified; unclear projects become user questions. You can answer with an absolute checkout path to register a project. Merely opening a TUI in a checkout does not authorize assigning all Slack messages to that checkout. Existing manually configured project bindings remain supported.

The first successful scan of each conversation records existing history as ignored baseline entries with a reason. Subsequent human messages, edits, and thread replies enter triage, including messages without explicit mentions. Bot messages and empty/system messages are skipped. Baseline entries can be reconsidered with **`u`**. Polling reads complete bounded conversation/thread snapshots, with up to 100 pages per endpoint and 200 threaded roots per conversation, so edits and replies to old roots are detected. Checkpoint generations, revisions, events, and successful schedules commit atomically. Incomplete snapshots leave checkpoints unchanged; histories beyond safety limits produce a visible error. Message deletions and attachments without text are not processed in this version.

Discovery and polling have persistent retry schedules. Up to two workspaces progress independently, with one request batch in flight per workspace. HTTP 429 Retry-After delays discovery and conversations in that workspace. Credentials stay in Keychain, and the adapter only calls Slack read endpoints; it does not post messages or modify conversations.

Slack needs the appropriate **User Token Scopes** for listing and reading conversations: `channels:read`/`channels:history`, `groups:read`/`groups:history`, `im:read`/`im:history`, and `mpim:read`/`mpim:history`. If history returns `missing_scope`, verify the history scopes under User Token Scopes, reinstall the app, and reconnect if required. DM labels fall back to user IDs because user-profile permissions are not required.

Diagnostics and optional controls:

```sh
.build/debug/task-manager --state-dir .state/dev coordinator-start
.build/debug/task-manager --state-dir .state/dev slack-sources
.build/debug/task-manager --state-dir .state/dev slack-conversations
.build/debug/task-manager --state-dir .state/dev slack-disable SOURCE_ID
.build/debug/task-manager --state-dir .state/dev slack-enable SOURCE_ID
```

`slack-poll SOURCE_ID` performs one complete diagnostic poll. The older `slack-watch` command remains available for explicit conversation/project bindings but is not needed for automatic monitoring. Slack connection metadata (`slack-connections.json`) and source/checkpoint state (SQLite) must use the same state directory. Keychain entries must remain available when restoring application state.

### Exploratory questions and replies ready for review

Information-seeking source questions (for example, “what commands are available right now?”) use an independent **exploration** task. A related implementation task can identify the project, but its branch/worktree is not reused or resumed. Implementation follow-ups still go through ordinary routing and conflict review. If the project is unclear, the master asks first.

An explorer receives a detached snapshot of the locally available default branch, with its reference and exact commit saved in SQLite. It resolves the remote default-branch name when available, preferring the corresponding local branch; otherwise it looks for local/cached `main` or `master`. It never falls back to the currently checked-out feature branch. The snapshot is pinned across retries. There is no automatic fetch: findings describe that recorded local snapshot, not necessarily the newest remote, deployed or released version. Explorers use the app-server’s read-only sandbox, with apps and web search disabled, and instructions to inspect without implementing or publishing. See the [official app-server documentation](https://learn.chatgpt.com/docs/app-server).

When an explorer finishes, its findings and suggested reply become a durable **user action** in the same transaction as completion. The TUI header shows an action count and the child shows “reply ready.” Press **`v`** for user actions, **`c`** to copy the suggested reply, **`Enter`** to inspect the child, or **`e`** for the source. Review and paste the response into the source thread manually; **`d`** marks it done and **`x`** dismisses it. Neither operation sends anything. Evidence and the inspected branch/commit are visible above the suggested reply (PgUp/PgDn scroll). Actions survive TUI detachment and coordinator restarts.

For a question that was previously routed to the wrong feature worker, select the source in **`e`** and press **`i`** to request an independent investigation. Existing feature messages and decisions remain in history; repeated requests reuse the already-created exploration. CLI equivalents:

```sh
.build/debug/task-manager --state-dir .state/dev source-investigate EVENT_ID
.build/debug/task-manager --state-dir .state/dev actions
.build/debug/task-manager --state-dir .state/dev action-done ACTION_ID
.build/debug/task-manager --state-dir .state/dev action-dismiss ACTION_ID
```

Relaunch the TUI after this upgrade to use the new actions view. The coordinator can be updated separately with `coordinator-start`.

### Slack context for project routing

Before asking which project a message concerns, the master now uses the channel name, topic and purpose, up to eight preceding channel messages, up to twelve earlier messages in the same thread (including its root), and up to four earlier project decisions from that conversation. Previous user clarifications help interpret short follow-ups without repeatedly asking for the project name. These are contextual clues, not permanent channel bindings: an explicit project change takes precedence, and genuinely conflicting or insufficient evidence still produces a focused question.

Metadata and raw message history are saved during existing discovery/poll batches, without additional Slack requests or permissions. Message text/revisions are unchanged by topic/name refreshes, so context updates do not duplicate tasks. Context is limited to the same workspace/conversation, excludes messages later than the incoming message, and truncates individual snippets. A snapshot is saved with each triage attempt for restart recovery and review; the incoming view shows its channel/topic and context counts. Child workers receive the same background context, labeled as source data rather than authority to change instructions or publish.

Older unanswered project questions that had no context snapshot are reconsidered once after discovery refreshes metadata. Questions already asked with the expanded context stay waiting for the user. Existing baselined event history provides context during upgrade until the next successful poll fills the raw-message cache. Channel metadata comes from Slack’s [conversation listing](https://docs.slack.dev/reference/methods/conversations.list/).
