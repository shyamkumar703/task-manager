#!/bin/sh
# Exercise the task core with cwd and persistent artifacts in a supplied checkout.
set -eu
project_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
binary="$project_root/.build/debug/task-manager"
if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
    echo 'Usage: scripts/test-repository.sh /absolute/path/to/test-checkout' >&2
    exit 1
fi
if [ ! -x "$binary" ]; then
    echo 'Run ./scripts/test.sh first.' >&2
    exit 1
fi
test_root=$(CDPATH= cd -- "$1" && pwd)
mkdir -p "$test_root/.task-manager-state"
run_root=$(mktemp -d "$test_root/.task-manager-state/run.XXXXXX")
cd "$test_root"
tm() { "$binary" --state-dir "$run_root/state" "$@"; }
extract() { /usr/bin/plutil -extract "$1" raw -o - "$2"; }
check_sql() {
    actual=$(/usr/bin/sqlite3 "$run_root/state/state.sqlite" "$1")
    if [ "$actual" != "$2" ]; then
        echo "Assertion failed: expected '$2', received '$actual'" >&2
        exit 1
    fi
}

tm init
tm add 'Investigate empty todo titles (synthetic test)' \
    'github:shyamkumar703/todo_list_test_task_manager:pr:1' > "$run_root/task.json"
task_id=$(extract id "$run_root/task.json")
tm add 'Independent task: must not block on another task question' > "$run_root/independent-task.json"
independent_id=$(extract id "$run_root/independent-task.json")
[ "$(tm ingest "$project_root/fixtures/github-feedback.json")" = 'Inserted 2 events' ]
[ "$(tm ingest "$project_root/fixtures/github-feedback.json")" = 'Inserted 0 events' ]
[ "$(tm route)" = 'Routed 2; pending 0' ]
[ "$(tm route)" = 'Routed 0; pending 0' ]
tm status "$task_id" running
tm status "$independent_id" running
question_id=$(tm ask "$task_id" 'Should whitespace-only titles be rejected?')
tm questions > "$run_root/questions-before-answer.json"
[ "$(extract 0.id "$run_root/questions-before-answer.json")" = "$question_id" ]
check_sql "SELECT status FROM tasks WHERE id = '$task_id';" waitingForUser
check_sql "SELECT status FROM tasks WHERE id = '$independent_id';" running
# Fresh CLI processes reopen SQLite for every operation, including answer delivery.
tm status "$task_id" paused
tm answer "$question_id" 'Yes, trim before validation.'
check_sql "SELECT status FROM tasks WHERE id = '$task_id';" paused
tm resume "$task_id"
check_sql "SELECT status FROM tasks WHERE id = '$task_id';" queued
check_sql "SELECT status FROM tasks WHERE id = '$independent_id';" running
[ -n "$(tm message "$task_id" 'Also preserve existing todo order.')" ]
check_sql "SELECT count(*) FROM messages WHERE task_id = '$task_id' AND delivered = 0;" 4
if tm answer "$question_id" 'Duplicate answer must fail' > "$run_root/duplicate-answer.txt" 2>&1; then
    echo 'Duplicate answer unexpectedly succeeded' >&2
    exit 1
fi
check_sql "SELECT count(*) FROM messages WHERE task_id = '$task_id';" 4
proposal_id=$(tm propose-comment "$task_id" \
    'https://github.com/shyamkumar703/todo_list_test_task_manager/pull/1' \
    'synthetic-head-not-a-real-commit' 'Synthetic proposal: do not publish.')
tm decide "$proposal_id" reject
check_sql "SELECT status FROM proposals WHERE id = '$proposal_id';" rejected
check_sql 'PRAGMA integrity_check;' ok
tm list > "$run_root/tasks-after-restart.json"
tm questions > "$run_root/questions-after-answer.json"
tm proposals > "$run_root/proposals.json"
tm journal > "$run_root/journal.json"
cat > "$run_root/RESULTS.txt" <<REPORT
PASS: test run from $test_root
Database: $run_root/state/state.sqlite
Task: $task_id
Independent task: $independent_id
Question: $question_id

Verified across separate processes:
- Two feedback events ingested once despite duplicate import.
- Known PR association routes each event once.
- Waiting question persists without blocking independent task state.
- Answer while paused preserves pause; resume queues task.
- Answer becomes a durable message; duplicate answer is rejected.
- Four pending messages persist (two feedback, answer, manual follow-up).
- Exact local comment proposal is rejected; no external executor runs.
- SQLite integrity_check returns ok.

Synthetic fixture only. No agent execution, repository code change, GitHub
publication, or test of automatic agent recovery is claimed.
REPORT
cat "$run_root/RESULTS.txt"
