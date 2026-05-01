# tests/helpers/setup.bash
#
# Common bats setup. Sourced from each *.bats file's setup().
#
# Provides:
#   - twk_setup_env:        per-test tmpdir, TWK_DATA_DIR/TWK_CONFIG_DIR overrides
#   - twk_source_libs:      sources lib/*.sh in dependency order, no bin/twk
#   - twk_load_stub_path:   prepends tests/helpers/stubs onto PATH
#                           (for python-based jq/bc fallbacks when the system
#                           lacks the real binaries; if jq/bc are already on
#                           PATH this is a no-op).
#
# Tests that need to invoke `bin/twk` itself should additionally set
# TWK_VERSION, TWK_SCRIPT, TWK_ROOT and TWK_LIB to mirror what bin/twk does
# at startup, OR simply `run "${TWK_REPO}/bin/twk" <args>` and let bin/twk
# bootstrap normally — TWK_DATA_DIR/TWK_CONFIG_DIR are exported here so the
# child shell sees them.

# Resolve repo root once, regardless of current CWD when bats runs us.
TWK_TEST_HELPERS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
TWK_REPO="$( cd "${TWK_TEST_HELPERS_DIR}/../.." && pwd )"
export TWK_REPO TWK_TEST_HELPERS_DIR

twk_setup_env() {
    # bats provides BATS_TEST_TMPDIR per-test (since 1.7).
    : "${BATS_TEST_TMPDIR:=$(mktemp -d -t twk-bats-XXXXXX)}"

    export TWK_BATS_TMP="${BATS_TEST_TMPDIR}"
    export TWK_DATA_DIR="${TWK_BATS_TMP}/data/sessions"
    export TWK_CONFIG_DIR="${TWK_BATS_TMP}/config"
    export HOME="${TWK_BATS_TMP}/home"

    mkdir -p "${TWK_DATA_DIR}" "${TWK_CONFIG_DIR}" "${HOME}"

    # Default: no AzDO config sourced. Tests that need one should call
    # twk_write_fake_config or set TWK_* directly.
    unset TWK_ORGANIZATION TWK_PROJECT TWK_TEAM TWK_PAT \
          TWK_TIME_FIELD_TASK TWK_TIME_FIELD_FEATURE \
          TWK_STATE_ACTIVE TWK_STATE_PAUSED TWK_STATE_DONE
}

twk_source_libs() {
    # Order matters: config.sh defines no deps, azdo.sh uses validate_work_item_id
    # from session.sh, resolve.sh uses session.sh, display.sh uses session.sh,
    # session.sh uses display.sh's format_duration (cmd_pause/cmd_end echo it).
    # banner.sh / help.sh are leaves.
    #
    # bin/twk sources in this order:
    #   config azdo resolve session display help banner
    # so we mirror that.
    # shellcheck disable=SC1091
    source "${TWK_REPO}/lib/config.sh"
    # shellcheck disable=SC1091
    source "${TWK_REPO}/lib/azdo.sh"
    # shellcheck disable=SC1091
    source "${TWK_REPO}/lib/resolve.sh"
    # shellcheck disable=SC1091
    source "${TWK_REPO}/lib/session.sh"
    # shellcheck disable=SC1091
    source "${TWK_REPO}/lib/display.sh"
    # shellcheck disable=SC1091
    source "${TWK_REPO}/lib/help.sh"
    # shellcheck disable=SC1091
    source "${TWK_REPO}/lib/banner.sh"
}

# Append tests/helpers/stubs onto PATH so real `jq`/`bc` (when installed)
# take precedence and the python-backed stubs only fill in when neither is
# available system-wide. Decision (round-2 review #3): real wins, stubs are
# the fallback. This keeps the stubs from masking real-jq/real-bc behaviour
# divergences on developer machines / CI.
#
# If you change the codebase to use a new jq filter, update
# tests/helpers/stubs/jq accordingly so machines without real jq stay green.
twk_load_stub_path() {
    export PATH="${PATH}:${TWK_TEST_HELPERS_DIR}/stubs"
}

# Write a fake config to TWK_CONFIG_DIR/config and source it. Used by tests
# that exercise functions which read TWK_ORGANIZATION etc.
twk_write_fake_config() {
    local config_file="${TWK_CONFIG_DIR}/config"
    mkdir -p "${TWK_CONFIG_DIR}"
    cat > "${config_file}" <<'EOF'
TWK_ORGANIZATION=fakeorg
TWK_PROJECT=FakeProject
TWK_TEAM=FakeTeam
TWK_PAT=fakepat
TWK_TIME_FIELD_TASK=Custom.TimeSpent
TWK_TIME_FIELD_FEATURE=Custom.TimeSpentFeature
TWK_STATE_ACTIVE=Active
TWK_STATE_PAUSED=Paused
TWK_STATE_DONE=Done
EOF
    # shellcheck disable=SC1090
    source "${config_file}"
}

# --- Assertion helpers ---------------------------------------------------

# assert_status <expected> — fail with diagnostic if $status != expected.
# Use after `run`. Includes the captured output to make failures debuggable.
#
# `status` and `output` below are bats-managed magic globals populated by
# `run`; shellcheck can't see that, hence the SC2154 disables.
assert_status() {
    local expected="$1"
    # shellcheck disable=SC2154
    if [[ "${status}" -ne "${expected}" ]]; then
        # shellcheck disable=SC2154
        printf 'expected status %s, got %s\noutput:\n%s\n' \
            "${expected}" "${status}" "${output}" >&2
        return 1
    fi
}

# assert_output_contains <substring>
assert_output_contains() {
    local needle="$1"
    # shellcheck disable=SC2154
    if [[ "${output}" != *"${needle}"* ]]; then
        printf 'expected output to contain %q\noutput:\n%s\n' \
            "${needle}" "${output}" >&2
        return 1
    fi
}

# assert_output_not_contains <substring>
assert_output_not_contains() {
    local needle="$1"
    # shellcheck disable=SC2154
    if [[ "${output}" == *"${needle}"* ]]; then
        printf 'expected output NOT to contain %q\noutput:\n%s\n' \
            "${needle}" "${output}" >&2
        return 1
    fi
}

# assert_session_state <id> <expected_state>
# Reads the session state and compares.
assert_session_state() {
    local id="$1"
    local expected="$2"
    local actual
    actual="$(session_read_state "${id}")"
    if [[ "${actual}" != "${expected}" ]]; then
        printf 'session #%s: expected state %s, got %s\n' \
            "${id}" "${expected}" "${actual}" >&2
        return 1
    fi
}

# assert_session_event_count <id> <expected_count>
assert_session_event_count() {
    local id="$1"
    local expected="$2"
    local file="${TWK_DATA_DIR}/${id}.session"
    local actual=0
    if [[ -f "${file}" ]]; then
        actual="$(grep -c '' "${file}" 2>/dev/null || echo 0)"
    fi
    if [[ "${actual}" -ne "${expected}" ]]; then
        printf 'session #%s: expected %s events, got %s\nfile contents:\n%s\n' \
            "${id}" "${expected}" "${actual}" \
            "$(cat "${file}" 2>/dev/null || echo '<missing>')" >&2
        return 1
    fi
}

# assert_file_exists <path>
assert_file_exists() {
    local path="$1"
    if [[ ! -e "${path}" ]]; then
        printf 'expected file to exist: %s\n' "${path}" >&2
        return 1
    fi
}

# assert_file_not_exists <path>
assert_file_not_exists() {
    local path="$1"
    if [[ -e "${path}" ]]; then
        printf 'expected file NOT to exist: %s\n' "${path}" >&2
        return 1
    fi
}

# Skip the test if a required binary isn't on PATH.
require_binary() {
    local bin="$1"
    if ! command -v "${bin}" &>/dev/null; then
        skip "requires '${bin}' on PATH"
    fi
}
