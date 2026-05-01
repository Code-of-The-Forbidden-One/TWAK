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

@test "normalise_description: strips HTML tags and collapses whitespace" {
    run normalise_description "<div>Hello   world</div><br>second line"
    assert_status 0
    [[ "${output}" == "Hello world second line" ]] || { echo "got: ${output}"; return 1; }
}

@test "normalise_description: decodes common HTML entities" {
    run normalise_description "Tom &amp; Jerry &lt;span&gt; &quot;ok&quot;"
    assert_status 0
    [[ "${output}" == 'Tom & Jerry <span> "ok"' ]] || { echo "got: ${output}"; return 1; }
}

@test "normalise_description: empty input returns '(no description)'" {
    run normalise_description ""
    assert_status 0
    [[ "${output}" == "(no description)" ]] || { echo "got: ${output}"; return 1; }
}

@test "normalise_description: tag-only input collapses to '(no description)'" {
    run normalise_description "<div></div><br>"
    assert_status 0
    [[ "${output}" == "(no description)" ]] || { echo "got: ${output}"; return 1; }
}

@test "normalise_description: long input truncates with '...' suffix" {
    local long
    long="$(printf 'a%.0s' $(seq 1 300))"
    run normalise_description "${long}"
    assert_status 0
    # First 240 chars of input + 3-char suffix.
    [[ "${#output}" -eq 243 ]] || { echo "len=${#output}"; return 1; }
    [[ "${output}" == *"..." ]] || { echo "no ... suffix"; return 1; }
}

@test "normalise_description: max_len 0 disables truncation" {
    local long
    long="$(printf 'a%.0s' $(seq 1 500))"
    run normalise_description "${long}" 0
    assert_status 0
    [[ "${#output}" -eq 500 ]] || { echo "len=${#output}"; return 1; }
    [[ "${output}" != *"..." ]] || { echo "should not have truncation suffix"; return 1; }
}

@test "normalise_description: explicit max_len takes precedence over default" {
    local long
    long="$(printf 'a%.0s' $(seq 1 200))"
    run normalise_description "${long}" 50
    assert_status 0
    # 50 chars + '...'
    [[ "${#output}" -eq 53 ]] || { echo "len=${#output}"; return 1; }
}

@test "render_list_item: summary row has ID, title, state, priority, est, done, assigned" {
    require_binary jq

    export TWK_TIME_FIELD_TASK="Custom.TaskTime"
    export TWK_TIME_FIELD_FEATURE="Custom.FeatureTime"

    local item='{"id":42,"fields":{
        "System.Title":"Login bug",
        "System.WorkItemType":"Task",
        "System.State":"Active",
        "System.Description":"<p>Fix the login</p>",
        "System.AssignedTo":{"displayName":"Luke McCann","uniqueName":"luke@example.com"},
        "Microsoft.VSTS.Common.Priority":2,
        "Microsoft.VSTS.Scheduling.OriginalEstimate":4.5,
        "Custom.TaskTime":1.25
    }}'

    run render_list_item "${item}"
    assert_status 0

    # Summary row is the first line.
    local first_line
    first_line="$(printf '%s\n' "${output}" | head -n1)"
    [[ "${first_line}" == *"#42"* ]]          || { echo "no ID: ${first_line}"; return 1; }
    [[ "${first_line}" == *"Login bug"* ]]    || { echo "no title: ${first_line}"; return 1; }
    [[ "${first_line}" == *"Active"* ]]       || { echo "no state: ${first_line}"; return 1; }
    [[ "${first_line}" == *"4.5h"* ]]         || { echo "no est: ${first_line}"; return 1; }
    [[ "${first_line}" == *"1.25h"* ]]        || { echo "no done: ${first_line}"; return 1; }
    [[ "${first_line}" == *"Luke McCann"* ]]  || { echo "no assignee: ${first_line}"; return 1; }

    # Description is on a subsequent line, indented.
    [[ "${first_line}" != *"Fix the login"* ]] || { echo "desc on row: ${first_line}"; return 1; }
    assert_output_contains "Fix the login"
}

@test "render_list_item: unassigned items render '-' in assigned column" {
    require_binary jq

    export TWK_TIME_FIELD_TASK="Custom.TaskTime"
    export TWK_TIME_FIELD_FEATURE="Custom.FeatureTime"

    local item='{"id":70,"fields":{
        "System.Title":"Orphan",
        "System.WorkItemType":"Task",
        "System.State":"New"
    }}'

    run render_list_item "${item}"
    assert_status 0
    local first_line
    first_line="$(printf '%s\n' "${output}" | head -n1)"
    # Last visible token in the row should include a '-' for assigned.
    # We already test missing pri/est/done elsewhere — here we specifically
    # confirm the row doesn't contain a stray name.
    [[ "${first_line}" != *"@"* ]] || { echo "row contains @: ${first_line}"; return 1; }
    [[ "${first_line}" == *"-"* ]] || { echo "no - placeholder: ${first_line}"; return 1; }
}

@test "render_list_item: long assignee name truncates at LIST_ASSIGNED_WIDTH with '...'" {
    require_binary jq

    export TWK_TIME_FIELD_TASK="Custom.TaskTime"
    export TWK_TIME_FIELD_FEATURE="Custom.FeatureTime"

    local item='{"id":71,"fields":{
        "System.Title":"With long owner",
        "System.WorkItemType":"Task",
        "System.State":"Active",
        "System.AssignedTo":{"displayName":"Maximilian Bartholomew Cunningham"}
    }}'

    run render_list_item "${item}"
    assert_status 0
    local first_line
    first_line="$(printf '%s\n' "${output}" | head -n1)"
    [[ "${first_line}" == *"Maximilian"* ]]               || { echo "no head: ${first_line}"; return 1; }
    [[ "${first_line}" == *"..."* ]]                       || { echo "no truncation: ${first_line}"; return 1; }
    [[ "${first_line}" != *"Cunningham"* ]]                || { echo "tail not truncated: ${first_line}"; return 1; }
}

@test "render_list_item: missing priority/estimate/time render as '-'" {
    require_binary jq

    export TWK_TIME_FIELD_TASK="Custom.TaskTime"
    export TWK_TIME_FIELD_FEATURE="Custom.FeatureTime"

    local item='{"id":99,"fields":{
        "System.Title":"Bare item",
        "System.WorkItemType":"Task",
        "System.State":"New"
    }}'

    run render_list_item "${item}"
    assert_status 0

    local first_line
    first_line="$(printf '%s\n' "${output}" | head -n1)"
    # Three '-' placeholders should appear in the summary row (Pri, Est, Done).
    local dash_count
    dash_count="$(grep -o -- '-' <<< "${first_line}" | wc -l)"
    [[ "${dash_count}" -ge 3 ]] || { echo "got ${dash_count} dashes in: ${first_line}"; return 1; }

    assert_output_contains "(no description)"
}

@test "render_list_item: Feature uses the feature time field for Done" {
    require_binary jq

    export TWK_TIME_FIELD_TASK="Custom.TaskTime"
    export TWK_TIME_FIELD_FEATURE="Custom.FeatureTime"

    local item='{"id":101,"fields":{
        "System.Title":"Big feature",
        "System.WorkItemType":"Feature",
        "System.State":"Active",
        "Custom.TaskTime":99,
        "Custom.FeatureTime":12.5
    }}'

    run render_list_item "${item}"
    assert_status 0
    assert_output_contains "12.5h"
    [[ "${output}" != *"99h"* ]] || { echo "should not have used task field; got: ${output}"; return 1; }
}

@test "render_list_item: long title truncates to 40 chars with '...' in summary row" {
    require_binary jq

    export TWK_TIME_FIELD_TASK="Custom.TaskTime"
    export TWK_TIME_FIELD_FEATURE="Custom.FeatureTime"

    local item='{"id":50,"fields":{
        "System.Title":"This is an exceedingly long work item title that overflows the column",
        "System.WorkItemType":"Task",
        "System.State":"New"
    }}'

    run render_list_item "${item}"
    assert_status 0
    local first_line
    first_line="$(printf '%s\n' "${output}" | head -n1)"
    # Title truncated to first 37 chars + "..."
    [[ "${first_line}" == *"This is an exceedingly long work item"* ]] || { echo "got: ${first_line}"; return 1; }
    [[ "${first_line}" == *"..."* ]] || { echo "no truncation suffix: ${first_line}"; return 1; }
    [[ "${first_line}" != *"overflows the column"* ]] || { echo "title not truncated: ${first_line}"; return 1; }
}

@test "render_list_item: description is indented under the summary row" {
    require_binary jq

    export TWK_TIME_FIELD_TASK="Custom.TaskTime"
    export TWK_TIME_FIELD_FEATURE="Custom.FeatureTime"

    local item='{"id":60,"fields":{
        "System.Title":"With description",
        "System.WorkItemType":"Task",
        "System.State":"Active",
        "System.Description":"Sub-line content here."
    }}'

    run render_list_item "${item}"
    assert_status 0
    # Second line should start with 11 leading spaces (LIST_DESC_INDENT).
    local second_line
    second_line="$(printf '%s\n' "${output}" | sed -n '2p')"
    [[ "${second_line}" == "           Sub-line content here." ]] || { echo "got: '${second_line}'"; return 1; }
}

@test "cmd_list: rejects extra arguments" {
    twk_write_fake_config
    config_global_file() { printf '%s\n' "${TWK_CONFIG_DIR}/config"; }
    config_find_local() { return 1; }

    run cmd_list extra
    assert_status 1
    assert_output_contains "takes no arguments"
}

@test "cmd_list: errors when no current iteration" {
    twk_write_fake_config
    config_global_file() { printf '%s\n' "${TWK_CONFIG_DIR}/config"; }
    config_find_local() { return 1; }

    azdo_fetch_current_iteration() { printf '%s' '{"value":[]}'; }

    run cmd_list
    assert_status 1
    assert_output_contains "no current iteration"
}

@test "cmd_list: prints 'No work items' when iteration has no items" {
    twk_write_fake_config
    config_global_file() { printf '%s\n' "${TWK_CONFIG_DIR}/config"; }
    config_find_local() { return 1; }

    azdo_fetch_current_iteration() {
        printf '%s' '{"value":[{"id":"abc","name":"Sprint 1"}]}'
    }
    azdo_fetch_iteration_work_items() {
        printf '%s' '{"workItemRelations":[]}'
    }

    run cmd_list
    assert_status 0
    assert_output_contains "Sprint 1"
    assert_output_contains "No work items in current sprint."
}

@test "cmd_list: renders header row, items, rule lines, and trailing count" {
    require_binary jq

    twk_write_fake_config
    config_global_file() { printf '%s\n' "${TWK_CONFIG_DIR}/config"; }
    config_find_local() { return 1; }

    export TWK_TIME_FIELD_TASK="Custom.TaskTime"
    export TWK_TIME_FIELD_FEATURE="Custom.FeatureTime"

    azdo_fetch_current_iteration() {
        printf '%s' '{"value":[{"id":"iter-1","name":"Sprint 23"}]}'
    }
    azdo_fetch_iteration_work_items() {
        printf '%s' '{"workItemRelations":[
            {"target":{"id":1}},
            {"target":{"id":2}}
        ]}'
    }
    azdo_fetch_sprint_with_details() {
        printf '%s' '{"value":[
            {"id":1,"fields":{"System.Title":"First","System.WorkItemType":"Task","System.State":"Active","System.AssignedTo":{"displayName":"Alice"},"Microsoft.VSTS.Common.Priority":1,"Microsoft.VSTS.Scheduling.OriginalEstimate":2,"Custom.TaskTime":0.5,"System.Description":"alpha"}},
            {"id":2,"fields":{"System.Title":"Second","System.WorkItemType":"Bug","System.State":"New","System.Description":"<b>bravo</b>"}}
        ]}'
    }

    run cmd_list
    assert_status 0
    assert_output_contains "Sprint 23"
    # Table header columns appear.
    assert_output_contains "ID"
    assert_output_contains "Title"
    assert_output_contains "State"
    assert_output_contains "Pri"
    assert_output_contains "Est"
    assert_output_contains "Done"
    assert_output_contains "Assigned"
    # Rule line uses the box-drawing dash.
    assert_output_contains "─"
    # Items render.
    assert_output_contains "#1"
    assert_output_contains "First"
    assert_output_contains "alpha"
    assert_output_contains "Alice"
    assert_output_contains "#2"
    assert_output_contains "Second"
    assert_output_contains "bravo"
    assert_output_contains "(2 items in sprint)"
}

@test "cmd_list: trailing count uses singular for one item" {
    require_binary jq

    twk_write_fake_config
    config_global_file() { printf '%s\n' "${TWK_CONFIG_DIR}/config"; }
    config_find_local() { return 1; }

    azdo_fetch_current_iteration() {
        printf '%s' '{"value":[{"id":"iter-1","name":"Sprint 23"}]}'
    }
    azdo_fetch_iteration_work_items() {
        printf '%s' '{"workItemRelations":[{"target":{"id":1}}]}'
    }
    azdo_fetch_sprint_with_details() {
        printf '%s' '{"value":[{"id":1,"fields":{"System.Title":"Solo","System.WorkItemType":"Task","System.State":"New"}}]}'
    }

    run cmd_list
    assert_status 0
    assert_output_contains "(1 item in sprint)"
    [[ "${output}" != *"items in sprint"* ]] || { echo "should be singular; got: ${output}"; return 1; }
}

@test "twk_pager: passes through stdin to stdout when stdout is not a tty" {
    # In bats, run captures via pipe, so [[ -t 1 ]] is false → cat path.
    run bash -c 'source /home/lukemccann/Projects/TWAK/lib/display.sh; printf "hello\nworld\n" | twk_pager'
    assert_status 0
    [[ "${output}" == "hello"$'\n'"world" ]] || { echo "got: ${output}"; return 1; }
}

@test "twk_pager_cmd: returns 'less -FRX' when less is on PATH and PAGER unset" {
    unset PAGER TWK_NO_PAGER
    if ! command -v less &> /dev/null; then
        skip "less not installed in this environment"
    fi
    run twk_pager_cmd
    assert_status 0
    [[ "${output}" == "less -FRX" ]] || { echo "got: ${output}"; return 1; }
}

@test "twk_pager_cmd: returns empty when less is missing and PAGER unset" {
    unset PAGER TWK_NO_PAGER
    # Override `command` to make less appear absent.
    command() {
        if [[ "${1:-}" == "-v" ]] && [[ "${2:-}" == "less" ]]; then
            return 1
        fi
        builtin command "$@"
    }
    run twk_pager_cmd
    assert_status 0
    [[ -z "${output}" ]] || { echo "expected empty (cat fallback), got: ${output}"; return 1; }
}

@test "twk_pager_cmd: returns the user's PAGER value verbatim" {
    PAGER="more" run twk_pager_cmd
    assert_status 0
    [[ "${output}" == "more" ]] || { echo "got: ${output}"; return 1; }
}

@test "twk_pager_cmd: empty PAGER stays empty (explicit no-pager)" {
    PAGER="" run twk_pager_cmd
    assert_status 0
    [[ -z "${output}" ]] || { echo "got: ${output}"; return 1; }
}

@test "twk_pager_cmd: TWK_NO_PAGER returns empty regardless of PAGER" {
    PAGER="less" TWK_NO_PAGER=1 run twk_pager_cmd
    assert_status 0
    [[ -z "${output}" ]] || { echo "got: ${output}"; return 1; }
}

@test "cmd_list -i: errors when fzf is not on PATH" {
    require_binary jq
    twk_write_fake_config
    config_global_file() { printf '%s\n' "${TWK_CONFIG_DIR}/config"; }
    config_find_local() { return 1; }

    azdo_fetch_current_iteration() {
        printf '%s' '{"value":[{"id":"iter-1","name":"Sprint 23"}]}'
    }
    azdo_fetch_iteration_work_items() {
        printf '%s' '{"workItemRelations":[{"target":{"id":1}}]}'
    }
    azdo_fetch_sprint_with_details() {
        printf '%s' '{"value":[{"id":1,"fields":{"System.Title":"Solo","System.WorkItemType":"Task","System.State":"New"}}]}'
    }

    # twk_hide_fzf is already active via twk_setup_env, so command -v fzf
    # returns non-zero. The interactive path should detect this and error.
    run cmd_list -i
    assert_status 1
    assert_output_contains "requires fzf"
}

@test "cmd_list: rejects unknown arguments" {
    twk_write_fake_config
    config_global_file() { printf '%s\n' "${TWK_CONFIG_DIR}/config"; }
    config_find_local() { return 1; }

    run cmd_list --bogus
    assert_status 1
    assert_output_contains "unknown argument"
    assert_output_contains "Usage: twk list"
}

@test "render_list_row: emits the summary row only (no description sub-line)" {
    require_binary jq

    export TWK_TIME_FIELD_TASK="Custom.TaskTime"
    export TWK_TIME_FIELD_FEATURE="Custom.FeatureTime"

    local item='{"id":80,"fields":{
        "System.Title":"Row only",
        "System.WorkItemType":"Task",
        "System.State":"Active",
        "System.Description":"Should not appear"
    }}'

    run render_list_row "${item}"
    assert_status 0
    assert_output_contains "#80"
    assert_output_contains "Row only"
    [[ "${output}" != *"Should not appear"* ]] || { echo "row leaked description: ${output}"; return 1; }
    # Single line of output (no description sub-line).
    local line_count
    line_count="$(printf '%s\n' "${output}" | wc -l)"
    [[ "${line_count}" -eq 1 ]] || { echo "got ${line_count} lines"; return 1; }
}

@test "render_show_item: prints labelled block with all fields" {
    require_binary jq

    export TWK_TIME_FIELD_TASK="Custom.TaskTime"
    export TWK_TIME_FIELD_FEATURE="Custom.FeatureTime"

    local item='{"id":48210,"fields":{
        "System.Title":"Implement login button",
        "System.WorkItemType":"Task",
        "System.State":"Active",
        "System.Description":"<p>OAuth2 with PKCE flow.</p>",
        "System.AssignedTo":{"displayName":"Luke McCann"},
        "System.IterationPath":"Platform\\Sprint 23",
        "Microsoft.VSTS.Common.Priority":2,
        "Microsoft.VSTS.Scheduling.OriginalEstimate":8,
        "Custom.TaskTime":2.5
    }}'

    run render_show_item "${item}"
    assert_status 0
    assert_output_contains "#48210"
    assert_output_contains "Implement login button"
    assert_output_contains "Type:       Task"
    assert_output_contains "State:      Active"
    assert_output_contains "Priority:   2"
    assert_output_contains "Assigned:   Luke McCann"
    assert_output_contains "Estimate:   8h"
    assert_output_contains "Done:       2.5h"
    assert_output_contains "Iteration:"
    assert_output_contains "Sprint 23"
    assert_output_contains "Description:"
    assert_output_contains "OAuth2 with PKCE flow."
}

@test "render_show_item: missing fields render as '-' or '(no description)'" {
    require_binary jq

    export TWK_TIME_FIELD_TASK="Custom.TaskTime"
    export TWK_TIME_FIELD_FEATURE="Custom.FeatureTime"

    local item='{"id":99,"fields":{
        "System.Title":"Sparse",
        "System.WorkItemType":"Task",
        "System.State":"New"
    }}'

    run render_show_item "${item}"
    assert_status 0
    assert_output_contains "Priority:   -"
    assert_output_contains "Assigned:   -"
    assert_output_contains "Estimate:   -"
    assert_output_contains "Done:       -"
    assert_output_contains "Iteration:  -"
    assert_output_contains "(no description)"
}

@test "render_show_item: long description renders untruncated" {
    require_binary jq

    export TWK_TIME_FIELD_TASK="Custom.TaskTime"
    export TWK_TIME_FIELD_FEATURE="Custom.FeatureTime"

    local long
    long="$(printf 'x%.0s' $(seq 1 600))"

    local item
    item="$(jq -nc --arg desc "${long}" '{
        id: 1,
        fields: {
            "System.Title": "Long",
            "System.WorkItemType": "Task",
            "System.State": "Active",
            "System.Description": $desc
        }
    }')"

    run render_show_item "${item}"
    assert_status 0
    # No truncation marker should appear in the description.
    [[ "${output}" != *"..."* ]] || { echo "unexpected truncation in show output"; return 1; }
    # All 600 chars of x's are present (across wrapped lines).
    local x_count
    x_count="$(grep -o 'x' <<< "${output}" | wc -l)"
    [[ "${x_count}" -eq 600 ]] || { echo "got ${x_count} x's"; return 1; }
}

@test "cmd_show: errors when work item fetch fails" {
    twk_write_fake_config
    config_global_file() { printf '%s\n' "${TWK_CONFIG_DIR}/config"; }
    config_find_local() { return 1; }

    azdo_fetch_work_item() { return 1; }

    run cmd_show 12345
    assert_status 1
    assert_output_contains "failed to fetch work item #12345"
}

@test "cmd_show: routes a numeric ID through to render_show_item" {
    require_binary jq
    twk_write_fake_config
    config_global_file() { printf '%s\n' "${TWK_CONFIG_DIR}/config"; }
    config_find_local() { return 1; }

    export TWK_TIME_FIELD_TASK="Custom.TaskTime"
    export TWK_TIME_FIELD_FEATURE="Custom.FeatureTime"

    azdo_fetch_work_item() {
        printf '%s' '{"id":4242,"fields":{"System.Title":"Routed","System.WorkItemType":"Task","System.State":"Active"}}'
    }

    run cmd_show 4242
    assert_status 0
    assert_output_contains "#4242"
    assert_output_contains "Routed"
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
