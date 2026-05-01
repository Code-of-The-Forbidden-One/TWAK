#!/usr/bin/env bats
# shellcheck disable=SC2329
#   SC2329: function overrides (config_find_local, azdo_test_connection,
#           print_banner, etc.) are invoked indirectly by the SUT.
#
# Tests for lib/config.sh — local-config walk-up, scope detection, write,
# load error path, and the protect_local gitignore matrix.
#
# config_protect_local has a complex case grid:
#   - git not on PATH                      -> emits reminder, no write
#   - PWD not in a git repo                -> reminder
#   - git worktree (.git is a file)        -> uses repo root
#   - inside subdirectory of a repo        -> uses repo root
#   - existing .gitignore without trailing newline
#   - .gitignore with `.twk/` already present
#   - .gitignore with `.twk` (no slash) already present
#   - .gitignore is a symlink              -> refuses, warns
#   - no .gitignore                        -> creates one

load 'helpers/setup.bash'
load 'helpers/mock_azdo.bash'

setup() {
    twk_setup_env
    twk_source_libs
    twk_load_stub_path
}

# -----------------------------------------------------------------------------
# config_find_local — walks from PWD up to / looking for .twk/config.
# -----------------------------------------------------------------------------

@test "config_find_local: returns path when .twk/config in PWD" {
    local proj="${TWK_BATS_TMP}/proj"
    mkdir -p "${proj}/.twk"
    : > "${proj}/.twk/config"

    cd "${proj}"
    run config_find_local
    assert_status 0
    [[ "${output}" == "${proj}/.twk/config" ]]
}

@test "config_find_local: walks up multiple levels to find .twk/config" {
    local proj="${TWK_BATS_TMP}/proj"
    mkdir -p "${proj}/.twk" "${proj}/a/b/c/d"
    : > "${proj}/.twk/config"

    cd "${proj}/a/b/c/d"
    run config_find_local
    assert_status 0
    [[ "${output}" == "${proj}/.twk/config" ]]
}

@test "config_find_local: returns rc=1 when no config anywhere up to /" {
    local proj="${TWK_BATS_TMP}/lonely"
    mkdir -p "${proj}/x/y"

    cd "${proj}/x/y"
    run config_find_local
    assert_status 1
    [[ -z "${output}" ]]
}

@test "config_find_local: handles PWD with no slashes (e.g. '/' itself) without infinite loop" {
    # We can't actually cd to / in tests, but we can simulate the boundary
    # by creating a session at the deepest reachable level and running the
    # walk against a single-component path. The bash function's behaviour
    # for dir='/' is to attempt one check and break.
    cd "${TWK_BATS_TMP}"
    run config_find_local
    assert_status 1
}

@test "config_find_local: nearer config wins over a higher-level one" {
    local outer="${TWK_BATS_TMP}/outer"
    local inner="${outer}/inner"
    mkdir -p "${outer}/.twk" "${inner}/.twk"
    : > "${outer}/.twk/config"
    : > "${inner}/.twk/config"

    cd "${inner}"
    run config_find_local
    assert_status 0
    [[ "${output}" == "${inner}/.twk/config" ]]
}

# -----------------------------------------------------------------------------
# config_active_file / config_active_scope — local wins; falls back to global.
# -----------------------------------------------------------------------------

@test "config_active_file: returns global file when no local config exists" {
    cd "${TWK_BATS_TMP}"
    run config_active_file
    assert_status 0
    [[ "${output}" == "${TWK_CONFIG_DIR}/config" ]]
}

@test "config_active_file: returns local path when one exists in walk-up" {
    local proj="${TWK_BATS_TMP}/proj"
    mkdir -p "${proj}/.twk"
    : > "${proj}/.twk/config"

    cd "${proj}"
    run config_active_file
    assert_status 0
    [[ "${output}" == "${proj}/.twk/config" ]]
}

@test "config_active_scope: 'global' when no local config" {
    cd "${TWK_BATS_TMP}"
    run config_active_scope
    [[ "${output}" == "global" ]]
}

@test "config_active_scope: 'local' when local config exists" {
    local proj="${TWK_BATS_TMP}/proj"
    mkdir -p "${proj}/.twk"
    : > "${proj}/.twk/config"

    cd "${proj}"
    run config_active_scope
    [[ "${output}" == "local" ]]
}

# -----------------------------------------------------------------------------
# config_load — error path when no config.
# -----------------------------------------------------------------------------

@test "config_load: rc=1 with helpful error when no config exists" {
    cd "${TWK_BATS_TMP}"
    run config_load
    assert_status 1
    assert_output_contains "twk not initialised"
    assert_output_contains "twk init"
}

@test "config_load: sources active config and exposes TWK_* vars" {
    twk_write_fake_config

    # Override config_find_local to short-circuit (no local config) so global
    # is picked up.
    config_find_local() { return 1; }

    # twk_write_fake_config sources the file as a side effect so the TWK_*
    # vars are already set. Unset them between the write and the load so the
    # post-load assertions actually verify config_load did the sourcing
    # itself (round-2 review #4 fix; was a tautology before).
    unset TWK_ORGANIZATION TWK_PROJECT TWK_TEAM TWK_PAT \
          TWK_TIME_FIELD_TASK TWK_TIME_FIELD_FEATURE \
          TWK_STATE_ACTIVE TWK_STATE_PAUSED TWK_STATE_DONE

    config_load
    [[ "${TWK_ORGANIZATION}" == "fakeorg" ]]
    [[ "${TWK_PROJECT}" == "FakeProject" ]]
    [[ "${TWK_PAT}" == "fakepat" ]]
}

# -----------------------------------------------------------------------------
# config_write — round-trips shell-special characters via printf %q.
# -----------------------------------------------------------------------------

@test "config_write: writes file with mode 600 in mode-700 directory" {
    local target="${TWK_BATS_TMP}/proj/.twk/config"
    config_write "${target}" "org" "proj" "team" "pat" \
        "Custom.TimeSpent" "Custom.TimeSpentFeature" \
        "Active" "Paused" "Done"

    assert_file_exists "${target}"
    local file_mode dir_mode
    file_mode="$(stat -c '%a' "${target}")"
    dir_mode="$(stat -c '%a' "$(dirname "${target}")")"
    [[ "${file_mode}" == "600" ]] || { echo "file mode: ${file_mode}" >&2; return 1; }
    [[ "${dir_mode}" == "700" ]] || { echo "dir mode: ${dir_mode}" >&2; return 1; }
}

@test "config_write: round-trips PAT with spaces, dollar, backtick, single quote" {
    # The PAT character set is opaque to twk — printf %q must survive
    # absolutely anything bash can interpret.
    local nasty_pat="abc def\$ghi\`jkl'mno\"pqr"
    local target="${TWK_BATS_TMP}/proj/.twk/config"

    config_write "${target}" "org" "proj" "team" "${nasty_pat}" \
        "f.task" "f.feature" "Active" "Paused" "Done"

    # Source it in a sub-shell to verify TWK_PAT round-trips exactly.
    local round_tripped
    round_tripped="$(bash -c "set -e; source '${target}'; printf '%s' \"\${TWK_PAT}\"")"
    [[ "${round_tripped}" == "${nasty_pat}" ]] \
        || { echo "expected: ${nasty_pat}"; echo "got:      ${round_tripped}"; return 1; }
}

@test "config_write: round-trips organization with newline and spaces" {
    # Shell-quoting must handle newlines too.
    local nasty_org=$'line1\nline2 with spaces'
    local target="${TWK_BATS_TMP}/proj/.twk/config"

    config_write "${target}" "${nasty_org}" "proj" "team" "pat" \
        "f.task" "f.feature" "Active" "Paused" "Done"

    local round_tripped
    round_tripped="$(bash -c "set -e; source '${target}'; printf '%s' \"\${TWK_ORGANIZATION}\"")"
    [[ "${round_tripped}" == "${nasty_org}" ]] \
        || { echo "round-trip failed for newline-containing org" >&2; return 1; }
}

@test "config_write: writes empty team correctly" {
    local target="${TWK_BATS_TMP}/proj/.twk/config"
    config_write "${target}" "org" "proj" "" "pat" \
        "f.task" "f.feature" "Active" "Paused" "Done"

    local round_tripped
    round_tripped="$(bash -c "set -e; source '${target}'; printf '%s' \"\${TWK_TEAM}\"")"
    [[ -z "${round_tripped}" ]]
}

# -----------------------------------------------------------------------------
# config_protect_local — the gitignore matrix.
#
# These tests exercise REAL git via `git init` in tmpdirs. We do not mock git
# because the lib uses git rev-parse directly.
# -----------------------------------------------------------------------------

@test "config_protect_local: not a git repo prints reminder, no .gitignore created" {
    require_binary git

    local proj="${TWK_BATS_TMP}/nongit"
    mkdir -p "${proj}/.twk"
    : > "${proj}/.twk/config"

    run config_protect_local "${proj}/.twk/config"
    assert_status 0
    assert_output_contains "not a git repository"
    assert_file_not_exists "${proj}/.gitignore"
}

@test "config_protect_local: git not on PATH prints reminder, doesn't crash" {
    # We can't actually unset git here without breaking bash itself in this
    # subshell. Instead, build a minimal PATH that contains the test stubs
    # plus a 'git' shim that doesn't exist (force command -v to fail) but
    # still has /usr/bin for bash/other essentials. Easiest: PATH with ONLY
    # a bin dir we control that lacks git.
    local proj="${TWK_BATS_TMP}/nogit"
    mkdir -p "${proj}/.twk"
    : > "${proj}/.twk/config"

    # Build a sandbox PATH dir: symlinks for the binaries config_protect_local
    # depends on (none, in the no-git path) plus the basic shell tools any
    # bash subshell might need. Crucially, NO git.
    local sandbox_bin="${TWK_BATS_TMP}/sandbox_bin"
    mkdir -p "${sandbox_bin}"
    local b
    for b in dirname grep tail printf; do
        if command -v "${b}" >/dev/null 2>&1; then
            ln -sf "$(command -v "${b}")" "${sandbox_bin}/${b}"
        fi
    done

    output="$(PATH="${sandbox_bin}" "${BASH}" -c "
        source '${TWK_REPO}/lib/config.sh'
        config_protect_local '${proj}/.twk/config'
    ")"
    [[ "${output}" == *"'git' is not installed"* ]] \
        || { echo "got: ${output}" >&2; return 1; }
    assert_file_not_exists "${proj}/.gitignore"
}

@test "config_protect_local: in fresh git repo creates .gitignore with .twk/ entry" {
    require_binary git

    local proj="${TWK_BATS_TMP}/repo"
    mkdir -p "${proj}/.twk"
    : > "${proj}/.twk/config"
    git -C "${proj}" init -q

    run config_protect_local "${proj}/.twk/config"
    assert_status 0
    assert_file_exists "${proj}/.gitignore"
    grep -qxF '.twk/' "${proj}/.gitignore"
    assert_output_contains "Created"
}

@test "config_protect_local: existing .gitignore without trailing newline gets a newline + entry" {
    require_binary git

    local proj="${TWK_BATS_TMP}/repo_nonewline"
    mkdir -p "${proj}/.twk"
    : > "${proj}/.twk/config"
    git -C "${proj}" init -q

    # Existing .gitignore has content but no trailing newline.
    printf 'foo' > "${proj}/.gitignore"

    run config_protect_local "${proj}/.twk/config"
    assert_status 0

    # Resulting file should have foo on line 1 and .twk/ on line 2 — exactly
    # two lines, separated cleanly.
    local lines
    lines="$(wc -l < "${proj}/.gitignore")"
    [[ "${lines}" -eq 2 ]] \
        || { echo "expected 2 lines, got ${lines}; content:"; cat "${proj}/.gitignore"; return 1; }
    grep -qxF 'foo' "${proj}/.gitignore"
    grep -qxF '.twk/' "${proj}/.gitignore"
}

@test "config_protect_local: .twk/ already in .gitignore is idempotent (no append)" {
    require_binary git

    local proj="${TWK_BATS_TMP}/repo_already"
    mkdir -p "${proj}/.twk"
    : > "${proj}/.twk/config"
    git -C "${proj}" init -q

    printf '%s\n' '.twk/' > "${proj}/.gitignore"

    run config_protect_local "${proj}/.twk/config"
    assert_status 0
    assert_output_contains "already in"

    # Should still be exactly one line.
    local lines
    lines="$(wc -l < "${proj}/.gitignore")"
    [[ "${lines}" -eq 1 ]]
}

@test "config_protect_local: .twk (no slash) already in .gitignore is recognised as equivalent" {
    require_binary git

    local proj="${TWK_BATS_TMP}/repo_noslash"
    mkdir -p "${proj}/.twk"
    : > "${proj}/.twk/config"
    git -C "${proj}" init -q

    printf '%s\n' '.twk' > "${proj}/.gitignore"

    run config_protect_local "${proj}/.twk/config"
    assert_status 0
    assert_output_contains "already in"

    # No duplicate line should be appended.
    local lines
    lines="$(wc -l < "${proj}/.gitignore")"
    [[ "${lines}" -eq 1 ]]
}

@test "config_protect_local: symlinked .gitignore is refused, target unchanged" {
    require_binary git

    local proj="${TWK_BATS_TMP}/repo_symlink"
    mkdir -p "${proj}/.twk"
    : > "${proj}/.twk/config"
    git -C "${proj}" init -q

    # Real target outside the repo, symlinked into it.
    local real_target="${TWK_BATS_TMP}/elsewhere.gitignore"
    : > "${real_target}"
    ln -s "${real_target}" "${proj}/.gitignore"

    run config_protect_local "${proj}/.twk/config"
    assert_status 0
    assert_output_contains "symlink"
    assert_output_contains "refusing"

    # Real target must NOT have been modified.
    [[ ! -s "${real_target}" ]] || { echo "target was modified" >&2; cat "${real_target}"; return 1; }
}

@test "config_protect_local: inside a git worktree (.git is a file) writes to repo root .gitignore" {
    require_binary git

    # Create a primary repo with one commit, then `git worktree add` into a
    # second checkout where .git is a file pointing back into the primary
    # repo.
    local primary="${TWK_BATS_TMP}/primary"
    git init -q "${primary}"
    git -C "${primary}" config user.email "test@example.com"
    git -C "${primary}" config user.name "test"
    git -C "${primary}" commit --allow-empty -q -m initial

    local worktree="${TWK_BATS_TMP}/wt"
    git -C "${primary}" worktree add -q -b feature "${worktree}"

    # In the worktree, .git is a *file*.
    [[ -f "${worktree}/.git" && ! -d "${worktree}/.git" ]] \
        || { echo "worktree .git not a file: $(ls -la "${worktree}/.git")" >&2; return 1; }

    mkdir -p "${worktree}/.twk"
    : > "${worktree}/.twk/config"

    run config_protect_local "${worktree}/.twk/config"
    assert_status 0
    # The function should detect the worktree as a git repo and write to its
    # repo-root .gitignore — which is the worktree itself.
    assert_file_exists "${worktree}/.gitignore"
    grep -qxF '.twk/' "${worktree}/.gitignore"
}

@test "config_protect_local: inside a subdirectory of a repo writes to repo-root .gitignore" {
    require_binary git

    local proj="${TWK_BATS_TMP}/repo_sub"
    git init -q "${proj}"
    mkdir -p "${proj}/services/api/.twk"
    : > "${proj}/services/api/.twk/config"

    # config_parent is the parent of the .twk dir = ${proj}/services/api.
    # The function should walk up to ${proj} and write the .gitignore there.
    run config_protect_local "${proj}/services/api/.twk/config"
    assert_status 0
    assert_file_exists "${proj}/.gitignore"
    grep -qxF '.twk/' "${proj}/.gitignore"

    # Crucially, no .gitignore should appear in the subdirectory.
    assert_file_not_exists "${proj}/services/api/.gitignore"
    assert_file_not_exists "${proj}/services/.gitignore"
}

@test "config_protect_local: re-running in an existing protected repo prints idempotency notice" {
    require_binary git

    local proj="${TWK_BATS_TMP}/repo_idem"
    mkdir -p "${proj}/.twk"
    : > "${proj}/.twk/config"
    git -C "${proj}" init -q

    config_protect_local "${proj}/.twk/config" >/dev/null
    run config_protect_local "${proj}/.twk/config"
    assert_status 0
    assert_output_contains "already in"

    # Still exactly one .twk/ entry.
    local count
    count="$(grep -c -xF '.twk/' "${proj}/.gitignore")"
    [[ "${count}" -eq 1 ]] || { echo "duplicate count=${count}"; cat "${proj}/.gitignore"; return 1; }
}

# -----------------------------------------------------------------------------
# Constants — readonly and stable.
# -----------------------------------------------------------------------------

@test "constants: TWK_LOCAL_CONFIG_DIR_NAME is .twk" {
    [[ "${TWK_LOCAL_CONFIG_DIR_NAME}" == ".twk" ]]
}

@test "constants: TWK_LOCAL_CONFIG_FILE_NAME is config" {
    [[ "${TWK_LOCAL_CONFIG_FILE_NAME}" == "config" ]]
}

@test "config_local_relative: returns .twk/config" {
    run config_local_relative
    [[ "${output}" == ".twk/config" ]]
}

@test "config_global_file: returns TWK_CONFIG_DIR/config" {
    run config_global_file
    [[ "${output}" == "${TWK_CONFIG_DIR}/config" ]]
}

@test "config_exists: false when no config" {
    cd "${TWK_BATS_TMP}"
    run config_exists
    assert_status 1
}

@test "config_exists: true after twk_write_fake_config" {
    twk_write_fake_config
    config_find_local() { return 1; }
    run config_exists
    assert_status 0
}

# -----------------------------------------------------------------------------
# cmd_init — interactive prompts via heredoc.
#
# Round-2 review #7: the author claimed cmd_init was "untestable". It is
# testable: `read -rsp` reads from stdin without a terminal just fine when
# fed a heredoc. We mock azdo_test_connection (so the network bail doesn't
# kick in) and config_protect_local (to keep tests focused on what cmd_init
# writes). print_banner is replaced with a no-op so the banner ASCII art
# doesn't drown the assertions.
# -----------------------------------------------------------------------------

# shellcheck disable=SC2329  # invoked indirectly by SUT
_install_cmd_init_mocks() {
    azdo_test_connection() { return 0; }
    config_protect_local()  { :; }
    print_banner()          { :; }
}

@test "cmd_init --global: writes config from heredoc-fed prompts" {
    _install_cmd_init_mocks
    config_find_local() { return 1; }

    # Fed prompts in order:
    #   organisation, project, team (blank ok), pat, time_field_task,
    #   time_field_feature (blank → defaults to task), state_active,
    #   state_paused, state_done.
    cmd_init --global <<'EOF'
myorg
MyProject

mypat
Custom.TimeSpent

Active
Paused
Done
EOF

    local config_file="${TWK_CONFIG_DIR}/config"
    assert_file_exists "${config_file}"

    # Round-trip through bash to verify each field.
    local org proj team pat tf_task tf_feature s_active s_paused s_done
    org="$(bash -c "set -e; source '${config_file}'; printf '%s' \"\${TWK_ORGANIZATION}\"")"
    proj="$(bash -c "set -e; source '${config_file}'; printf '%s' \"\${TWK_PROJECT}\"")"
    team="$(bash -c "set -e; source '${config_file}'; printf '%s' \"\${TWK_TEAM}\"")"
    pat="$(bash -c "set -e; source '${config_file}'; printf '%s' \"\${TWK_PAT}\"")"
    tf_task="$(bash -c "set -e; source '${config_file}'; printf '%s' \"\${TWK_TIME_FIELD_TASK}\"")"
    tf_feature="$(bash -c "set -e; source '${config_file}'; printf '%s' \"\${TWK_TIME_FIELD_FEATURE}\"")"
    s_active="$(bash -c "set -e; source '${config_file}'; printf '%s' \"\${TWK_STATE_ACTIVE}\"")"
    s_paused="$(bash -c "set -e; source '${config_file}'; printf '%s' \"\${TWK_STATE_PAUSED}\"")"
    s_done="$(bash -c "set -e; source '${config_file}'; printf '%s' \"\${TWK_STATE_DONE}\"")"

    [[ "${org}" == "myorg" ]]            || { echo "org=${org}" >&2; return 1; }
    [[ "${proj}" == "MyProject" ]]       || { echo "proj=${proj}" >&2; return 1; }
    [[ -z "${team}" ]]                   || { echo "team=${team}" >&2; return 1; }
    [[ "${pat}" == "mypat" ]]            || { echo "pat=${pat}" >&2; return 1; }
    [[ "${tf_task}" == "Custom.TimeSpent" ]]    || { echo "tf_task=${tf_task}" >&2; return 1; }
    # Blank time_field_feature must fall back to time_field_task.
    [[ "${tf_feature}" == "Custom.TimeSpent" ]] || { echo "tf_feature=${tf_feature}" >&2; return 1; }
    [[ "${s_active}" == "Active" ]]      || { echo "s_active=${s_active}" >&2; return 1; }
    [[ "${s_paused}" == "Paused" ]]      || { echo "s_paused=${s_paused}" >&2; return 1; }
    [[ "${s_done}" == "Done" ]]          || { echo "s_done=${s_done}" >&2; return 1; }
}

@test "cmd_init --global: empty state prompts fall back to default Active/Paused/Done" {
    _install_cmd_init_mocks
    config_find_local() { return 1; }

    # Empty-line responses for the three state prompts at the end.
    cmd_init --global <<'EOF'
myorg
MyProject

mypat
Custom.TimeSpent
Custom.FeatureTime



EOF

    local config_file="${TWK_CONFIG_DIR}/config"
    assert_file_exists "${config_file}"

    local s_active s_paused s_done
    s_active="$(bash -c "set -e; source '${config_file}'; printf '%s' \"\${TWK_STATE_ACTIVE}\"")"
    s_paused="$(bash -c "set -e; source '${config_file}'; printf '%s' \"\${TWK_STATE_PAUSED}\"")"
    s_done="$(bash -c "set -e; source '${config_file}'; printf '%s' \"\${TWK_STATE_DONE}\"")"

    [[ "${s_active}" == "Active" ]]
    [[ "${s_paused}" == "Paused" ]]
    [[ "${s_done}" == "Done" ]]
}

@test "cmd_init --global: empty organisation prompt errors and exits non-zero" {
    _install_cmd_init_mocks
    config_find_local() { return 1; }

    # First line blank → organisation validator triggers immediately.
    run cmd_init --global <<'EOF'

MyProject

mypat
Custom.TimeSpent

Active
Paused
Done
EOF
    assert_status 1
    assert_output_contains "organisation is required"
    # Config file should NOT have been written.
    assert_file_not_exists "${TWK_CONFIG_DIR}/config"
}

@test "cmd_init --global: empty project prompt errors and exits non-zero" {
    _install_cmd_init_mocks
    config_find_local() { return 1; }

    run cmd_init --global <<'EOF'
myorg


mypat
Custom.TimeSpent

Active
Paused
Done
EOF
    assert_status 1
    assert_output_contains "project is required"
    assert_file_not_exists "${TWK_CONFIG_DIR}/config"
}

@test "cmd_init --global: empty PAT prompt errors and exits non-zero" {
    _install_cmd_init_mocks
    config_find_local() { return 1; }

    # Blank PAT (empty line after Team).
    run cmd_init --global <<'EOF'
myorg
MyProject


Custom.TimeSpent

Active
Paused
Done
EOF
    assert_status 1
    assert_output_contains "personal access token is required"
    assert_file_not_exists "${TWK_CONFIG_DIR}/config"
}

@test "cmd_init --global: empty task time field errors and exits non-zero" {
    _install_cmd_init_mocks
    config_find_local() { return 1; }

    run cmd_init --global <<'EOF'
myorg
MyProject

mypat


Active
Paused
Done
EOF
    assert_status 1
    assert_output_contains "task time field is required"
    assert_file_not_exists "${TWK_CONFIG_DIR}/config"
}

@test "cmd_init: rejects unknown args" {
    _install_cmd_init_mocks
    run cmd_init --global --bogus
    assert_status 1
    assert_output_contains "unknown argument '--bogus'"
}
