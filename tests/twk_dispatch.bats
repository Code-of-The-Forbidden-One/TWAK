#!/usr/bin/env bats
# Tests for bin/twk — the top-level dispatcher.
#
# We source lib/dispatch.sh directly (the same file bin/twk sources) and
# install lightweight overrides for cmd_init / cmd_start / etc. that log
# their calls. This way any future drift in the real main()/print_usage()
# is observed by these tests rather than being masked by an inline copy.
#
# bin/twk also runs check_dependencies on startup which exits if curl/jq/bc
# are missing. We don't reach that path here because we source the libs
# manually. A separate test below invokes bin/twk for real and verifies it
# dispatches end-to-end (skipped when curl/jq/bc are unavailable).

load 'helpers/setup.bash'

setup() {
    twk_setup_env

    # Create stub binaries for curl/jq/bc that satisfy `command -v`. The jq
    # and bc are real (python-based) stubs; curl is just a no-op. These are
    # needed by the bin/twk end-to-end test below.
    export TWK_DISPATCH_BIN="${TWK_BATS_TMP}/dispatch_bin"
    mkdir -p "${TWK_DISPATCH_BIN}"
    cat > "${TWK_DISPATCH_BIN}/curl" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${TWK_DISPATCH_BIN}/curl"
    ln -sf "${TWK_TEST_HELPERS_DIR}/stubs/jq" "${TWK_DISPATCH_BIN}/jq"
    ln -sf "${TWK_TEST_HELPERS_DIR}/stubs/bc" "${TWK_DISPATCH_BIN}/bc"

    # Write a fake config so bin/twk's command path can find it without
    # prompting. cmd_init we'll override; everyone else uses config_require.
    twk_write_fake_config
}

# Helper: invoke the dispatcher with overrides installed. Logs calls to
# CALL_LOG=${TWK_BATS_TMP}/dispatch_calls.log
_run_dispatch() {
    local call_log="${TWK_BATS_TMP}/dispatch_calls.log"
    : > "${call_log}"
    export CALL_LOG="${call_log}"

    # shellcheck disable=SC2016
    # The bash -c body is intentionally single-quoted so the inner shell
    # evaluates ${command}, ${1:-}, etc. Outer-shell vars are interpolated
    # via the close-single/open-double dance ('"${var}"') where needed.
    PATH="${TWK_DISPATCH_BIN}:${TWK_TEST_HELPERS_DIR}/stubs:${PATH}" \
    HOME="${TWK_BATS_TMP}/home" \
    "${BASH}" -c '
        set -euo pipefail
        readonly TWK_VERSION="0.1.0"
        readonly TWK_SCRIPT="'"${TWK_REPO}"'/bin/twk"
        readonly TWK_ROOT="'"${TWK_REPO}"'"
        readonly TWK_LIB="${TWK_ROOT}/lib"
        readonly TWK_CONFIG_DIR="'"${TWK_CONFIG_DIR}"'"
        readonly TWK_DATA_DIR="'"${TWK_DATA_DIR}"'"

        source "${TWK_LIB}/config.sh"
        source "${TWK_LIB}/azdo.sh"
        source "${TWK_LIB}/resolve.sh"
        source "${TWK_LIB}/session.sh"
        source "${TWK_LIB}/display.sh"
        source "${TWK_LIB}/help.sh"
        source "${TWK_LIB}/banner.sh"
        # Source the REAL dispatcher. Any future change to main() or
        # print_usage() will be observed by these tests.
        source "${TWK_LIB}/dispatch.sh"

        # Override every cmd_* to log into CALL_LOG. We separate the cmd
        # name from its args with a tab.
        cmd_init()    { printf "init\t%s\n"    "$*" >> "$CALL_LOG"; }
        cmd_start()   { printf "start\t%s\n"   "$*" >> "$CALL_LOG"; }
        cmd_pause()   { printf "pause\t%s\n"   "$*" >> "$CALL_LOG"; }
        cmd_end()     { printf "end\t%s\n"     "$*" >> "$CALL_LOG"; }
        cmd_done()    { printf "done\t%s\n"    "$*" >> "$CALL_LOG"; }
        cmd_assign()  { printf "assign\t%s\n"  "$*" >> "$CALL_LOG"; }
        cmd_comment() { printf "comment\t%s\n" "$*" >> "$CALL_LOG"; }
        cmd_reset()   { printf "reset\t%s\n"   "$*" >> "$CALL_LOG"; }
        cmd_undo()    { printf "undo\t%s\n"    "$*" >> "$CALL_LOG"; }
        cmd_cancel()  { printf "cancel\t%s\n"  "$*" >> "$CALL_LOG"; }
        cmd_adjust()  { printf "adjust\t%s\n"  "$*" >> "$CALL_LOG"; }
        cmd_list()    { printf "list\t%s\n"    "$*" >> "$CALL_LOG"; }
        cmd_show()    { printf "show\t%s\n"    "$*" >> "$CALL_LOG"; }
        cmd_users()   { printf "users\t%s\n"   "$*" >> "$CALL_LOG"; }
        cmd_log()     { printf "log\t%s\n"     "$*" >> "$CALL_LOG"; }
        cmd_pull()    { printf "pull\t%s\n"    "$*" >> "$CALL_LOG"; }
        cmd_status()  { printf "status\t%s\n"  "$*" >> "$CALL_LOG"; }
        cmd_commit()  { printf "commit\t%s\n"  "$*" >> "$CALL_LOG"; }

        main "$@"
    ' _ "$@"
}

_first_call() {
    head -n1 "${CALL_LOG:-${TWK_BATS_TMP}/dispatch_calls.log}"
}

# -----------------------------------------------------------------------------
# Routing — every subcommand routes to the right cmd_* function.
# -----------------------------------------------------------------------------

@test "dispatch: 'twk start 12345' → cmd_start 12345" {
    run _run_dispatch start 12345
    assert_status 0
    [[ "$(_first_call)" == $'start\t12345' ]]
}

@test "dispatch: 'twk pause 12345' → cmd_pause 12345" {
    run _run_dispatch pause 12345
    assert_status 0
    [[ "$(_first_call)" == $'pause\t12345' ]]
}

@test "dispatch: 'twk end 12345 --state Done' → cmd_end with all args" {
    run _run_dispatch end 12345 --state Done
    assert_status 0
    [[ "$(_first_call)" == $'end\t12345 --state Done' ]]
}

@test "dispatch: 'twk done 12345' → cmd_done" {
    # shellcheck disable=SC1010  # 'done' is a literal arg here, not a keyword
    run _run_dispatch done 12345
    [[ "$(_first_call)" == $'done\t12345' ]]
}

@test "dispatch: 'twk undo 12345' → cmd_undo" {
    run _run_dispatch undo 12345
    [[ "$(_first_call)" == $'undo\t12345' ]]
}

@test "dispatch: 'twk cancel 12345' → cmd_cancel" {
    run _run_dispatch cancel 12345
    [[ "$(_first_call)" == $'cancel\t12345' ]]
}

@test "dispatch: 'twk assign 12345 luke@example.com' → cmd_assign 12345 luke@example.com" {
    run _run_dispatch assign 12345 luke@example.com
    [[ "$(_first_call)" == $'assign\t12345 luke@example.com' ]]
}

@test "dispatch: 'twk comment 12345 hi' → cmd_comment 12345 hi" {
    run _run_dispatch comment 12345 hi
    [[ "$(_first_call)" == $'comment\t12345 hi' ]]
}

@test "dispatch: 'twk adjust 12345 +30m' → cmd_adjust 12345 +30m" {
    run _run_dispatch adjust 12345 +30m
    [[ "$(_first_call)" == $'adjust\t12345 +30m' ]]
}

@test "dispatch: 'twk reset 12345 --yes' → cmd_reset 12345 --yes" {
    run _run_dispatch reset 12345 --yes
    [[ "$(_first_call)" == $'reset\t12345 --yes' ]]
}

@test "dispatch: 'twk list' → cmd_list" {
    run _run_dispatch list
    [[ "$(_first_call)" == $'list\t' ]]
}

@test "dispatch: 'twk pull' → cmd_pull" {
    run _run_dispatch pull
    [[ "$(_first_call)" == $'pull\t' ]]
}

@test "dispatch: 'twk show 12345' → cmd_show 12345" {
    run _run_dispatch show 12345
    [[ "$(_first_call)" == $'show\t12345' ]]
}

@test "dispatch: 'twk users' → cmd_users" {
    run _run_dispatch users
    [[ "$(_first_call)" == $'users\t' ]]
}

@test "dispatch: 'twk log' → cmd_log" {
    run _run_dispatch log
    [[ "$(_first_call)" == $'log\t' ]]
}

@test "dispatch: 'twk log --by-id --days=30' → cmd_log --by-id --days=30" {
    run _run_dispatch log --by-id --days=30
    [[ "$(_first_call)" == $'log\t--by-id --days=30' ]]
}

@test "dispatch: 'twk status' → cmd_status" {
    run _run_dispatch status
    [[ "$(_first_call)" == $'status\t' ]]
}

@test "dispatch: 'twk commit' → cmd_commit" {
    run _run_dispatch commit
    [[ "$(_first_call)" == $'commit\t' ]]
}

@test "dispatch: 'twk init' → cmd_init" {
    run _run_dispatch init
    [[ "$(_first_call)" == $'init\t' ]]
}

@test "dispatch: 'twk init --global' → cmd_init --global" {
    run _run_dispatch init --global
    [[ "$(_first_call)" == $'init\t--global' ]]
}

@test "dispatch: 'twk version' → prints 'twk <version>'" {
    run _run_dispatch version
    assert_status 0
    assert_output_contains "twk 0.1.0"
}

@test "dispatch: 'twk -v' → prints 'twk <version>'" {
    run _run_dispatch -v
    assert_status 0
    assert_output_contains "twk 0.1.0"
}

@test "dispatch: 'twk --version' → prints 'twk <version>'" {
    run _run_dispatch --version
    assert_status 0
    assert_output_contains "twk 0.1.0"
}

@test "dispatch: 'twk help' → prints usage" {
    run _run_dispatch help
    assert_status 0
    assert_output_contains "Usage:"
    assert_output_contains "twk init"
}

@test "dispatch: 'twk --help' → prints usage (no subcommand)" {
    run _run_dispatch --help
    assert_status 0
    assert_output_contains "Usage:"
    assert_output_contains "twk init"
}

@test "dispatch: 'twk -h' → prints usage" {
    run _run_dispatch -h
    assert_status 0
    assert_output_contains "Usage:"
}

@test "dispatch: bare 'twk' (no args) prints usage and exits 1" {
    run _run_dispatch
    assert_status 1
    assert_output_contains "Usage:"
}

@test "dispatch: unknown command prints error and exits 1" {
    run _run_dispatch totally-not-a-command
    assert_status 1
    assert_output_contains "unknown command 'totally-not-a-command'"
}

# -----------------------------------------------------------------------------
# --help flag works in any position (round-1 review issue #3).
# -----------------------------------------------------------------------------

@test "dispatch: 'twk init --help' → show_subcommand_help init (not cmd_init)" {
    run _run_dispatch init --help
    assert_status 0
    assert_output_contains "twk init"
    # cmd_init MUST NOT have been routed to.
    [[ ! -s "${TWK_BATS_TMP}/dispatch_calls.log" ]] \
        || { echo "cmd_* was incorrectly called:"; cat "${TWK_BATS_TMP}/dispatch_calls.log"; return 1; }
}

@test "dispatch: 'twk init --global --help' → show_subcommand_help init (round-1 bug)" {
    run _run_dispatch init --global --help
    assert_status 0
    assert_output_contains "twk init"
    [[ ! -s "${TWK_BATS_TMP}/dispatch_calls.log" ]]
}

@test "dispatch: 'twk start 12345 --help' → show_subcommand_help start" {
    run _run_dispatch start 12345 --help
    assert_status 0
    assert_output_contains "twk start"
    [[ ! -s "${TWK_BATS_TMP}/dispatch_calls.log" ]]
}

@test "dispatch: 'twk start --state Doing -h' → show_subcommand_help start" {
    run _run_dispatch start --state Doing -h
    assert_status 0
    assert_output_contains "twk start"
}

@test "dispatch: 'twk commit --help' → show_subcommand_help commit" {
    run _run_dispatch commit --help
    assert_status 0
    assert_output_contains "twk commit"
}

# -----------------------------------------------------------------------------
# End-to-end: bin/twk itself dispatches correctly. Skips on machines that
# lack curl/jq/bc (bin/twk's check_dependencies bails before main() runs).
# -----------------------------------------------------------------------------

@test "dispatch: bin/twk version dispatches end-to-end (real bootstrap)" {
    # Use the dispatch_bin shims we built in setup so check_dependencies
    # sees curl/jq/bc on PATH.
    require_binary python3   # bc/jq stubs need python3
    PATH="${TWK_DISPATCH_BIN}:${PATH}" \
        run "${TWK_REPO}/bin/twk" version
    assert_status 0
    assert_output_contains "twk 0.1.0"
}
