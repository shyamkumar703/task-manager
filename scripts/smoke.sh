#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
binary="$PWD/.build/debug/task-manager"
if [ ! -x "$binary" ]; then
    echo "Run ./scripts/test.sh first." >&2
    exit 1
fi
scratch=$(mktemp -d "${TMPDIR:-/tmp}/task-manager-smoke.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
tm() { "$binary" --state-dir "$scratch/state" "$@"; }

tm init
tm add 'Address PR feedback' 'github:shyamkumar703/todo_list_test_task_manager:pr:1' > "$scratch/task.json"
task_id=$(/usr/bin/plutil -extract id raw -o - "$scratch/task.json")
[ "$(tm ingest fixtures/github-feedback.json)" = 'Inserted 2 events' ]
[ "$(tm ingest fixtures/github-feedback.json)" = 'Inserted 0 events' ]
[ "$(tm route)" = 'Routed 2; pending 0' ]
[ "$(tm route)" = 'Routed 0; pending 0' ]
tm status "$task_id" running
question_id=$(tm ask "$task_id" 'Should whitespace-only titles be rejected?')
# Every command is a fresh process opening the same on-disk state.
tm questions > "$scratch/questions.json"
[ "$(/usr/bin/plutil -extract 0.id raw -o - "$scratch/questions.json")" = "$question_id" ]
tm answer "$question_id" 'Yes, trim before validation.'
tm list > "$scratch/tasks.json"
[ "$(/usr/bin/plutil -extract 0.status raw -o - "$scratch/tasks.json")" = 'queued' ]
proposal_id=$(tm propose-comment "$task_id" 'https://github.com/shyamkumar703/todo_list_test_task_manager/pull/1' 'fixture-head-sha' 'Validated locally; awaiting review.')
tm decide "$proposal_id" approve
tm proposals > "$scratch/proposals.json"
[ "$(/usr/bin/plutil -extract 0.status raw -o - "$scratch/proposals.json")" = 'approved' ]
[ "$(/usr/bin/sqlite3 "$scratch/state/state.sqlite" 'PRAGMA integrity_check;')" = 'ok' ]
echo 'Smoke test passed: durable questions, deduplication, routing, and local approval decisions.'
