#!/usr/bin/env bats
# shellcheck disable=SC2329,SC2034
#   SC2329: stub function definitions are invoked indirectly by SUT
#   SC2034: TWK_* variables are read by the sourced libs
#
# Tests for moving work items on the board:
#   - TWK_STATE_ON_START / TWK_STATE_ON_PAUSE move the item on start/pause;
#   - --state overrides them once, --no-state skips them;
#   - `twk end --done` sets TWK_STATE_DONE;
#   - 0.1.x configs (TWK_STATE_ACTIVE/PAUSED) move nothing.

load 'helpers/setup.bash'

setup() {
    twk_setup_env
    twk_source_libs
    twk_load_stub_path
    require_binary jq
    twk_write_fake_config

    session_cache_meta() { :; }
    azdo_update_state() {
        printf '%s %s\n' "$1" "$2" >> "${BATS_TEST_TMPDIR}/states"
    }
}

# Adds lines to the fake config, so they go through config_require.
_config() {
    printf '%s\n' "$@" >> "${TWK_CONFIG_DIR}/config"
}

_states_sent() {
    cat "${BATS_TEST_TMPDIR}/states" 2>/dev/null
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

@test "parse_query_arg: skips --no-state and --done" {
    run parse_query_arg --no-state 12345
    [[ "${output}" == "12345" ]] || { echo "got: ${output}"; return 1; }
    run parse_query_arg --done "login bug"
    [[ "${output}" == "login bug" ]] || { echo "got: ${output}"; return 1; }
}

@test "resolve_target_state: --state beats --no-state, --done, and the default" {
    TWK_STATE_DONE=Closed
    run resolve_target_state Doing 1 --no-state --done --state Review
    [[ "${output}" == "Review" ]] || { echo "got: ${output}"; return 1; }
}

@test "resolve_target_state: --no-state gives no state" {
    run resolve_target_state Doing 1 --no-state
    [[ -z "${output}" ]] || { echo "got: ${output}"; return 1; }
}

@test "resolve_target_state: --done gives the configured done state" {
    TWK_STATE_DONE=Closed
    run resolve_target_state "" 1 --done
    [[ "${output}" == "Closed" ]] || { echo "got: ${output}"; return 1; }
}

@test "resolve_target_state: otherwise the default" {
    run resolve_target_state Doing 1
    [[ "${output}" == "Doing" ]] || { echo "got: ${output}"; return 1; }
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

@test "cmd_start: moves the item to TWK_STATE_ON_START" {
    _config "TWK_STATE_ON_START=Doing"

    run cmd_start 42
    assert_status 0
    assert_output_contains "State set to Doing"
    [[ "$(_states_sent)" == "42 Doing" ]] || { echo "sent: $(_states_sent)"; return 1; }
}

@test "cmd_start: resuming a paused item moves it to the start state too" {
    _config "TWK_STATE_ON_START=Doing"
    mkdir -p "${TWK_DATA_DIR}"
    printf 'start|1000\npause|1600\n' > "${TWK_DATA_DIR}/42.session"

    run cmd_start 42
    assert_output_contains "Resumed tracking #42"
    [[ "$(_states_sent)" == "42 Doing" ]] || { echo "sent: $(_states_sent)"; return 1; }
}

@test "cmd_start: --no-state leaves the state alone" {
    _config "TWK_STATE_ON_START=Doing"

    run cmd_start 42 --no-state
    assert_status 0
    [[ -z "$(_states_sent)" ]] || { echo "sent: $(_states_sent)"; return 1; }
}

@test "cmd_start: --state overrides the configured start state" {
    _config "TWK_STATE_ON_START=Doing"

    run cmd_start 42 --state "Code Review"
    [[ "$(_states_sent)" == "42 Code Review" ]] || { echo "sent: $(_states_sent)"; return 1; }
}

@test "cmd_start: a 0.1.x config (TWK_STATE_ACTIVE only) moves nothing" {
    # The fake config holds TWK_STATE_ACTIVE=Active and no TWK_STATE_ON_START.
    run cmd_start 42
    assert_status 0
    [[ -z "$(_states_sent)" ]] || { echo "sent: $(_states_sent)"; return 1; }
}

@test "cmd_start: no state change when the item is already running" {
    _config "TWK_STATE_ON_START=Doing"
    mkdir -p "${TWK_DATA_DIR}"
    echo "start|1000" > "${TWK_DATA_DIR}/42.session"

    run cmd_start 42
    assert_status 1
    [[ -z "$(_states_sent)" ]] || { echo "sent: $(_states_sent)"; return 1; }
}

@test "cmd_pause: moves the item to TWK_STATE_ON_PAUSE, or not with --no-state" {
    _config "TWK_STATE_ON_PAUSE=Blocked"
    mkdir -p "${TWK_DATA_DIR}"
    echo "start|1000" > "${TWK_DATA_DIR}/42.session"
    echo "start|1000" > "${TWK_DATA_DIR}/43.session"

    run cmd_pause 42
    assert_output_contains "State set to Blocked"
    run cmd_pause 43 --no-state
    [[ "$(_states_sent)" == "42 Blocked" ]] || { echo "sent: $(_states_sent)"; return 1; }
}

@test "cmd_end: changes no state by default" {
    _config "TWK_STATE_ON_START=Doing" "TWK_STATE_ON_PAUSE=Blocked"
    mkdir -p "${TWK_DATA_DIR}"
    echo "start|1000" > "${TWK_DATA_DIR}/42.session"

    run cmd_end 42
    assert_status 0
    [[ -z "$(_states_sent)" ]] || { echo "sent: $(_states_sent)"; return 1; }
}

@test "cmd_end --done: ends the session and sets the done state" {
    _config "TWK_STATE_DONE=Closed"
    mkdir -p "${TWK_DATA_DIR}"
    echo "start|1000" > "${TWK_DATA_DIR}/42.session"

    run cmd_end 42 --done
    assert_status 0
    assert_output_contains "Ended #42"
    assert_output_contains "State set to Closed"
    assert_session_state 42 ended
    [[ "$(_states_sent)" == "42 Closed" ]] || { echo "sent: $(_states_sent)"; return 1; }
}

@test "cmd_done: uses the configured done state" {
    _config "TWK_STATE_DONE=Closed"
    run cmd_done 42
    [[ "$(_states_sent)" == "42 Closed" ]] || { echo "sent: $(_states_sent)"; return 1; }
}

@test "config_parse_file: TWK_STATE_DONE defaults to Done" {
    local file="${BATS_TEST_TMPDIR}/parse_me.conf"
    printf 'TWK_ORGANIZATION=o\nTWK_PROJECT=p\nTWK_PAT=x\nTWK_TIME_FIELD_TASK=Custom.T\n' > "${file}"
    config_parse_file "${file}"
    [[ "${TWK_STATE_DONE}" == "Done" ]]
    [[ -z "${TWK_STATE_ON_START}" ]]
}

@test "config_parse_file: 0.1.x state keys load without a warning" {
    local file="${BATS_TEST_TMPDIR}/parse_me.conf"
    printf 'TWK_ORGANIZATION=o\nTWK_PROJECT=p\nTWK_PAT=x\nTWK_TIME_FIELD_TASK=Custom.T\nTWK_STATE_ACTIVE=Active\nTWK_STATE_PAUSED=Paused\n' > "${file}"
    run config_parse_file "${file}"
    assert_status 0
    assert_output_not_contains "unknown key"
}

@test "cmd_doctor: shows the configured state moves" {
    cd "${BATS_TEST_TMPDIR}"
    _config "TWK_STATE_ON_START=Doing"
    azdo_fetch_authenticated_user() { printf '%s' '{"authenticatedUser":{"providerDisplayName":"A"}}'; }

    run cmd_doctor
    assert_output_contains "start → Doing, pause → (no change), done → Done"
}
