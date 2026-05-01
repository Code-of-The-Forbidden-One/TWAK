#!/usr/bin/env bats
# shellcheck disable=SC2329  # stub definitions invoked indirectly
#
# Tests for lib/display.sh — duration formatting, hours conversion,
# title truncation, and the cmd_status output structure.

load 'helpers/setup.bash'
load 'helpers/mock_azdo.bash'

setup() {
    twk_setup_env
    twk_source_libs
    twk_load_stub_path
    mock_azdo_install
}

# -----------------------------------------------------------------------------
# format_duration — integer seconds → HH:MM:SS, zero-padded.
# -----------------------------------------------------------------------------

@test "format_duration: zero seconds renders 00:00:00" {
    run format_duration 0
    assert_status 0
    [[ "${output}" == "00:00:00" ]] || { echo "got: ${output}" >&2; return 1; }
}

@test "format_duration: 59 seconds is sub-minute" {
    run format_duration 59
    [[ "${output}" == "00:00:59" ]]
}

@test "format_duration: 60 seconds rolls into one minute" {
    run format_duration 60
    [[ "${output}" == "00:01:00" ]]
}

@test "format_duration: 3600 seconds renders one hour" {
    run format_duration 3600
    [[ "${output}" == "01:00:00" ]]
}

@test "format_duration: composite 1h 23m 45s" {
    run format_duration $(( 3600 + 23 * 60 + 45 ))
    [[ "${output}" == "01:23:45" ]]
}

@test "format_duration: 100 hours stays HH:MM:SS without truncation" {
    # 100 * 3600 = 360000 — verify HH width handles 3 digits.
    run format_duration 360000
    [[ "${output}" == "100:00:00" ]]
}

# -----------------------------------------------------------------------------
# seconds_to_hours — bc-driven division. Skip if bc isn't around (the
# stubs/bc fallback handles it, but we set up that fallback in setup()).
# -----------------------------------------------------------------------------

@test "seconds_to_hours: 3600 seconds is 1.00" {
    run seconds_to_hours 3600
    assert_status 0
    [[ "${output}" == "1.00" ]] || { echo "got: ${output}" >&2; return 1; }
}

@test "seconds_to_hours: 1800 seconds is .50 (bc strips leading zero)" {
    run seconds_to_hours 1800
    assert_status 0
    # bc renders 0.5 as ".50" with scale=2.
    [[ "${output}" == ".50" ]] || { echo "got: ${output}" >&2; return 1; }
}

@test "seconds_to_hours: 0 seconds is 0" {
    run seconds_to_hours 0
    assert_status 0
    [[ "${output}" == "0" || "${output}" == "0.00" || "${output}" == ".00" ]] \
        || { echo "got: ${output}" >&2; return 1; }
}

# Regression test for round-2 review #9: the bc stub historically used
# banker's rounding (ROUND_HALF_EVEN); real bc with `scale=2` truncates.
# 5/3 = 1.666… — real bc and ROUND_DOWN both yield "1.66"; banker's-round
# would have given "1.67". Lock in the truncating behaviour either way.
@test "bc stub (or real bc) truncates rather than banker's-rounds at scale=2" {
    require_binary bc
    local out
    out="$(echo 'scale=2; 5/3' | bc)"
    [[ "${out}" == "1.66" ]] \
        || { echo "expected 1.66 (truncate), got: ${out}" >&2; return 1; }
}

# -----------------------------------------------------------------------------
# truncate_title — three branches: under, exact, over.
# -----------------------------------------------------------------------------

@test "truncate_title: shorter than max returns unchanged" {
    run truncate_title "short" 10
    [[ "${output}" == "short" ]]
}

@test "truncate_title: exact length returns unchanged (boundary)" {
    run truncate_title "1234567890" 10
    [[ "${output}" == "1234567890" ]]
}

@test "truncate_title: over-length yields ASCII '...' suffix at exactly max chars" {
    run truncate_title "12345678901234567890" 10
    # Output should be 10 chars total with the trailing '...'.
    [[ "${output}" == "1234567..." ]] || { echo "got: ${output}" >&2; return 1; }
    [[ "${#output}" -eq 10 ]]
}

@test "truncate_title: default max is STATUS_TITLE_WIDTH (40)" {
    local title
    printf -v title 'A%.0s' {1..50}  # 50 As
    run truncate_title "${title}"
    [[ "${#output}" -eq 40 ]]
    [[ "${output}" == *"..." ]]
}

@test "truncate_title: empty input returns empty" {
    run truncate_title ""
    [[ "${output}" == "" ]]
}

# -----------------------------------------------------------------------------
# cmd_status — config line, table headers, totals, "(no title cached)"
# placeholder. cmd_status calls config_require, session_list_uncommitted,
# session_read_state, session_calculate_elapsed_seconds, seconds_to_hours,
# session_read_meta_title, format_duration, truncate_title.
#
# We don't mock those helpers; we let them run against real session files in
# the per-test data dir. config_require is satisfied by writing a fake config
# the test sources.
# -----------------------------------------------------------------------------

@test "cmd_status: prints config line and 'no entries' when no sessions exist" {
    twk_write_fake_config
    # Override config functions to point at the fake we just wrote, so
    # config_require finds it.
    config_global_file() { printf '%s\n' "${TWK_CONFIG_DIR}/config"; }
    config_find_local() { return 1; }

    run cmd_status
    assert_status 0
    assert_output_contains "Config:"
    assert_output_contains "${TWK_CONFIG_DIR}/config"
    assert_output_contains "global scope"
    assert_output_contains "No uncommitted time entries."
}

@test "cmd_status: renders table header and total row when sessions present" {
    require_binary jq  # session_read_meta_title and column rendering use jq via stub
    require_binary bc

    twk_write_fake_config
    config_global_file() { printf '%s\n' "${TWK_CONFIG_DIR}/config"; }
    config_find_local() { return 1; }

    # Two sessions: one running, one ended. Use fixed timestamps so duration
    # is deterministic.
    local now
    now="$(date +%s)"
    local hour_ago=$(( now - 3600 ))

    mkdir -p "${TWK_DATA_DIR}"
    {
        echo "start|${hour_ago}"
        echo "end|${now}"
    } > "${TWK_DATA_DIR}/100.session"

    # Session 200 has no meta — should render "(no title cached)".
    {
        echo "start|${hour_ago}"
        echo "pause|${now}"
    } > "${TWK_DATA_DIR}/200.session"

    # Session 100 has a cached title.
    printf '%s\n' '{"title":"cached title 100","type":"Task"}' \
        > "${TWK_DATA_DIR}/100.meta"

    run cmd_status
    assert_status 0
    assert_output_contains "Uncommitted time entries:"
    assert_output_contains "ID"
    assert_output_contains "Title"
    assert_output_contains "State"
    assert_output_contains "Hours"
    assert_output_contains "#100"
    assert_output_contains "cached title 100"
    assert_output_contains "#200"
    assert_output_contains "(no title cached)"
    assert_output_contains "Total"
    # Two sessions of one hour each = 02:00:00 total.
    assert_output_contains "02:00:00"
}

@test "cmd_status: rejects unknown arguments with usage hint" {
    twk_write_fake_config
    config_global_file() { printf '%s\n' "${TWK_CONFIG_DIR}/config"; }
    config_find_local() { return 1; }

    run cmd_status --bogus
    assert_status 1
    assert_output_contains "unknown argument '--bogus'"
    assert_output_contains "Usage: twk status"
}

@test "cmd_status --with-existing: renders extra columns and post-commit projection" {
    require_binary jq
    require_binary bc

    twk_write_fake_config
    config_global_file() { printf '%s\n' "${TWK_CONFIG_DIR}/config"; }
    config_find_local() { return 1; }

    # One session, one hour tracked.
    local now hour_ago
    now="$(date +%s)"
    hour_ago=$(( now - 3600 ))
    mkdir -p "${TWK_DATA_DIR}"
    echo "start|${hour_ago}" > "${TWK_DATA_DIR}/400.session"
    echo "end|${now}"        >> "${TWK_DATA_DIR}/400.session"
    printf '%s\n' '{"title":"with existing test","type":"Task"}' \
        > "${TWK_DATA_DIR}/400.meta"

    # Stub the batch fetch — return existing 4.20h on the configured task field.
    local task_field="${TWK_TIME_FIELD_TASK}"
    azdo_fetch_existing_times() {
        printf '%s' "{\"value\":[{\"id\":400,\"fields\":{\"System.WorkItemType\":\"Task\",\"${task_field}\":4.20}}]}"
    }

    run cmd_status --with-existing
    assert_status 0
    assert_output_contains "+ AzDO"
    assert_output_contains "= Total"
    assert_output_contains "#400"
    assert_output_contains "1.00h"      # tracked
    assert_output_contains "4.20h"      # existing
    assert_output_contains "5.20h"      # total = 4.20 + 1.00
}

@test "cmd_status --with-existing: shows '?' when batch fetch fails" {
    require_binary jq
    require_binary bc

    twk_write_fake_config
    config_global_file() { printf '%s\n' "${TWK_CONFIG_DIR}/config"; }
    config_find_local() { return 1; }

    local now hour_ago
    now="$(date +%s)"
    hour_ago=$(( now - 3600 ))
    mkdir -p "${TWK_DATA_DIR}"
    echo "start|${hour_ago}" > "${TWK_DATA_DIR}/500.session"
    echo "end|${now}"        >> "${TWK_DATA_DIR}/500.session"

    # Simulate AzDO unreachable.
    azdo_fetch_existing_times() { return 1; }

    run cmd_status --with-existing
    assert_status 0
    assert_output_contains "+ AzDO"
    assert_output_contains "?"
    # The command itself does not fail.
}

@test "build_existing_times_map: maps id -> task or feature time field by type" {
    require_binary jq

    twk_write_fake_config
    config_global_file() { printf '%s\n' "${TWK_CONFIG_DIR}/config"; }
    config_find_local() { return 1; }

    local task_field="${TWK_TIME_FIELD_TASK}"
    local feature_field="${TWK_TIME_FIELD_FEATURE}"

    azdo_fetch_existing_times() {
        printf '%s' "{
            \"value\": [
                {\"id\": 600, \"fields\": {\"System.WorkItemType\": \"Task\",    \"${task_field}\": 1.5}},
                {\"id\": 601, \"fields\": {\"System.WorkItemType\": \"Feature\", \"${feature_field}\": 2.5}},
                {\"id\": 602, \"fields\": {\"System.WorkItemType\": \"Bug\"}}
            ]
        }"
    }

    run build_existing_times_map "[600,601,602]"
    assert_status 0
    # Bug falls through to task field (which is missing → 0).
    assert_output_contains "600	1.5"
    assert_output_contains "601	2.5"
    assert_output_contains "602	0"
}

@test "lookup_existing_time: returns mapped value or '?' when missing" {
    local map=$'700\t3.14\n701\t1.0'

    run lookup_existing_time 700 "${map}"
    assert_status 0
    [[ "${output}" == "3.14" ]] || { echo "got: ${output}"; return 1; }

    run lookup_existing_time 999 "${map}"
    assert_status 0
    [[ "${output}" == "?" ]] || { echo "got: ${output}"; return 1; }
}

@test "cmd_status: 'no title cached' placeholder appears once per untitled session" {
    require_binary jq
    require_binary bc

    twk_write_fake_config
    config_global_file() { printf '%s\n' "${TWK_CONFIG_DIR}/config"; }
    config_find_local() { return 1; }

    mkdir -p "${TWK_DATA_DIR}"
    local now hour_ago
    now="$(date +%s)"
    hour_ago=$(( now - 3600 ))
    echo "start|${hour_ago}" > "${TWK_DATA_DIR}/300.session"
    echo "pause|${now}"     >> "${TWK_DATA_DIR}/300.session"

    run cmd_status
    assert_status 0
    # Should appear exactly once for #300.
    local count
    count="$(grep -c "no title cached" <<< "${output}")"
    [[ "${count}" -eq 1 ]] || { echo "got count=${count}; output:" >&2; echo "${output}" >&2; return 1; }
}
