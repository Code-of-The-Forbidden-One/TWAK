# tests/helpers/mock_azdo.bash
#
# Overrides the lib/azdo.sh API surface so tests run offline without curl,
# without network, and without a real Azure DevOps instance.
#
# Two complementary configuration mechanisms (use whichever is more
# convenient for the test):
#
#   1. Fixture files. Set MOCK_AZDO_FIXTURES_DIR to a directory containing:
#        work_item_<id>.json        - returned by azdo_fetch_work_item <id>
#        work_item_<id>.meta.json   - returned by azdo_fetch_work_item_meta
#        current_iteration.json     - returned by azdo_fetch_current_iteration
#        iteration_<id>_items.json  - returned by azdo_fetch_iteration_work_items
#        batch_response.json        - returned by azdo_fetch_work_items_batch
#      Missing fixture => mock returns rc=1 (simulates fetch failure).
#
#   2. Env-var toggles, useful for one-shot behaviour overrides:
#        MOCK_AZDO_TEST_CONNECTION_RC   - default 0
#        MOCK_AZDO_UPDATE_STATE_RC      - default 0
#        MOCK_AZDO_UPDATE_TIME_RC       - default 0
#        MOCK_AZDO_FETCH_WORK_ITEM_RC   - default 0
#                                          (still requires fixture for stdout)
#        MOCK_AZDO_FETCH_META_RC        - default 0
#
# Call recording: every mocked function appends a line to MOCK_AZDO_CALL_LOG
# (default: ${BATS_TEST_TMPDIR}/azdo_calls.log) with format:
#   <function>\t<arg1>\t<arg2>\t...
# Tests can grep this log to assert what was called.
#
# Usage from a bats setup():
#   load 'helpers/setup.bash'
#   load 'helpers/mock_azdo.bash'
#   twk_setup_env
#   twk_source_libs
#   mock_azdo_install
#   export MOCK_AZDO_FIXTURES_DIR="${BATS_TEST_DIRNAME}/fixtures"
#
# After the SUT runs:
#   mock_azdo_was_called azdo_update_time_spent && ...
#   mock_azdo_call_args azdo_update_time_spent      # echoes "<id>\t<hrs>\t<field>"

# shellcheck disable=SC2329  # functions defined inside override azdo_* dynamically
mock_azdo_install() {
    : "${MOCK_AZDO_CALL_LOG:=${BATS_TEST_TMPDIR:-/tmp}/azdo_calls.log}"
    export MOCK_AZDO_CALL_LOG
    : > "${MOCK_AZDO_CALL_LOG}"

    # Defaults
    : "${MOCK_AZDO_TEST_CONNECTION_RC:=0}"
    : "${MOCK_AZDO_UPDATE_STATE_RC:=0}"
    : "${MOCK_AZDO_UPDATE_TIME_RC:=0}"
    : "${MOCK_AZDO_FETCH_WORK_ITEM_RC:=0}"
    : "${MOCK_AZDO_FETCH_META_RC:=0}"
    : "${MOCK_AZDO_FETCH_ITERATION_RC:=0}"
    : "${MOCK_AZDO_FETCH_BATCH_RC:=0}"
    export MOCK_AZDO_TEST_CONNECTION_RC MOCK_AZDO_UPDATE_STATE_RC \
           MOCK_AZDO_UPDATE_TIME_RC MOCK_AZDO_FETCH_WORK_ITEM_RC \
           MOCK_AZDO_FETCH_META_RC MOCK_AZDO_FETCH_ITERATION_RC \
           MOCK_AZDO_FETCH_BATCH_RC

    azdo_api_request() {
        _mock_azdo_log "azdo_api_request" "$@"
        return 0
    }

    azdo_test_connection() {
        _mock_azdo_log "azdo_test_connection" "$@"
        return "${MOCK_AZDO_TEST_CONNECTION_RC}"
    }

    azdo_fetch_work_item() {
        _mock_azdo_log "azdo_fetch_work_item" "$@"
        local id="$1"
        if [[ "${MOCK_AZDO_FETCH_WORK_ITEM_RC}" != "0" ]]; then
            return "${MOCK_AZDO_FETCH_WORK_ITEM_RC}"
        fi
        local fixture="${MOCK_AZDO_FIXTURES_DIR:-}/work_item_${id}.json"
        if [[ -f "${fixture}" ]]; then
            cat "${fixture}"
            return 0
        fi
        return 1
    }

    azdo_fetch_work_item_meta() {
        _mock_azdo_log "azdo_fetch_work_item_meta" "$@"
        local id="$1"
        if [[ "${MOCK_AZDO_FETCH_META_RC}" != "0" ]]; then
            return "${MOCK_AZDO_FETCH_META_RC}"
        fi
        local fixture="${MOCK_AZDO_FIXTURES_DIR:-}/work_item_${id}.meta.json"
        if [[ -f "${fixture}" ]]; then
            cat "${fixture}"
            return 0
        fi
        return 1
    }

    azdo_fetch_current_iteration() {
        _mock_azdo_log "azdo_fetch_current_iteration" "$@"
        if [[ "${MOCK_AZDO_FETCH_ITERATION_RC}" != "0" ]]; then
            return "${MOCK_AZDO_FETCH_ITERATION_RC}"
        fi
        local fixture="${MOCK_AZDO_FIXTURES_DIR:-}/current_iteration.json"
        if [[ -f "${fixture}" ]]; then
            cat "${fixture}"
            return 0
        fi
        return 1
    }

    azdo_fetch_iteration_work_items() {
        _mock_azdo_log "azdo_fetch_iteration_work_items" "$@"
        local id="$1"
        local fixture="${MOCK_AZDO_FIXTURES_DIR:-}/iteration_${id}_items.json"
        if [[ -f "${fixture}" ]]; then
            cat "${fixture}"
            return 0
        fi
        return 1
    }

    azdo_fetch_work_items_batch() {
        _mock_azdo_log "azdo_fetch_work_items_batch" "$@"
        if [[ "${MOCK_AZDO_FETCH_BATCH_RC}" != "0" ]]; then
            return "${MOCK_AZDO_FETCH_BATCH_RC}"
        fi
        local fixture="${MOCK_AZDO_FIXTURES_DIR:-}/batch_response.json"
        if [[ -f "${fixture}" ]]; then
            cat "${fixture}"
            return 0
        fi
        return 1
    }

    azdo_update_state() {
        _mock_azdo_log "azdo_update_state" "$@"
        return "${MOCK_AZDO_UPDATE_STATE_RC}"
    }

    azdo_update_time_spent() {
        _mock_azdo_log "azdo_update_time_spent" "$@"
        return "${MOCK_AZDO_UPDATE_TIME_RC}"
    }

    # azdo_resolve_time_field calls azdo_fetch_work_item internally; let it
    # do that so tests can swap the fixture rather than re-stub. But provide
    # an override hook for tests that want to bypass.
    if [[ "${MOCK_AZDO_RESOLVE_TIME_FIELD_OVERRIDE:-}" != "" ]]; then
        eval "azdo_resolve_time_field() { _mock_azdo_log 'azdo_resolve_time_field' \"\$@\"; printf '%s\n' '${MOCK_AZDO_RESOLVE_TIME_FIELD_OVERRIDE}'; }"
    fi
}

_mock_azdo_log() {
    # Each call gets one physical line in the log so grep/head/cut work
    # predictably. Real newlines inside an arg (typically pretty-printed
    # JSON bodies) are escaped to literal "\n" before joining; callers
    # asserting on body content should expect the escaped form.
    local IFS=$'\t'
    local arg
    local sanitized=()
    for arg in "$@"; do
        sanitized+=("${arg//$'\n'/\\n}")
    done
    printf '%s\n' "${sanitized[*]}" >> "${MOCK_AZDO_CALL_LOG}"
}

# True if <fn> was called at least once.
mock_azdo_was_called() {
    local fn="$1"
    grep -qE "^${fn}(\$|	)" "${MOCK_AZDO_CALL_LOG}"
}

# Echo the tab-separated args from the first call to <fn>. Newlines that
# appeared inside any arg at call time are returned as the literal
# two-char sequence "\n" — see _mock_azdo_log above.
mock_azdo_call_args() {
    local fn="$1"
    grep -E "^${fn}(\$|	)" "${MOCK_AZDO_CALL_LOG}" | head -n1 | cut -f2-
}

# Echo the number of times <fn> was called.
mock_azdo_call_count() {
    local fn="$1"
    grep -cE "^${fn}(\$|	)" "${MOCK_AZDO_CALL_LOG}" || true
}
