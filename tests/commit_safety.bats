#!/usr/bin/env bats
# shellcheck disable=SC2329,SC2034
#   SC2329: stub function definitions are invoked indirectly by SUT
#   SC2034: TWK_* variables are read by the sourced libs
#
# Tests for the audit's correctness fixes around writing hours:
#   - a commit never writes when it could not read the current value;
#   - it sends the revision it read, so a concurrent change is refused;
#   - a commit whose outcome is unknown is recovered, not repeated;
#   - `twk add`, session locking, and `twk doctor`.

load 'helpers/setup.bash'

setup() {
    twk_setup_env
    twk_source_libs
    twk_load_stub_path
    require_binary jq
    twk_write_fake_config
    TWK_AUTH=pat
    export TWK_LOCK_WAIT_TENTHS=5
}

# One ended session on #100 holding exactly one hour.
_one_hour_session() {
    mkdir -p "${TWK_DATA_DIR}"
    printf 'start|1000\nend|4600\n' > "${TWK_DATA_DIR}/100.session"
}

# azdo_fetch_work_item answers with this work item: rev 5, 2.5h done.
_work_item_rev5() {
    azdo_fetch_work_item() {
        printf '%s' '{"id":100,"rev":5,"fields":{"System.WorkItemType":"Task","Custom.TimeSpent":2.5}}'
    }
}

# azdo_update_time_spent records its arguments and returns <rc>.
_record_updates() {
    export UPDATE_RC="${1:-0}"
    azdo_update_time_spent() {
        printf '%s\n' "$*" >> "${BATS_TEST_TMPDIR}/updates"
        return "${UPDATE_RC}"
    }
}

_update_count() {
    grep -c . "${BATS_TEST_TMPDIR}/updates" 2>/dev/null || echo 0
}

@test "cmd_commit: a failed read writes nothing and keeps the session" {
    _one_hour_session
    azdo_fetch_work_item() { echo "Error: HTTP 503" >&2; return 2; }
    _record_updates 0

    run cmd_commit
    assert_output_contains "#100: failed (could not read the current hours; nothing was written)"
    assert_output_contains "0 committed, 1 failed"
    [[ "$(_update_count)" -eq 0 ]] || { echo "an update was sent"; return 1; }
    assert_file_exists "${TWK_DATA_DIR}/100.session"
}

@test "cmd_commit: adds to the existing hours and sends the revision it read" {
    _one_hour_session
    _work_item_rev5
    _record_updates 0

    run cmd_commit
    assert_status 0
    assert_output_contains "#100: committed 1.00h (total: 3.50h)"
    [[ "$(cat "${BATS_TEST_TMPDIR}/updates")" == "100 3.50 Custom.TimeSpent 5" ]] \
        || { echo "update: $(cat "${BATS_TEST_TMPDIR}/updates")"; return 1; }
    assert_file_not_exists "${TWK_DATA_DIR}/100.session"
    assert_file_not_exists "${TWK_DATA_DIR}/100.pending"
}

@test "cmd_commit: a total under one hour is sent with a leading zero" {
    mkdir -p "${TWK_DATA_DIR}"
    printf 'start|1000\nend|2800\n' > "${TWK_DATA_DIR}/100.session"
    azdo_fetch_work_item() {
        printf '%s' '{"id":100,"rev":1,"fields":{"System.WorkItemType":"Task"}}'
    }
    _record_updates 0

    run cmd_commit
    assert_status 0
    [[ "$(cut -d' ' -f2 "${BATS_TEST_TMPDIR}/updates")" == "0.50" ]] \
        || { echo "update: $(cat "${BATS_TEST_TMPDIR}/updates")"; return 1; }
}

@test "cmd_commit: Feature items use the feature time field" {
    _one_hour_session
    azdo_fetch_work_item() {
        printf '%s' '{"id":100,"rev":2,"fields":{"System.WorkItemType":"Feature","Custom.TimeSpentFeature":1}}'
    }
    _record_updates 0

    run cmd_commit
    assert_status 0
    [[ "$(cat "${BATS_TEST_TMPDIR}/updates")" == "100 2.00 Custom.TimeSpentFeature 2" ]] \
        || { echo "update: $(cat "${BATS_TEST_TMPDIR}/updates")"; return 1; }
}

@test "cmd_commit: a refused write keeps the session and leaves no pending record" {
    _one_hour_session
    _work_item_rev5
    _record_updates 1

    run cmd_commit
    assert_output_contains "#100: failed to update Azure DevOps (nothing was written)"
    assert_file_exists "${TWK_DATA_DIR}/100.session"
    assert_file_not_exists "${TWK_DATA_DIR}/100.pending"
}

@test "cmd_commit: an unknown outcome keeps a pending record" {
    _one_hour_session
    _work_item_rev5
    _record_updates 2

    run cmd_commit
    assert_output_contains "outcome unknown"
    assert_file_exists "${TWK_DATA_DIR}/100.session"
    [[ "$(cat "${TWK_DATA_DIR}/100.pending")" == "5 350" ]] \
        || { echo "pending: $(cat "${TWK_DATA_DIR}/100.pending")"; return 1; }
}

@test "cmd_commit: a pending commit that landed is archived, not added again" {
    _one_hour_session
    echo "5 350" > "${TWK_DATA_DIR}/100.pending"
    azdo_fetch_work_item() {
        printf '%s' '{"id":100,"rev":6,"fields":{"System.WorkItemType":"Task","Custom.TimeSpent":3.5}}'
    }
    _record_updates 0

    run cmd_commit
    assert_status 0
    assert_output_contains "already committed by an earlier run (total: 3.50h)"
    [[ "$(_update_count)" -eq 0 ]] || { echo "hours were added twice"; return 1; }
    assert_file_not_exists "${TWK_DATA_DIR}/100.session"
    assert_file_not_exists "${TWK_DATA_DIR}/100.pending"
}

@test "cmd_commit: a pending commit that did not land is retried normally" {
    _one_hour_session
    echo "5 350" > "${TWK_DATA_DIR}/100.pending"
    _work_item_rev5
    _record_updates 0

    run cmd_commit
    assert_status 0
    assert_output_contains "#100: committed 1.00h (total: 3.50h)"
    [[ "$(_update_count)" -eq 1 ]]
    assert_file_not_exists "${TWK_DATA_DIR}/100.pending"
}

@test "cmd_commit --dry-run: shows the projection and the rounded total" {
    _one_hour_session
    _work_item_rev5
    _record_updates 0

    run cmd_commit --dry-run
    assert_status 0
    assert_output_contains "would commit 1.00h (existing 2.50h → total 3.50h)"
    assert_output_contains "Would commit 1.00h across 1 session"
    [[ "$(_update_count)" -eq 0 ]]
}

# -----------------------------------------------------------------------------
# twk add
# -----------------------------------------------------------------------------

@test "cmd_add: creates an ended session holding the time" {
    session_cache_meta() { :; }

    run cmd_add 321 1h30m
    assert_status 0
    assert_output_contains "Added 01:30:00 to #321"
    assert_session_state 321 ended
    [[ "$(session_calculate_elapsed_seconds 321)" -eq 5400 ]]
}

@test "cmd_add: adds to an existing session" {
    session_cache_meta() { :; }
    mkdir -p "${TWK_DATA_DIR}"
    printf 'start|1000\npause|1600\n' > "${TWK_DATA_DIR}/321.session"

    run cmd_add 321 2.5h
    assert_status 0
    assert_session_state 321 paused
    [[ "$(session_calculate_elapsed_seconds 321)" -eq $(( 600 + 9000 )) ]]
}

@test "cmd_add: rejects a missing or invalid duration" {
    run cmd_add 321
    assert_status 1
    assert_output_contains "invalid duration '321'"

    run cmd_add 321 soon
    assert_status 1
    assert_output_contains "invalid duration 'soon'"

    run cmd_add
    assert_status 1
    assert_output_contains "a duration is required"
}

# -----------------------------------------------------------------------------
# Locking
# -----------------------------------------------------------------------------

@test "session_lock: a lock held by a live process makes others wait, then give up" {
    mkdir -p "${TWK_DATA_DIR}/.lock"
    echo "$$" > "${TWK_DATA_DIR}/.lock/pid"

    run session_locked true
    assert_status 1
    assert_output_contains "another twk command is changing sessions"
}

@test "session_lock: a lock left by a process that has gone is taken over" {
    mkdir -p "${TWK_DATA_DIR}/.lock"
    echo "999999" > "${TWK_DATA_DIR}/.lock/pid"

    run session_locked true
    assert_status 0
    assert_file_not_exists "${TWK_DATA_DIR}/.lock"
}

@test "session_locked: passes the command's status through and releases the lock" {
    run session_locked false
    assert_status 1
    assert_file_not_exists "${TWK_DATA_DIR}/.lock"
}

# -----------------------------------------------------------------------------
# twk doctor
# -----------------------------------------------------------------------------

@test "cmd_doctor: shows the settings and the connection, never the PAT" {
    cd "${BATS_TEST_TMPDIR}"
    chmod 600 "${TWK_CONFIG_DIR}/config"
    chmod 700 "${TWK_CONFIG_DIR}"
    azdo_fetch_authenticated_user() {
        printf '%s' '{"authenticatedUser":{"providerDisplayName":"Ada Lovelace"}}'
    }

    run cmd_doctor
    assert_status 0
    assert_output_contains "${TWK_CONFIG_DIR}/config (global)"
    assert_output_contains "fakeorg"
    assert_output_contains "Personal Access Token (set, 7 characters)"
    assert_output_contains "connected to fakeorg as Ada Lovelace"
    assert_output_not_contains "fakepat"
}

@test "cmd_doctor: reports a failed connection and exits non-zero" {
    cd "${BATS_TEST_TMPDIR}"
    chmod 600 "${TWK_CONFIG_DIR}/config"
    chmod 700 "${TWK_CONFIG_DIR}"
    azdo_fetch_authenticated_user() { echo "Error: HTTP 401" >&2; return 1; }

    run cmd_doctor
    assert_status 1
    assert_output_contains "could not connect"
    assert_output_contains "Problems found."
}

@test "format_epoch: formats an epoch as a local date and time" {
    run format_epoch 0
    assert_status 0
    [[ "${output}" =~ ^19(69|70)-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]] \
        || { echo "got: ${output}"; return 1; }
}
