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

Test coverage uses short-lived shell fixtures, including more stderr output than a pipe can hold, fragmented JSON, out-of-order responses, malformed/oversized frames, blocked stdin, timeouts, cancellation, disconnect, and incoming approval requests. Fixtures perform no real remote actions.

Important boundaries still to implement:

- Dedicated worker configuration that cannot inherit authenticated tools or write credentials.
- Verified filesystem/network isolation for repository commands on the target laptop.
- Thread start/resume, persisted run ownership, turn execution, steering, and structured task outcomes.
- Durable user interactions connected to runtime requests.
- Supervision and termination of a worker's entire subprocess tree, rather than only the directly owned app-server.

The generic transport request API is an internal building block, not an authorization policy. Timing out a request abandons the local waiter; it does not prove the remote operation was cancelled. Future lifecycle code must reconcile side effects and interrupt turns explicitly.

The live handshake could not be validated in this restricted development session. The installed server exits before accepting requests with:

```text
failed to initialize sqlite state runtime under /Users/shyamkumar/.codex
```

That directory is read-only in the session. The failure is separate from protocol fixture validation. No agent thread or model request was started. Autonomous workers remain disabled until the runtime and isolation milestone is verified.
