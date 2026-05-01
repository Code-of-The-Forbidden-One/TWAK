#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031
#   SC2030/SC2031: env var modifications inside @test bodies look subshell-
#                  scoped to shellcheck, but bats' `run` inherits exports.
#
# Tests for lib/session.sh — validation, state machine, atomic pop semantics,
# archive helpers, meta caching, and the parse_state_flag/parse_query_arg pair.

load 'helpers/setup.bash'
load 'helpers/mock_azdo.bash'

setup() {
    twk_setup_env
    twk_source_libs
    twk_load_stub_path
    mock_azdo_install
}

# -----------------------------------------------------------------------------
# validate_work_item_id
# -----------------------------------------------------------------------------

@test "validate_work_item_id: numeric IDs accepted" {
    run validate_work_item_id 12345
    assert_status 0
    [[ -z "${output}" ]]
}

@test "validate_work_item_id: single digit accepted" {
    run validate_work_item_id 0
    assert_status 0
}

@test "validate_work_item_id: alphabetic input rejected with stderr message" {
    run validate_work_item_id abc
    assert_status 1
    assert_output_contains "invalid work item ID 'abc'"
    assert_output_contains "numeric"
}

@test "validate_work_item_id: mixed alphanumeric rejected" {
    run validate_work_item_id 12a
    assert_status 1
}

@test "validate_work_item_id: negative numbers rejected (regex anchors at ^)" {
    run validate_work_item_id -- -5
    # Note: bash function arg parsing — '-5' may look like a flag to `run`.
    # We pass `--` to disambiguate. validate_work_item_id only checks regex.
    assert_status 1
}

@test "validate_work_item_id: empty input rejected" {
    run validate_work_item_id ""
    assert_status 1
    assert_output_contains "invalid work item ID"
}

@test "validate_work_item_id: input with embedded space rejected" {
    run validate_work_item_id "12 3"
    assert_status 1
}

# -----------------------------------------------------------------------------
# session_read_state — state machine. Every event sequence + empty + missing.
# -----------------------------------------------------------------------------

@test "session_read_state: missing file returns 'none'" {
    run session_read_state 999
    assert_status 0
    [[ "${output}" == "none" ]]
}

@test "session_read_state: empty file returns 'none' (event_type empty)" {
    : > "${TWK_DATA_DIR}/100.session"
    run session_read_state 100
    assert_status 0
    [[ "${output}" == "none" ]]
}

@test "session_read_state: 'start' event yields 'running'" {
    echo "start|1700000000" > "${TWK_DATA_DIR}/100.session"
    run session_read_state 100
    [[ "${output}" == "running" ]]
}

@test "session_read_state: 'resume' event yields 'running'" {
    {
        echo "start|1700000000"
        echo "pause|1700000060"
        echo "resume|1700000120"
    } > "${TWK_DATA_DIR}/100.session"
    run session_read_state 100
    [[ "${output}" == "running" ]]
}

@test "session_read_state: 'pause' event yields 'paused'" {
    {
        echo "start|1700000000"
        echo "pause|1700000060"
    } > "${TWK_DATA_DIR}/100.session"
    run session_read_state 100
    [[ "${output}" == "paused" ]]
}

@test "session_read_state: 'end' event yields 'ended'" {
    {
        echo "start|1700000000"
        echo "end|1700000060"
    } > "${TWK_DATA_DIR}/100.session"
    run session_read_state 100
    [[ "${output}" == "ended" ]]
}

@test "session_read_state: unknown last event yields 'none'" {
    echo "garbage|1700000000" > "${TWK_DATA_DIR}/100.session"
    run session_read_state 100
    [[ "${output}" == "none" ]]
}

@test "session_read_state: non-numeric ID returns rc=1" {
    run session_read_state notnumeric
    assert_status 1
}

# -----------------------------------------------------------------------------
# session_calculate_elapsed_seconds — including the "running, count up to now"
# branch. Since this branch reads `date +%s` on the live clock, we test the
# closed cases (sum is exact) plus that the running branch contributes a
# non-zero positive value at minimum.
# -----------------------------------------------------------------------------

@test "session_calculate_elapsed_seconds: missing session returns 0" {
    run session_calculate_elapsed_seconds 999
    assert_status 0
    [[ "${output}" == "0" ]]
}

@test "session_calculate_elapsed_seconds: simple start→end is exact diff" {
    {
        echo "start|1700000000"
        echo "end|1700000600"   # 600s = 10min
    } > "${TWK_DATA_DIR}/100.session"
    run session_calculate_elapsed_seconds 100
    [[ "${output}" == "600" ]]
}

@test "session_calculate_elapsed_seconds: start→pause→resume→end sums two segments" {
    {
        echo "start|1700000000"
        echo "pause|1700000300"   # +300
        echo "resume|1700001000"  # gap is unpaid
        echo "end|1700001500"     # +500
    } > "${TWK_DATA_DIR}/100.session"
    run session_calculate_elapsed_seconds 100
    [[ "${output}" == "800" ]]
}

@test "session_calculate_elapsed_seconds: paused without resume only counts first segment" {
    {
        echo "start|1700000000"
        echo "pause|1700000200"
    } > "${TWK_DATA_DIR}/100.session"
    run session_calculate_elapsed_seconds 100
    [[ "${output}" == "200" ]]
}

@test "session_calculate_elapsed_seconds: still-running counts to 'now' (positive, recent)" {
    # Use a timestamp 5 seconds in the past. Output should be >= 5 and within
    # a few seconds of that — verifying the 'running, count up to now' branch.
    local five_ago
    five_ago=$(( $(date +%s) - 5 ))
    echo "start|${five_ago}" > "${TWK_DATA_DIR}/100.session"
    run session_calculate_elapsed_seconds 100
    assert_status 0
    [[ "${output}" -ge 4 ]] || { echo "got: ${output}" >&2; return 1; }
    [[ "${output}" -le 30 ]] || { echo "got: ${output}" >&2; return 1; }
}

@test "session_calculate_elapsed_seconds: resume without prior start counts from resume" {
    # If a session somehow starts with 'resume', segment_start is set and
    # treated as the start of a segment. (Defensive: no error.)
    local five_ago
    five_ago=$(( $(date +%s) - 5 ))
    echo "resume|${five_ago}" > "${TWK_DATA_DIR}/100.session"
    run session_calculate_elapsed_seconds 100
    assert_status 0
    [[ "${output}" -ge 4 ]]
}

# -----------------------------------------------------------------------------
# session_pop_last_event — distinct exit codes:
#   2 = no file, 3 = empty file, 0 = success.
# Also: atomic mv semantics (no temp file left), and the round-1 trailing-
# newline corner case.
# -----------------------------------------------------------------------------

@test "session_pop_last_event: rc=2 when session file does not exist" {
    run session_pop_last_event 999
    assert_status 2
}

@test "session_pop_last_event: rc=3 when session file is empty (zero bytes)" {
    : > "${TWK_DATA_DIR}/100.session"
    run session_pop_last_event 100
    assert_status 3
    # The empty file should have been cleaned up.
    assert_file_not_exists "${TWK_DATA_DIR}/100.session"
}

@test "session_pop_last_event: rc=0, echoes popped event, leaves remaining lines" {
    {
        echo "start|1700000000"
        echo "pause|1700000060"
    } > "${TWK_DATA_DIR}/100.session"
    run session_pop_last_event 100
    assert_status 0
    [[ "${output}" == "pause" ]]
    # Remaining file should contain only the start line.
    [[ "$(cat "${TWK_DATA_DIR}/100.session")" == "start|1700000000" ]]
}

@test "session_pop_last_event: single-line file removes the file entirely" {
    echo "start|1700000000" > "${TWK_DATA_DIR}/100.session"
    run session_pop_last_event 100
    assert_status 0
    [[ "${output}" == "start" ]]
    assert_file_not_exists "${TWK_DATA_DIR}/100.session"
}

@test "session_pop_last_event: handles file without trailing newline correctly (round-1 bug)" {
    # The round-1 review identified a bug where wc -l mis-counted files that
    # lacked a trailing newline, causing data loss on multi-event files.
    # The fix uses awk; verify both the single-line and multi-line cases.
    printf 'start|1700000000\npause|1700000060' > "${TWK_DATA_DIR}/100.session"
    # File has two records but no trailing newline.
    run session_pop_last_event 100
    assert_status 0
    [[ "${output}" == "pause" ]]
    # The first event must NOT have been deleted.
    assert_file_exists "${TWK_DATA_DIR}/100.session"
    [[ "$(cat "${TWK_DATA_DIR}/100.session")" == "start|1700000000" ]]
}

@test "session_pop_last_event: single-line file without trailing newline removes file" {
    printf 'start|1700000000' > "${TWK_DATA_DIR}/100.session"
    run session_pop_last_event 100
    assert_status 0
    [[ "${output}" == "start" ]]
    assert_file_not_exists "${TWK_DATA_DIR}/100.session"
}

@test "session_pop_last_event: leaves no temp .XXXXXX file behind on success" {
    {
        echo "start|1700000000"
        echo "pause|1700000060"
        echo "resume|1700000120"
    } > "${TWK_DATA_DIR}/100.session"

    run session_pop_last_event 100
    assert_status 0

    # No leftover mktemp leftover should remain in TWK_DATA_DIR.
    local leftovers
    leftovers="$(find "${TWK_DATA_DIR}" -maxdepth 1 -name '100.session.*' 2>/dev/null)"
    [[ -z "${leftovers}" ]] || { echo "leftovers: ${leftovers}" >&2; return 1; }
}

@test "session_pop_last_event: invalid id returns rc=1" {
    run session_pop_last_event abc
    assert_status 1
}

# -----------------------------------------------------------------------------
# session_mark_committed / session_mark_cancelled — archive moves the
# .session into committed/ or cancelled/ with a timestamp suffix; meta is
# moved alongside.
# -----------------------------------------------------------------------------

@test "session_mark_committed: moves .session and .meta into committed/" {
    echo "start|1700000000" > "${TWK_DATA_DIR}/100.session"
    printf '%s\n' '{"title":"x","type":"Task"}' > "${TWK_DATA_DIR}/100.meta"

    run session_mark_committed 100
    assert_status 0
    assert_file_not_exists "${TWK_DATA_DIR}/100.session"
    assert_file_not_exists "${TWK_DATA_DIR}/100.meta"

    local committed_session committed_meta
    committed_session="$(find "${TWK_DATA_DIR}/committed" -name '100_*.session' | head -n1)"
    committed_meta="$(find "${TWK_DATA_DIR}/committed" -name '100_*.meta' | head -n1)"
    [[ -n "${committed_session}" ]] || { echo "no committed session found" >&2; return 1; }
    [[ -n "${committed_meta}" ]] || { echo "no committed meta found" >&2; return 1; }

    # Meta and session should share the same timestamp suffix.
    local sess_ts meta_ts
    sess_ts="$(basename "${committed_session}" .session | sed 's/^100_//')"
    meta_ts="$(basename "${committed_meta}" .meta | sed 's/^100_//')"
    [[ "${sess_ts}" == "${meta_ts}" ]]
}

@test "session_mark_cancelled: moves .session and .meta into cancelled/" {
    echo "start|1700000000" > "${TWK_DATA_DIR}/100.session"
    printf '%s\n' '{"title":"x","type":"Task"}' > "${TWK_DATA_DIR}/100.meta"

    run session_mark_cancelled 100
    assert_status 0
    assert_file_not_exists "${TWK_DATA_DIR}/100.session"
    local cancelled_session cancelled_meta
    cancelled_session="$(find "${TWK_DATA_DIR}/cancelled" -name '100_*.session' | head -n1)"
    cancelled_meta="$(find "${TWK_DATA_DIR}/cancelled" -name '100_*.meta' | head -n1)"
    [[ -n "${cancelled_session}" ]]
    [[ -n "${cancelled_meta}" ]]
}

@test "session_archive_meta: no-op when meta file does not exist (does not fail)" {
    mkdir -p "${TWK_DATA_DIR}/committed"
    # No 100.meta in TWK_DATA_DIR.
    run session_archive_meta 100 "${TWK_DATA_DIR}/committed" "1700001234"
    assert_status 0
    [[ -z "$(ls "${TWK_DATA_DIR}/committed")" ]]
}

# -----------------------------------------------------------------------------
# session_cache_meta — three cases: existing meta no-op, fetch on first call,
# AzDO failure no-op.
# -----------------------------------------------------------------------------

@test "session_cache_meta: returns 0 and writes nothing when meta already exists" {
    printf '%s\n' '{"title":"existing","type":"Task"}' > "${TWK_DATA_DIR}/100.meta"

    # If azdo_fetch_work_item_meta is called we want the test to fail.
    local before_calls
    before_calls="$(mock_azdo_call_count azdo_fetch_work_item_meta)"

    run session_cache_meta 100
    assert_status 0

    local after_calls
    after_calls="$(mock_azdo_call_count azdo_fetch_work_item_meta)"
    [[ "${after_calls}" -eq "${before_calls}" ]] \
        || { echo "fetch was called ${after_calls} times (was ${before_calls})" >&2; return 1; }
}

@test "session_cache_meta: fetches and writes meta on first call" {
    # Provide a fixture so the mock returns success.
    local fixtures="${TWK_BATS_TMP}/fixtures"
    mkdir -p "${fixtures}"
    printf '%s\n' '{"title":"new title","type":"Task"}' > "${fixtures}/work_item_100.meta.json"
    export MOCK_AZDO_FIXTURES_DIR="${fixtures}"

    run session_cache_meta 100
    assert_status 0
    assert_file_exists "${TWK_DATA_DIR}/100.meta"
    grep -q "new title" "${TWK_DATA_DIR}/100.meta"
}

@test "session_cache_meta: no-op (rc=1) when AzDO fetch fails, no meta file written" {
    # No fixture provided + no override → mock returns rc=1.
    run session_cache_meta 100
    assert_status 1
    assert_file_not_exists "${TWK_DATA_DIR}/100.meta"
}

@test "session_cache_meta: rc=1 when AzDO returns empty meta_json" {
    local fixtures="${TWK_BATS_TMP}/fixtures"
    mkdir -p "${fixtures}"
    : > "${fixtures}/work_item_100.meta.json"  # empty
    export MOCK_AZDO_FIXTURES_DIR="${fixtures}"

    run session_cache_meta 100
    assert_status 1
    assert_file_not_exists "${TWK_DATA_DIR}/100.meta"
}

# -----------------------------------------------------------------------------
# parse_state_flag — extracts the value following --state in any position.
# parse_query_arg — first non-flag argument, skipping --state and its value.
# -----------------------------------------------------------------------------

@test "parse_state_flag: returns value after --state" {
    run parse_state_flag --state Doing
    assert_status 0
    [[ "${output}" == "Doing" ]]
}

@test "parse_state_flag: returns value after --state with id before it" {
    run parse_state_flag 12345 --state Done
    [[ "${output}" == "Done" ]]
}

@test "parse_state_flag: returns value after --state with state value containing spaces" {
    run parse_state_flag 12345 --state "Code Review"
    [[ "${output}" == "Code Review" ]]
}

@test "parse_state_flag: empty when --state absent" {
    run parse_state_flag 12345
    assert_status 0
    [[ -z "${output}" ]]
}

@test "parse_state_flag: empty when --state is the last arg with no value" {
    run parse_state_flag 12345 --state
    assert_status 0
    [[ -z "${output}" ]]
}

@test "parse_query_arg: returns first positional arg" {
    run parse_query_arg 12345
    [[ "${output}" == "12345" ]]
}

@test "parse_query_arg: skips --state value, returns following positional" {
    run parse_query_arg --state Done 12345
    [[ "${output}" == "12345" ]]
}

@test "parse_query_arg: --state at end of args, returns first positional" {
    run parse_query_arg "login bug" --state Done
    [[ "${output}" == "login bug" ]]
}

@test "parse_query_arg: --state in middle, positional precedes" {
    run parse_query_arg 12345 --state Done
    [[ "${output}" == "12345" ]]
}

@test "parse_query_arg: empty when no positional given (only --state)" {
    run parse_query_arg --state Done
    assert_status 0
    [[ -z "${output}" ]]
}

@test "parse_query_arg: empty argv yields empty output" {
    run parse_query_arg
    assert_status 0
    [[ -z "${output}" ]]
}

# -----------------------------------------------------------------------------
# session_file_path / session_meta_file_path / session_exists / session_meta_exists
# Smoke tests for the path helpers.
# -----------------------------------------------------------------------------

@test "session_file_path: returns TWK_DATA_DIR/<id>.session" {
    run session_file_path 12345
    [[ "${output}" == "${TWK_DATA_DIR}/12345.session" ]]
}

@test "session_meta_file_path: returns TWK_DATA_DIR/<id>.meta" {
    run session_meta_file_path 12345
    [[ "${output}" == "${TWK_DATA_DIR}/12345.meta" ]]
}

@test "session_file_path: invalid id returns rc=1" {
    run session_file_path xyz
    assert_status 1
}

@test "session_exists: false when no file" {
    run session_exists 999
    assert_status 1
}

@test "session_exists: true when file present" {
    echo "start|1700000000" > "${TWK_DATA_DIR}/100.session"
    run session_exists 100
    assert_status 0
}

# -----------------------------------------------------------------------------
# session_work_item_id_from_path — basename strips path and .session suffix.
# -----------------------------------------------------------------------------

@test "session_work_item_id_from_path: extracts numeric id" {
    run session_work_item_id_from_path "/var/lib/twk/12345.session"
    [[ "${output}" == "12345" ]]
}

@test "session_work_item_id_from_path: handles relative path" {
    run session_work_item_id_from_path "12345.session"
    [[ "${output}" == "12345" ]]
}

# -----------------------------------------------------------------------------
# session_list_uncommitted — empty dir returns nothing; populated returns paths.
# -----------------------------------------------------------------------------

@test "session_list_uncommitted: empty data dir returns nothing" {
    run session_list_uncommitted
    assert_status 0
    [[ -z "${output}" ]]
}

@test "session_list_uncommitted: populated dir returns one path per session" {
    echo "start|1700000000" > "${TWK_DATA_DIR}/100.session"
    echo "start|1700000000" > "${TWK_DATA_DIR}/200.session"
    run session_list_uncommitted
    assert_status 0
    assert_output_contains "100.session"
    assert_output_contains "200.session"
}

# -----------------------------------------------------------------------------
# cmd_pull — refreshes .meta for every uncommitted session via
# azdo_fetch_work_item_meta (overridden per test).
# -----------------------------------------------------------------------------

@test "cmd_pull: rejects unexpected arguments" {
    twk_write_fake_config

    run cmd_pull surplus
    assert_status 1
    assert_output_contains "takes no arguments"
}

@test "cmd_pull: prints 'no sessions' when there is nothing to refresh" {
    twk_write_fake_config

    run cmd_pull
    assert_status 0
    assert_output_contains "No sessions to refresh."
}

@test "cmd_pull: refreshes meta for every session and reports per-line" {
    require_binary jq
    twk_write_fake_config

    echo "start|1700000000" > "${TWK_DATA_DIR}/100.session"
    echo "start|1700000000" > "${TWK_DATA_DIR}/200.session"

    azdo_fetch_work_item_meta() {
        case "$1" in
            100) printf '%s' '{"title":"First","type":"Task"}' ;;
            200) printf '%s' '{"title":"Second","type":"Bug"}' ;;
            *)   return 1 ;;
        esac
    }

    run cmd_pull
    assert_status 0
    assert_output_contains "Refreshing metadata for 2 sessions..."
    assert_output_contains "#100: refreshed (\"First\")"
    assert_output_contains "#200: refreshed (\"Second\")"
    assert_output_contains "Done: 2 refreshed, 0 failed."

    [[ -f "${TWK_DATA_DIR}/100.meta" ]] || { echo "100.meta missing"; return 1; }
    grep -q '"title":"First"' "${TWK_DATA_DIR}/100.meta"
    [[ -f "${TWK_DATA_DIR}/200.meta" ]] || { echo "200.meta missing"; return 1; }
    grep -q '"title":"Second"' "${TWK_DATA_DIR}/200.meta"
}

@test "cmd_pull: failures are reported per-session and do not abort the loop" {
    require_binary jq
    twk_write_fake_config

    echo "start|1700000000" > "${TWK_DATA_DIR}/100.session"
    echo "start|1700000000" > "${TWK_DATA_DIR}/200.session"
    echo "start|1700000000" > "${TWK_DATA_DIR}/300.session"

    azdo_fetch_work_item_meta() {
        case "$1" in
            100) printf '%s' '{"title":"OK","type":"Task"}' ;;
            200) return 1 ;;
            300) printf '%s' '{"title":"Also OK","type":"Bug"}' ;;
        esac
    }

    run cmd_pull
    assert_status 0
    assert_output_contains "#100: refreshed"
    assert_output_contains "#200: failed"
    assert_output_contains "#300: refreshed"
    assert_output_contains "Done: 2 refreshed, 1 failed."
}

@test "cmd_pull: overwrites a stale meta file with the fresh value" {
    require_binary jq
    twk_write_fake_config

    echo "start|1700000000" > "${TWK_DATA_DIR}/100.session"
    printf '%s' '{"title":"Stale name","type":"Task"}' > "${TWK_DATA_DIR}/100.meta"

    azdo_fetch_work_item_meta() {
        printf '%s' '{"title":"Fresh name","type":"Task"}'
    }

    run cmd_pull
    assert_status 0
    grep -q '"title":"Fresh name"' "${TWK_DATA_DIR}/100.meta"
    ! grep -q '"title":"Stale name"' "${TWK_DATA_DIR}/100.meta"
}

@test "cmd_pull: refreshed message omits empty title in parens" {
    require_binary jq
    twk_write_fake_config

    echo "start|1700000000" > "${TWK_DATA_DIR}/100.session"

    azdo_fetch_work_item_meta() {
        printf '%s' '{"title":"","type":"Task"}'
    }

    run cmd_pull
    assert_status 0
    [[ "${output}" == *"#100: refreshed"* ]] || { echo "got: ${output}"; return 1; }
    [[ "${output}" != *"#100: refreshed (\"\")"* ]] || { echo "should not show empty quoted title"; return 1; }
}
