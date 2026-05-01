#!/usr/bin/env bats
# Tests for lib/help.sh — the help-text dispatcher and the --help flag scanner.

load 'helpers/setup.bash'

setup() {
    twk_setup_env
    twk_source_libs
}

# -----------------------------------------------------------------------------
# contains_help_flag — must detect --help/-h in any argv position, including
# none (return non-zero on empty argv).
# -----------------------------------------------------------------------------

@test "contains_help_flag: empty argv returns non-zero" {
    run contains_help_flag
    assert_status 1
}

@test "contains_help_flag: --help in first position" {
    run contains_help_flag --help
    assert_status 0
}

@test "contains_help_flag: -h in first position" {
    run contains_help_flag -h
    assert_status 0
}

@test "contains_help_flag: --help in last position after positional args" {
    run contains_help_flag init --global --help
    assert_status 0
}

@test "contains_help_flag: -h in middle position" {
    run contains_help_flag start 12345 -h --state Doing
    assert_status 0
}

@test "contains_help_flag: returns non-zero when no help flag present" {
    run contains_help_flag init --global
    assert_status 1
}

@test "contains_help_flag: doesn't match --helper or -help (only exact tokens)" {
    run contains_help_flag --helper -help
    assert_status 1
}

# -----------------------------------------------------------------------------
# show_subcommand_help — emits a help block for each known subcommand.
# We don't pin the exact text (it's prose) but we assert it (a) returns 0,
# (b) prints something non-empty, and (c) mentions the subcommand name.
# -----------------------------------------------------------------------------

@test "show_subcommand_help: init prints help block" {
    run show_subcommand_help init
    assert_status 0
    assert_output_contains "twk init"
    assert_output_contains "--global"
}

@test "show_subcommand_help: start mentions interactive picker behaviour" {
    run show_subcommand_help start
    assert_status 0
    assert_output_contains "twk start"
    assert_output_contains "interactive picker"
}

@test "show_subcommand_help: pause" {
    run show_subcommand_help pause
    assert_status 0
    assert_output_contains "twk pause"
}

@test "show_subcommand_help: end" {
    run show_subcommand_help end
    assert_status 0
    assert_output_contains "twk end"
}

@test "show_subcommand_help: done" {
    # shellcheck disable=SC1010  # 'done' here is a literal argument, not a keyword
    run show_subcommand_help done
    assert_status 0
    assert_output_contains "twk done"
}

@test "show_subcommand_help: undo" {
    run show_subcommand_help undo
    assert_status 0
    assert_output_contains "twk undo"
}

@test "show_subcommand_help: cancel" {
    run show_subcommand_help cancel
    assert_status 0
    assert_output_contains "twk cancel"
    assert_output_contains "cancelled"
}

@test "show_subcommand_help: status" {
    run show_subcommand_help status
    assert_status 0
    assert_output_contains "twk status"
}

@test "show_subcommand_help: commit" {
    run show_subcommand_help commit
    assert_status 0
    assert_output_contains "twk commit"
}

@test "show_subcommand_help: unknown subcommand returns non-zero with error" {
    run show_subcommand_help bogus_xyz
    assert_status 1
    assert_output_contains "No help available"
}

# -----------------------------------------------------------------------------
# print_banner — round-2 review #8: trivially testable, must not be empty.
# -----------------------------------------------------------------------------

@test "print_banner: returns 0" {
    run print_banner
    assert_status 0
}

@test "print_banner: emits non-empty multiline banner (>= 5 lines)" {
    run print_banner
    assert_status 0
    local line_count
    line_count="$(printf '%s\n' "${output}" | wc -l)"
    [[ "${line_count}" -ge 5 ]] \
        || { echo "expected >= 5 lines, got ${line_count}; output:"; echo "${output}"; return 1; }
}
