# Codex transport implementation status

The installed CLI reports `codex-cli 0.167.0`. The initial transport was checked against that version's generated JSON schemas, produced with:

```sh
codex app-server generate-json-schema --out /tmp/task-manager-codex-schema
```

The generated bundle is not checked into this repository. Relevant schemas are `v1/InitializeParams.json`, `v1/InitializeResponse.json`, `CommandExecutionRequestApprovalResponse.json`, and `PermissionsRequestApprovalResponse.json`. The public reference is the [official App Server documentation](https://learn.chatgpt.com/docs/app-server).

Implemented:

- Owned `codex app-server --listen stdio://` subprocess and JSONL framing.
- Stable initialization capabilities; experimental API opt-in is disabled.
- Integer client request IDs, string/integer server request IDs, and out-of-order response correlation.
- Streamed notifications, request timeout/cancellation, and waiter release on disconnect.
- Concurrent stdout/stderr draining, bounded incoming frames and queues, and nonblocking serialized stdin writes.
- Command/file approvals return `cancel`; permission requests grant no additional permissions. Other server requests receive an unsupported-method error. No request silently approves an action.
- Explicit stop terminates the owned process, with a delayed forced termination fallback.
- Persisted thread start/resume, turn start/interrupt, and in-flight steering through the coordinator.
- Structured final outcomes: a child can complete or ask a question and yield. Answer delivery resumes the saved thread.
- Persistent transcripts and inbox acknowledgments after runtime acceptance; deferred delivery when a turn ends before steering is accepted.

Test coverage uses short-lived shell fixtures, including more stderr output than a pipe can hold, fragmented JSON, out-of-order responses, malformed/oversized frames, blocked stdin, timeouts, cancellation, disconnect, and incoming approval requests. Fixtures perform no real remote actions.

Execution policy and remaining work:

- The current worker policy explicitly uses `sandbox = danger-full-access` and `approvalPolicy = never`, following the user's preference. Worker instructions prohibit external mutations; this policy does not enforce that prohibition at the OS boundary.
- A dedicated credential-isolated or mediated mode can be added if a hard external-action boundary is required.
- Questions currently use structured final outcomes and fresh turns, rather than holding a live server-side tool request open. Unsupported server-side interaction requests are still declined.
- Supervision and termination of a worker's entire subprocess tree, rather than only the directly owned app-server.

The generic transport request API is an internal building block, not an authorization policy. Timing out a request abandons the local waiter; it does not prove the remote operation was cancelled. The coordinator interrupts turns on pause/cancel, and cold recovery pauses tasks rather than automatically replaying uncertain effects.

The live initialization handshake passed on 2026-11-07 after the user restarted this development session with full access. The server identified itself as `autonomous_task_manager/0.167.0`, platform `macos`, and reported the expected Codex home. Earlier restricted-session probes failed because the runtime could not initialize its SQLite state under that home; that development-session blocker is resolved.

Subsequent live validation created a child through the TUI in a worktree of the todo-list test repo. While its shell command `sleep 20` was active, a TUI follow-up was accepted by `turn/steer`. That follow-up changed the task outcome to a question. Answering through the TUI resumed the same saved thread and completed the task with an empty inbox. The child performed only read operations and changed no files. Evidence is retained in `.state/ui-live/`, including `RESULTS.txt`, the journal, transcript, and session IDs.
