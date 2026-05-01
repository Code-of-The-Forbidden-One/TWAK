#!/usr/bin/env bats
# shellcheck disable=SC2329  # stub definitions invoked indirectly
#
# End-to-end integration test for the TWAK lifecycle.
#
# Exercises a complete session:  start → pause → start (resume) → end → commit.
# The AzDO API is fully mocked. After the run we assert:
#   1. The session events were appended in the right order.
#   2. The committed session+meta files appear in committed/ with matching
#      timestamps.
#   3. azdo_update_time_spent was called exactly once with the right hours.
#   4. azdo_resolve_time_field was called and routed the value through.
#   5. The 'twk status' output between steps reflects the elapsed time.
#
# To make timestamps deterministic we override `date +%s` (the only call
# session.sh makes for time) by injecting a `date` shim onto PATH that, when
# called as `date +%s`, prints a value from a counter file. Real `date` is
# untouched for any other invocation (which we don't make).

load 'helpers/setup.bash'
load 'helpers/mock_azdo.bash'

setup() {
    twk_setup_env
    twk_source_libs
    twk_load_stub_path
    mock_azdo_install

    require_binary jq
    require_binary bc

    # Seed config so config_require finds it.
    twk_write_fake_config
    config_find_local() { return 1; }

    # AzDO meta fixture so session_cache_meta succeeds on first 'start'.
    export MOCK_AZDO_FIXTURES_DIR="${TWK_BATS_TMP}/fixtures"
    mkdir -p "${MOCK_AZDO_FIXTURES_DIR}"
    cat > "${MOCK_AZDO_FIXTURES_DIR}/work_item_42.meta.json" <<'EOF'
{"title":"Integration test item","type":"Task"}
EOF

    # Work item fixture for cmd_commit (azdo_resolve_time_field +
    # cmd_commit's existing-hours read).
    cat > "${MOCK_AZDO_FIXTURES_DIR}/work_item_42.json" <<'EOF'
{
  "id": 42,
  "fields": {
    "System.Title": "Integration test item",
    "System.WorkItemType": "Task",
    "Custom.TimeSpent": 0.5
  }
}
EOF

    # Set up deterministic 'now': the i-th call returns
    # BASE + 60*counter. We don't even need that complexity here — every
    # session_append calls date once, every elapsed_seconds calculation
    # also calls it for the running branch. We just want monotonic timestamps.
    export DATE_COUNTER_FILE="${TWK_BATS_TMP}/date_counter"
    export DATE_BASE=1700000000
    echo 0 > "${DATE_COUNTER_FILE}"

    local fake_date_dir="${TWK_BATS_TMP}/fake_date_bin"
    mkdir -p "${fake_date_dir}"
    cat > "${fake_date_dir}/date" <<'EOF'
#!/bin/bash
# Fake `date` for integration test — only handles +%s by reading a counter
# file. Anything else passes through to real date.
if [[ "$1" == "+%s" ]]; then
    base="${DATE_BASE:-1700000000}"
    counter_file="${DATE_COUNTER_FILE:?}"
    n="$(cat "${counter_file}")"
    echo $(( base + n * 60 ))
    echo $(( n + 1 )) > "${counter_file}"
    exit 0
fi
# Find real date elsewhere on PATH.
for d in /usr/bin /bin; do
    if [[ -x "${d}/date" ]]; then
        exec "${d}/date" "$@"
    fi
done
exit 127
EOF
    chmod +x "${fake_date_dir}/date"
    export PATH="${fake_date_dir}:${PATH}"
}

# -----------------------------------------------------------------------------
# Lifecycle
# -----------------------------------------------------------------------------

@test "lifecycle: start → pause → start → end → commit, archives session+meta and PATCHes hours" {
    # 1. start #42  (counter 0 → ts 1700000000)
    run cmd_start 42
    assert_status 0
    assert_output_contains "Started tracking #42"
    assert_session_state 42 running
    assert_session_event_count 42 1
    # session_cache_meta should have been triggered once.
    [[ "$(mock_azdo_call_count azdo_fetch_work_item_meta)" -ge 1 ]]
    assert_file_exists "${TWK_DATA_DIR}/42.meta"
    grep -q "Integration test item" "${TWK_DATA_DIR}/42.meta"

    # 2. pause #42  (counter 1 → ts 1700000060) — but wait: the 'pause'
    # branch in cmd_pause also calls session_calculate_elapsed_seconds,
    # which only reads timestamps from the file (no date call) since the
    # last event is now 'pause'. So counter advances by exactly 1.
    run cmd_pause 42
    assert_status 0
    assert_output_contains "Paused #42"
    # Elapsed at pause: ts(1) - ts(0) = 60s = "00:01:00".
    assert_output_contains "00:01:00"
    assert_session_state 42 paused
    assert_session_event_count 42 2

    # 3. start #42 again — should append 'resume', not 'start'.
    run cmd_start 42
    assert_status 0
    assert_output_contains "Resumed tracking #42"
    assert_session_state 42 running
    assert_session_event_count 42 3
    # No second meta fetch because meta exists.
    local meta_calls
    meta_calls="$(mock_azdo_call_count azdo_fetch_work_item_meta)"
    [[ "${meta_calls}" -eq 1 ]]

    # 4. end #42  (counter 3 → ts 1700000180; resume was at ts(2)=1700000120).
    # Total elapsed: (60-0) + (180-120) = 60 + 60 = 120s.
    run cmd_end 42
    assert_status 0
    assert_output_contains "Ended #42"
    assert_output_contains "00:02:00"
    assert_session_state 42 ended
    assert_session_event_count 42 4

    # 5. commit. cmd_commit calls (per session):
    #      session_read_state → no date call
    #      session_calculate_elapsed_seconds → no date call (ended)
    #      seconds_to_hours → bc subshell
    #      azdo_resolve_time_field → fetches work item, returns Custom.TimeSpent
    #      azdo_fetch_work_item → existing hours = 0.5
    #      azdo_update_time_spent → mocked, captures call
    #      session_mark_committed → bumps date counter
    run cmd_commit
    assert_status 0
    assert_output_contains "#42: committed"
    # 120s = 0.0333… h → bc with scale=2 yields ".03"
    assert_output_contains ".03h"
    # Existing 0.5 + new ~0.03 = ~0.53 total.
    assert_output_contains "(total: .53h)"
    assert_output_contains "Done: 1 committed"

    # 6. Verify the archive layout: committed/<id>_<ts>.session and the
    # matching .meta with the same suffix.
    assert_file_not_exists "${TWK_DATA_DIR}/42.session"
    assert_file_not_exists "${TWK_DATA_DIR}/42.meta"
    local archived_session archived_meta
    archived_session="$(find "${TWK_DATA_DIR}/committed" -name '42_*.session' | head -n1)"
    archived_meta="$(find "${TWK_DATA_DIR}/committed" -name '42_*.meta' | head -n1)"
    [[ -n "${archived_session}" ]] || { echo "no committed session" >&2; ls -la "${TWK_DATA_DIR}/committed/" >&2; return 1; }
    [[ -n "${archived_meta}" ]]    || { echo "no committed meta" >&2;    ls -la "${TWK_DATA_DIR}/committed/" >&2; return 1; }

    # Both should have identical timestamp suffixes (same call to date in
    # session_mark_committed).
    local sess_ts meta_ts
    sess_ts="$(basename "${archived_session}" .session | sed 's/^42_//')"
    meta_ts="$(basename "${archived_meta}" .meta | sed 's/^42_//')"
    [[ "${sess_ts}" == "${meta_ts}" ]] \
        || { echo "ts mismatch: session=${sess_ts} meta=${meta_ts}" >&2; return 1; }

    # Archived session should contain all four events in order.
    local content
    content="$(cat "${archived_session}")"
    [[ "${content}" == *"start|"* ]]
    [[ "${content}" == *"pause|"* ]]
    [[ "${content}" == *"resume|"* ]]
    [[ "${content}" == *"end|"* ]]

    # Order check: line 1 = start, 2 = pause, 3 = resume, 4 = end.
    [[ "$(sed -n '1p' "${archived_session}" | cut -d'|' -f1)" == "start" ]]
    [[ "$(sed -n '2p' "${archived_session}" | cut -d'|' -f1)" == "pause" ]]
    [[ "$(sed -n '3p' "${archived_session}" | cut -d'|' -f1)" == "resume" ]]
    [[ "$(sed -n '4p' "${archived_session}" | cut -d'|' -f1)" == "end" ]]

    # 7. The fake AzDO PATCH for time was issued exactly once.
    [[ "$(mock_azdo_call_count azdo_update_time_spent)" -eq 1 ]] \
        || { echo "update_time_spent calls: $(mock_azdo_call_count azdo_update_time_spent)" >&2; return 1; }

    # And it was issued with id=42, total_hours ~ .53, time_field = Custom.TimeSpent.
    local args
    args="$(mock_azdo_call_args azdo_update_time_spent)"
    [[ "${args}" == "42"$'\t'".53"$'\t'"Custom.TimeSpent" ]] \
        || { echo "captured args: ${args}" >&2; return 1; }
}

@test "lifecycle: cancel discards session into cancelled/ archive without PATCH" {
    # start, pause, then cancel.
    cmd_start 42 >/dev/null
    cmd_pause 42 >/dev/null

    run cmd_cancel 42
    assert_status 0
    assert_output_contains "Cancelled #42"

    # No update_time_spent call.
    [[ "$(mock_azdo_call_count azdo_update_time_spent)" -eq 0 ]]

    # Archive should be in cancelled/, not committed/.
    local cancelled
    cancelled="$(find "${TWK_DATA_DIR}/cancelled" -name '42_*.session' | head -n1)"
    [[ -n "${cancelled}" ]]
    assert_file_not_exists "${TWK_DATA_DIR}/42.session"
    [[ ! -d "${TWK_DATA_DIR}/committed" ]] \
        || [[ -z "$(ls -A "${TWK_DATA_DIR}/committed" 2>/dev/null)" ]]
}

@test "lifecycle: undo removes the most recent event and reverts state" {
    cmd_start 42 >/dev/null
    cmd_pause 42 >/dev/null
    assert_session_event_count 42 2
    assert_session_state 42 paused

    run cmd_undo 42
    assert_status 0
    assert_output_contains "Undid 'pause'"
    assert_session_event_count 42 1
    assert_session_state 42 running

    # Undo again — should remove the only remaining event and delete file.
    run cmd_undo 42
    assert_status 0
    assert_output_contains "Undid 'start'"
    assert_output_contains "session removed"
    assert_file_not_exists "${TWK_DATA_DIR}/42.session"
}

@test "lifecycle: commit skips running sessions, doesn't archive them" {
    # Start but don't end.
    cmd_start 42 >/dev/null
    assert_session_state 42 running

    run cmd_commit
    assert_status 0
    assert_output_contains "#42: skipped (still running"
    [[ "$(mock_azdo_call_count azdo_update_time_spent)" -eq 0 ]]

    # Session should still be present and intact.
    assert_file_exists "${TWK_DATA_DIR}/42.session"
}

@test "lifecycle: status between events shows correct cumulative time" {
    # First start at counter 0 (ts 1700000000).
    cmd_start 42 >/dev/null
    # Pause at counter 1 (ts 1700000060) — 60s elapsed.
    cmd_pause 42 >/dev/null

    run cmd_status
    assert_status 0
    assert_output_contains "#42"
    assert_output_contains "Integration test item"
    assert_output_contains "00:01:00"
    assert_output_contains "paused"
}
