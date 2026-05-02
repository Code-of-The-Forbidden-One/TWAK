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

@test "parse_duration: rejects empty input" {
    run parse_duration ""
    assert_status 1
}

@test "parse_duration: parses pure hours" {
    run parse_duration "1h"
    assert_status 0
    [[ "${output}" == "3600" ]] || { echo "got: ${output}"; return 1; }
}

@test "parse_duration: parses pure minutes" {
    run parse_duration "30m"
    assert_status 0
    [[ "${output}" == "1800" ]] || { echo "got: ${output}"; return 1; }
}

@test "parse_duration: parses pure seconds" {
    run parse_duration "45s"
    assert_status 0
    [[ "${output}" == "45" ]] || { echo "got: ${output}"; return 1; }
}

@test "parse_duration: parses h+m combination" {
    run parse_duration "1h30m"
    assert_status 0
    [[ "${output}" == "5400" ]] || { echo "got: ${output}"; return 1; }
}

@test "parse_duration: parses full h+m+s combination" {
    run parse_duration "1h30m45s"
    assert_status 0
    [[ "${output}" == "5445" ]] || { echo "got: ${output}"; return 1; }
}

@test "parse_duration: parses decimal hours" {
    require_binary bc
    run parse_duration "2.5h"
    assert_status 0
    [[ "${output}" == "9000" ]] || { echo "got: ${output}"; return 1; }
}

@test "parse_duration: rejects bare numbers" {
    run parse_duration "30"
    assert_status 1
}

@test "parse_duration: rejects unknown suffix" {
    run parse_duration "1d"
    assert_status 1
}

@test "parse_duration: rejects gibberish" {
    run parse_duration "abc"
    assert_status 1
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

@test "cmd_list --sort: rejects unknown column with helpful message" {
    twk_write_fake_config
    config_global_file() { printf '%s\n' "${TWK_CONFIG_DIR}/config"; }
    config_find_local() { return 1; }

    run cmd_list --sort=bogus
    assert_status 1
    assert_output_contains "unknown sort column 'bogus'"
    assert_output_contains "Valid: id, title, state, pri, est, done, assigned"
}

@test "cmd_list --sort: rejects bare flag with no column" {
    twk_write_fake_config
    config_global_file() { printf '%s\n' "${TWK_CONFIG_DIR}/config"; }
    config_find_local() { return 1; }

    run cmd_list --sort=
    assert_status 1
    assert_output_contains "--sort requires a column name"
}

@test "sort_list_items: ascending by id" {
    require_binary jq

    export TWK_TIME_FIELD_TASK="Custom.TaskTime"
    export TWK_TIME_FIELD_FEATURE="Custom.FeatureTime"

    local batch='{"value":[
        {"id":3,"fields":{}},
        {"id":1,"fields":{}},
        {"id":2,"fields":{}}
    ]}'

    run sort_list_items "${batch}" "id" false
    assert_status 0
    local ids
    ids="$(printf '%s' "${output}" | jq -r '[.value[].id] | join(",")')"
    [[ "${ids}" == "1,2,3" ]] || { echo "got: ${ids}"; return 1; }
}

@test "sort_list_items: descending by id" {
    require_binary jq

    export TWK_TIME_FIELD_TASK="Custom.TaskTime"
    export TWK_TIME_FIELD_FEATURE="Custom.FeatureTime"

    local batch='{"value":[
        {"id":1,"fields":{}},
        {"id":3,"fields":{}},
        {"id":2,"fields":{}}
    ]}'

    run sort_list_items "${batch}" "id" true
    assert_status 0
    local ids
    ids="$(printf '%s' "${output}" | jq -r '[.value[].id] | join(",")')"
    [[ "${ids}" == "3,2,1" ]] || { echo "got: ${ids}"; return 1; }
}

@test "sort_list_items: by priority puts missing-pri items at the end" {
    require_binary jq

    export TWK_TIME_FIELD_TASK="Custom.TaskTime"
    export TWK_TIME_FIELD_FEATURE="Custom.FeatureTime"

    local batch='{"value":[
        {"id":1,"fields":{"Microsoft.VSTS.Common.Priority":3}},
        {"id":2,"fields":{}},
        {"id":3,"fields":{"Microsoft.VSTS.Common.Priority":1}},
        {"id":4,"fields":{"Microsoft.VSTS.Common.Priority":2}}
    ]}'

    run sort_list_items "${batch}" "pri" false
    assert_status 0
    local ids
    ids="$(printf '%s' "${output}" | jq -r '[.value[].id] | join(",")')"
    # Order: pri=1 (id 3), pri=2 (id 4), pri=3 (id 1), no pri (id 2 → sentinel 999 → last)
    [[ "${ids}" == "3,4,1,2" ]] || { echo "got: ${ids}"; return 1; }
}

@test "sort_list_items: by assigned uses displayName, missing → end" {
    require_binary jq

    export TWK_TIME_FIELD_TASK="Custom.TaskTime"
    export TWK_TIME_FIELD_FEATURE="Custom.FeatureTime"

    local batch='{"value":[
        {"id":1,"fields":{"System.AssignedTo":{"displayName":"Charlie"}}},
        {"id":2,"fields":{}},
        {"id":3,"fields":{"System.AssignedTo":{"displayName":"Alice"}}},
        {"id":4,"fields":{"System.AssignedTo":{"displayName":"Bob"}}}
    ]}'

    run sort_list_items "${batch}" "assigned" false
    assert_status 0
    local ids
    ids="$(printf '%s' "${output}" | jq -r '[.value[].id] | join(",")')"
    # Alice(3), Bob(4), Charlie(1), unassigned(2 → "zzz" sentinel)
    [[ "${ids}" == "3,4,1,2" ]] || { echo "got: ${ids}"; return 1; }
}

@test "sort_list_items: by state ascending is alphabetical" {
    require_binary jq

    export TWK_TIME_FIELD_TASK="Custom.TaskTime"
    export TWK_TIME_FIELD_FEATURE="Custom.FeatureTime"

    local batch='{"value":[
        {"id":1,"fields":{"System.State":"New"}},
        {"id":2,"fields":{"System.State":"Active"}},
        {"id":3,"fields":{"System.State":"Done"}},
        {"id":4,"fields":{"System.State":"Doing"}}
    ]}'

    run sort_list_items "${batch}" "state" false
    assert_status 0
    local ids
    ids="$(printf '%s' "${output}" | jq -r '[.value[].id] | join(",")')"
    # Active(2), Doing(4), Done(3), New(1)
    [[ "${ids}" == "2,4,3,1" ]] || { echo "got: ${ids}"; return 1; }
}

@test "sort_list_items: by done dispatches per-type (Task vs Feature)" {
    require_binary jq

    export TWK_TIME_FIELD_TASK="Custom.TaskTime"
    export TWK_TIME_FIELD_FEATURE="Custom.FeatureTime"

    local batch='{"value":[
        {"id":1,"fields":{"System.WorkItemType":"Task","Custom.TaskTime":3.0}},
        {"id":2,"fields":{"System.WorkItemType":"Feature","Custom.FeatureTime":1.0}},
        {"id":3,"fields":{"System.WorkItemType":"Task","Custom.TaskTime":2.0}}
    ]}'

    run sort_list_items "${batch}" "done" false
    assert_status 0
    local ids
    ids="$(printf '%s' "${output}" | jq -r '[.value[].id] | join(",")')"
    # 1.0 (feature, id 2), 2.0 (task, id 3), 3.0 (task, id 1)
    [[ "${ids}" == "2,3,1" ]] || { echo "got: ${ids}"; return 1; }
}

@test "cmd_list --sort: end-to-end happy path applies the sort to rendered rows" {
    require_binary jq
    twk_write_fake_config
    config_global_file() { printf '%s\n' "${TWK_CONFIG_DIR}/config"; }
    config_find_local() { return 1; }

    azdo_fetch_current_iteration() {
        printf '%s' '{"value":[{"id":"iter-1","name":"Sprint 23"}]}'
    }
    azdo_fetch_iteration_work_items() {
        printf '%s' '{"workItemRelations":[
            {"target":{"id":1}},
            {"target":{"id":2}},
            {"target":{"id":3}}
        ]}'
    }
    azdo_fetch_sprint_with_details() {
        printf '%s' '{"value":[
            {"id":3,"fields":{"System.Title":"Charlie","System.WorkItemType":"Task","System.State":"Active","Microsoft.VSTS.Common.Priority":3}},
            {"id":1,"fields":{"System.Title":"Alpha","System.WorkItemType":"Task","System.State":"New","Microsoft.VSTS.Common.Priority":1}},
            {"id":2,"fields":{"System.Title":"Bravo","System.WorkItemType":"Task","System.State":"Doing","Microsoft.VSTS.Common.Priority":2}}
        ]}'
    }

    run cmd_list --sort=pri
    assert_status 0
    # Verify Alpha (pri 1) appears before Bravo (pri 2) before Charlie (pri 3) in the rendered output.
    local alpha_pos bravo_pos charlie_pos
    alpha_pos="$(grep -n "Alpha" <<< "${output}" | head -1 | cut -d: -f1)"
    bravo_pos="$(grep -n "Bravo" <<< "${output}" | head -1 | cut -d: -f1)"
    charlie_pos="$(grep -n "Charlie" <<< "${output}" | head -1 | cut -d: -f1)"
    [[ "${alpha_pos}" -lt "${bravo_pos}" ]] || { echo "Alpha not before Bravo"; return 1; }
    [[ "${bravo_pos}" -lt "${charlie_pos}" ]] || { echo "Bravo not before Charlie"; return 1; }
}

@test "cmd_list --sort: descending prefix '-' reverses the order" {
    require_binary jq
    twk_write_fake_config
    config_global_file() { printf '%s\n' "${TWK_CONFIG_DIR}/config"; }
    config_find_local() { return 1; }

    azdo_fetch_current_iteration() {
        printf '%s' '{"value":[{"id":"iter-1","name":"Sprint 23"}]}'
    }
    azdo_fetch_iteration_work_items() {
        printf '%s' '{"workItemRelations":[{"target":{"id":1}},{"target":{"id":2}}]}'
    }
    azdo_fetch_sprint_with_details() {
        printf '%s' '{"value":[
            {"id":1,"fields":{"System.Title":"Alpha","System.WorkItemType":"Task","System.State":"New"}},
            {"id":2,"fields":{"System.Title":"Bravo","System.WorkItemType":"Task","System.State":"New"}}
        ]}'
    }

    run cmd_list --sort=-id
    assert_status 0
    local alpha_pos bravo_pos
    alpha_pos="$(grep -n "Alpha" <<< "${output}" | head -1 | cut -d: -f1)"
    bravo_pos="$(grep -n "Bravo" <<< "${output}" | head -1 | cut -d: -f1)"
    # Descending → Bravo (id 2) appears before Alpha (id 1).
    [[ "${bravo_pos}" -lt "${alpha_pos}" ]] || { echo "descending sort didn't reverse: ${output}"; return 1; }
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

@test "cmd_comment: no args invokes task picker AND editor, then POSTs" {
    require_binary jq
    twk_write_fake_config

    # Stub the task resolver — returns a known ID without going to the network.
    resolve_work_item() { echo "777"; }

    # Fake editor: writes a known body into the tmpfile path it's invoked with.
    local fake_editor
    fake_editor="$(mktemp -t twk-fake-editor-XXXXXX)"
    cat > "${fake_editor}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "drafted in editor" > "$1"
EOF
    chmod +x "${fake_editor}"

    local captured_id="" captured_text=""
    azdo_post_comment() {
        captured_id="$1"
        captured_text="$2"
        printf '%s' '{"createdDate":"2026-05-02T10:00:00Z"}'
    }

    EDITOR="${fake_editor}" run cmd_comment
    rm -f "${fake_editor}"

    assert_status 0
    [[ "${captured_id}" == "777" ]] || { echo "got id: ${captured_id}"; return 1; }
    [[ "${captured_text}" == *"drafted in editor"* ]] || { echo "got text: ${captured_text}"; return 1; }
    assert_output_contains "Posted comment on #777"
    assert_output_contains "drafted in editor"
}

@test "cmd_comment: editor mode aborts when the editor leaves the buffer empty" {
    require_binary jq
    twk_write_fake_config

    resolve_work_item() { echo "888"; }

    # Editor that erases the file (simulates user clearing all content).
    local fake_editor
    fake_editor="$(mktemp -t twk-fake-editor-XXXXXX)"
    cat > "${fake_editor}" <<'EOF'
#!/usr/bin/env bash
: > "$1"
EOF
    chmod +x "${fake_editor}"

    local posted=false
    azdo_post_comment() { posted=true; }

    EDITOR="${fake_editor}" run cmd_comment
    rm -f "${fake_editor}"

    assert_status 1
    assert_output_contains "empty comment, aborting"
    [[ "${posted}" == false ]] || { echo "POST should not have fired"; return 1; }
}

@test "cmd_comment: editor mode strips '#'-prefixed lines from the body" {
    require_binary jq
    twk_write_fake_config

    resolve_work_item() { echo "999"; }

    local fake_editor
    fake_editor="$(mktemp -t twk-fake-editor-XXXXXX)"
    cat > "${fake_editor}" <<'EOF'
#!/usr/bin/env bash
cat > "$1" <<'INNER'
real content here

# This is a help line that should be stripped.
# Another stripped line.
more real content
INNER
EOF
    chmod +x "${fake_editor}"

    local captured_text=""
    azdo_post_comment() {
        captured_text="$2"
        printf '%s' '{"createdDate":"2026-05-02T10:00:00Z"}'
    }

    EDITOR="${fake_editor}" run cmd_comment
    rm -f "${fake_editor}"

    assert_status 0
    [[ "${captured_text}" == *"real content here"* ]] || { echo "missing first content line"; return 1; }
    [[ "${captured_text}" == *"more real content"* ]] || { echo "missing second content line"; return 1; }
    [[ "${captured_text}" != *"help line"* ]] || { echo "comment line leaked into body: ${captured_text}"; return 1; }
    [[ "${captured_text}" != *"stripped line"* ]] || { echo "comment line leaked into body: ${captured_text}"; return 1; }
}

@test "cmd_comment: rejects too many positional arguments" {
    twk_write_fake_config

    run cmd_comment 12345 "text" extra
    assert_status 1
    assert_output_contains "too many arguments"
}

@test "cmd_comment: errors when text is empty" {
    twk_write_fake_config

    run cmd_comment 12345 ""
    assert_status 1
    assert_output_contains "empty comment, aborting"
}

@test "cmd_comment: errors when text is only whitespace" {
    twk_write_fake_config

    run cmd_comment 12345 "   "
    assert_status 1
    assert_output_contains "empty comment, aborting"
}

@test "cmd_comment: inline text path posts to azdo_post_comment with the right id and body" {
    require_binary jq
    twk_write_fake_config

    local captured_id="" captured_text=""
    azdo_post_comment() {
        captured_id="$1"
        captured_text="$2"
        printf '%s' '{"id":99,"text":"hello","createdDate":"2026-05-02T10:42:00Z"}'
    }

    run cmd_comment 12345 "hello world"
    assert_status 0
    [[ "${captured_id}" == "12345" ]] || { echo "got id: ${captured_id}"; return 1; }
    [[ "${captured_text}" == "hello world" ]] || { echo "got text: ${captured_text}"; return 1; }
    assert_output_contains "Posted comment on #12345 at 2026-05-02 10:42"
    # Body echoed back, indented.
    assert_output_contains "  hello world"
}

@test "cmd_comment: stdin path reads body from standard input via '-'" {
    require_binary jq
    twk_write_fake_config

    local captured_text=""
    azdo_post_comment() {
        captured_text="$2"
        printf '%s' '{"id":1,"createdDate":"2026-05-02T10:00:00Z"}'
    }

    # Bats: pass stdin via run by invoking through bash -c.
    run bash -c "
        source '${TWK_REPO}/lib/config.sh'
        source '${TWK_REPO}/lib/azdo.sh'
        source '${TWK_REPO}/lib/resolve.sh'
        source '${TWK_REPO}/lib/session.sh'
        source '${TWK_REPO}/lib/display.sh'
        export TWK_DATA_DIR='${TWK_DATA_DIR}'
        export TWK_CONFIG_DIR='${TWK_CONFIG_DIR}'
        # Replicate the test mock.
        azdo_post_comment() { echo \"got: \$2\"; printf '%s' '{\"createdDate\":\"2026-05-02T10:00:00Z\"}'; }
        printf 'piped content here\n' | cmd_comment 12345 -
    "
    assert_status 0
    assert_output_contains "got: piped content here"
    assert_output_contains "Posted comment on #12345"
}

@test "cmd_comment: reports failure when AzDO POST fails" {
    twk_write_fake_config

    azdo_post_comment() { return 1; }

    run cmd_comment 12345 "doomed"
    assert_status 1
    assert_output_contains "failed to post comment on #12345"
}

@test "cmd_comment: degrades gracefully when API response has no createdDate" {
    require_binary jq
    twk_write_fake_config

    azdo_post_comment() { printf '%s' '{"id":1,"text":"ok"}'; }

    run cmd_comment 12345 "no timestamp"
    assert_status 0
    # Falls back to the timestamp-less message.
    assert_output_contains "Posted comment on #12345:"
    assert_output_contains "  no timestamp"
}

@test "render_discussion: prints '(no comments)' when comments array is empty" {
    require_binary jq
    azdo_fetch_comments() { printf '%s' '{"totalCount":0,"comments":[]}'; }

    run render_discussion 12345
    assert_status 0
    assert_output_contains "Discussion: (no comments)"
}

@test "render_discussion: degrades gracefully when fetch fails" {
    azdo_fetch_comments() { return 1; }

    run render_discussion 12345
    assert_status 0
    assert_output_contains "could not fetch comments"
}

@test "render_discussion: renders comments in chronological order with author + timestamp" {
    require_binary jq
    require_binary base64

    azdo_fetch_comments() {
        # Out-of-order on purpose to verify sort_by(.createdDate).
        printf '%s' '{
            "totalCount": 3,
            "comments": [
                {"createdDate":"2026-04-16T09:15:00Z","createdBy":{"displayName":"Luke McCann"},"text":"Confirmed, will rebase."},
                {"createdDate":"2026-04-15T10:30:00Z","createdBy":{"displayName":"Sarah Khan"},"text":"<p>First reply</p>"},
                {"createdDate":"2026-04-15T11:42:00Z","createdBy":{"displayName":"Sarah Khan"},"text":"<b>Edge case</b>"}
            ]
        }'
    }

    run render_discussion 12345
    assert_status 0
    assert_output_contains "Discussion (3 comments):"
    # Each row's header is present.
    assert_output_contains "[2026-04-15 10:30] Sarah Khan"
    assert_output_contains "[2026-04-15 11:42] Sarah Khan"
    assert_output_contains "[2026-04-16 09:15] Luke McCann"
    # HTML stripped from comment bodies.
    assert_output_contains "First reply"
    assert_output_contains "Edge case"
    [[ "${output}" != *"<p>"* ]] || { echo "HTML leaked: ${output}"; return 1; }
    [[ "${output}" != *"<b>"* ]] || { echo "HTML leaked: ${output}"; return 1; }

    # Chronological: 10:30 line should appear before 11:42 line, before 09:15 line.
    local p1 p2 p3
    p1="$(grep -n "10:30" <<< "${output}" | head -1 | cut -d: -f1)"
    p2="$(grep -n "11:42" <<< "${output}" | head -1 | cut -d: -f1)"
    p3="$(grep -n "09:15" <<< "${output}" | head -1 | cut -d: -f1)"
    [[ "${p1}" -lt "${p2}" ]] || { echo "10:30 not before 11:42"; return 1; }
    [[ "${p2}" -lt "${p3}" ]] || { echo "11:42 not before 09:15"; return 1; }
}

@test "render_discussion: trailing count is singular for one comment" {
    require_binary jq
    require_binary base64

    azdo_fetch_comments() {
        printf '%s' '{
            "totalCount": 1,
            "comments": [
                {"createdDate":"2026-04-15T10:30:00Z","createdBy":{"displayName":"Solo"},"text":"alone"}
            ]
        }'
    }

    run render_discussion 12345
    assert_status 0
    assert_output_contains "Discussion (1 comment):"
    [[ "${output}" != *"comments)"* ]] || { echo "should be singular: ${output}"; return 1; }
}

@test "cmd_show: rejects too many positional arguments" {
    twk_write_fake_config
    config_global_file() { printf '%s\n' "${TWK_CONFIG_DIR}/config"; }
    config_find_local() { return 1; }

    run cmd_show 1 2
    assert_status 1
    assert_output_contains "too many arguments"
}

@test "cmd_show --discussion: appends the discussion block after metadata" {
    require_binary jq
    require_binary base64
    twk_write_fake_config
    config_global_file() { printf '%s\n' "${TWK_CONFIG_DIR}/config"; }
    config_find_local() { return 1; }

    azdo_fetch_work_item() {
        printf '%s' '{"id":12345,"fields":{"System.Title":"With chat","System.WorkItemType":"Task","System.State":"Active"}}'
    }
    azdo_fetch_comments() {
        printf '%s' '{
            "totalCount": 1,
            "comments": [
                {"createdDate":"2026-04-15T10:30:00Z","createdBy":{"displayName":"Luke"},"text":"hello world"}
            ]
        }'
    }

    run cmd_show 12345 --discussion
    assert_status 0
    # Metadata block is rendered.
    assert_output_contains "#12345"
    assert_output_contains "With chat"
    # Discussion block is rendered.
    assert_output_contains "Discussion (1 comment):"
    assert_output_contains "[2026-04-15 10:30] Luke"
    assert_output_contains "hello world"

    # Order: metadata header line precedes discussion header.
    local title_line discussion_line
    title_line="$(grep -n "With chat" <<< "${output}" | head -1 | cut -d: -f1)"
    discussion_line="$(grep -n "Discussion" <<< "${output}" | head -1 | cut -d: -f1)"
    [[ "${title_line}" -lt "${discussion_line}" ]] || { echo "discussion not after metadata"; return 1; }
}

@test "cmd_show without --discussion: does NOT call comments API" {
    require_binary jq
    twk_write_fake_config
    config_global_file() { printf '%s\n' "${TWK_CONFIG_DIR}/config"; }
    config_find_local() { return 1; }

    azdo_fetch_work_item() {
        printf '%s' '{"id":12345,"fields":{"System.Title":"Quiet","System.WorkItemType":"Task","System.State":"New"}}'
    }
    local sentinel="${BATS_TEST_TMPDIR}/comments_called"
    azdo_fetch_comments() { : > "${sentinel}"; }

    run cmd_show 12345
    assert_status 0
    [[ ! -e "${sentinel}" ]] || { echo "comments API was called without --discussion"; return 1; }
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

@test "cmd_users: rejects unexpected arguments" {
    twk_write_fake_config

    run cmd_users surplus
    assert_status 1
    assert_output_contains "takes no arguments"
    assert_output_contains "Usage: twk users"
}

@test "cmd_users: prints 'no assigned users' when sprint has none" {
    require_binary jq
    twk_write_fake_config

    fetch_current_sprint_items() {
        printf '%s' '{"value":[
            {"id":1,"fields":{"System.Title":"Unassigned A"}},
            {"id":2,"fields":{"System.Title":"Unassigned B","System.AssignedTo":null}}
        ]}'
    }

    run cmd_users
    assert_status 0
    assert_output_contains "No assigned users in current sprint."
}

@test "cmd_users: aggregates and deduplicates unique users" {
    require_binary jq
    twk_write_fake_config

    fetch_current_sprint_items() {
        printf '%s' '{"value":[
            {"id":1,"fields":{"System.Title":"A","System.AssignedTo":{"id":"alice-id","displayName":"Alice","uniqueName":"alice@example.com"}}},
            {"id":2,"fields":{"System.Title":"B","System.AssignedTo":{"id":"alice-id","displayName":"Alice","uniqueName":"alice@example.com"}}},
            {"id":3,"fields":{"System.Title":"C","System.AssignedTo":{"id":"bob-id","displayName":"Bob","uniqueName":"bob@example.com"}}}
        ]}'
    }

    run cmd_users
    assert_status 0
    assert_output_contains "Users assigned to current sprint items:"
    assert_output_contains "ID"
    assert_output_contains "Username"
    assert_output_contains "Email"
    assert_output_contains "alice-id"
    assert_output_contains "Alice"
    assert_output_contains "alice@example.com"
    assert_output_contains "bob-id"
    assert_output_contains "Bob"
    assert_output_contains "bob@example.com"
    assert_output_contains "(2 users)"

    # Alice should appear exactly once despite being on two items.
    local alice_count
    alice_count="$(grep -c 'alice@example.com' <<< "${output}")"
    [[ "${alice_count}" -eq 1 ]] || { echo "alice appeared ${alice_count} times"; return 1; }
}

@test "cmd_users: sorts by display name (case-insensitive)" {
    require_binary jq
    twk_write_fake_config

    fetch_current_sprint_items() {
        printf '%s' '{"value":[
            {"id":1,"fields":{"System.AssignedTo":{"id":"z","displayName":"Zach","uniqueName":"zach@example.com"}}},
            {"id":2,"fields":{"System.AssignedTo":{"id":"a","displayName":"alice","uniqueName":"alice@example.com"}}},
            {"id":3,"fields":{"System.AssignedTo":{"id":"m","displayName":"Mike","uniqueName":"mike@example.com"}}}
        ]}'
    }

    run cmd_users
    assert_status 0
    # Confirm row order via positions in output.
    local alice_pos mike_pos zach_pos
    alice_pos="$(printf '%s\n' "${output}" | grep -n 'alice@' | head -1 | cut -d: -f1)"
    mike_pos="$(printf '%s\n' "${output}"  | grep -n 'mike@'  | head -1 | cut -d: -f1)"
    zach_pos="$(printf '%s\n' "${output}"  | grep -n 'zach@'  | head -1 | cut -d: -f1)"
    [[ "${alice_pos}" -lt "${mike_pos}" ]] || { echo "alice not before mike"; return 1; }
    [[ "${mike_pos}" -lt "${zach_pos}" ]] || { echo "mike not before zach"; return 1; }
}

@test "cmd_users: legacy string AssignedTo is skipped (not crashes)" {
    require_binary jq
    twk_write_fake_config

    fetch_current_sprint_items() {
        # Mix the modern object form with the legacy string form. The
        # string form should be filtered out by the `type == "object"`
        # check rather than crashing the jq pipeline.
        printf '%s' '{"value":[
            {"id":1,"fields":{"System.AssignedTo":"legacy@example.com"}},
            {"id":2,"fields":{"System.AssignedTo":{"id":"x","displayName":"Modern","uniqueName":"modern@example.com"}}}
        ]}'
    }

    run cmd_users
    assert_status 0
    assert_output_contains "modern@example.com"
    assert_output_contains "(1 user)"
    [[ "${output}" != *"legacy@example.com"* ]] || { echo "legacy form leaked: ${output}"; return 1; }
}

@test "cmd_users --all: pulls from the org Graph API and skips groups" {
    require_binary jq
    twk_write_fake_config
    config_global_file() { printf '%s\n' "${TWK_CONFIG_DIR}/config"; }
    config_find_local() { return 1; }

    azdo_fetch_org_users() {
        printf '%s' '{"value":[
            {"subjectKind":"user","descriptor":"aad.AAA","displayName":"Alice","principalName":"alice@example.com"},
            {"subjectKind":"group","descriptor":"aad.GGG","displayName":"Team A","principalName":"team@example.com"},
            {"subjectKind":"user","descriptor":"aad.BBB","displayName":"Bob","principalName":"bob@example.com"}
        ]}'
    }
    # Sprint fetcher must not be called when --all is set.
    fetch_current_sprint_items() { echo "SHOULD NOT FIRE"; return 1; }

    run cmd_users --all
    assert_status 0
    assert_output_contains "Users in the Azure DevOps organisation:"
    assert_output_contains "alice@example.com"
    assert_output_contains "bob@example.com"
    [[ "${output}" != *"team@example.com"* ]] || { echo "group leaked: ${output}"; return 1; }
    [[ "${output}" != *"SHOULD NOT FIRE"* ]] || { echo "sprint fetcher fired"; return 1; }
    assert_output_contains "(2 users)"
}

@test "cmd_users --all: reports PAT scope hint when Graph fetch fails" {
    twk_write_fake_config
    config_global_file() { printf '%s\n' "${TWK_CONFIG_DIR}/config"; }
    config_find_local() { return 1; }

    azdo_fetch_org_users() { return 1; }

    run cmd_users --all
    assert_status 1
    assert_output_contains "Graph (Read)"
}

@test "cmd_users: rejects unknown flags" {
    twk_write_fake_config
    config_global_file() { printf '%s\n' "${TWK_CONFIG_DIR}/config"; }
    config_find_local() { return 1; }

    run cmd_users --bogus
    assert_status 1
    assert_output_contains "unknown argument '--bogus'"
}

@test "cmd_users: trailing count uses singular for one user" {
    require_binary jq
    twk_write_fake_config

    fetch_current_sprint_items() {
        printf '%s' '{"value":[
            {"id":1,"fields":{"System.AssignedTo":{"id":"a","displayName":"Alone","uniqueName":"alone@example.com"}}}
        ]}'
    }

    run cmd_users
    assert_status 0
    assert_output_contains "(1 user)"
    [[ "${output}" != *"users)"* ]] || { echo "should be singular: ${output}"; return 1; }
}

@test "cmd_commit: rejects unknown arguments" {
    twk_write_fake_config

    run cmd_commit --bogus
    assert_status 1
    assert_output_contains "unknown argument '--bogus'"
    assert_output_contains "Usage: twk commit"
}

@test "cmd_commit --dry-run: prints DRY RUN header and per-session projection" {
    require_binary jq
    require_binary bc
    twk_write_fake_config

    # Two sessions: one paused (committable), one running (skipped).
    local now hour_ago
    now="$(date +%s)"
    hour_ago=$(( now - 3600 ))
    mkdir -p "${TWK_DATA_DIR}"
    {
        echo "start|${hour_ago}"
        echo "pause|${now}"
    } > "${TWK_DATA_DIR}/100.session"
    echo "start|${now}" > "${TWK_DATA_DIR}/200.session"

    azdo_resolve_time_field() { echo "Custom.TaskTime"; }
    azdo_fetch_work_item() {
        printf '%s' '{"id":'"$1"',"fields":{"Custom.TaskTime":2.5}}'
    }

    # Both writes must NOT fire in dry-run mode.
    local patch_called=false
    local archive_called=false
    azdo_update_time_spent() { patch_called=true; }
    session_mark_committed() { archive_called=true; }

    run cmd_commit --dry-run
    assert_status 0
    assert_output_contains "DRY RUN"
    assert_output_contains "would commit"
    assert_output_contains "existing 2.5h"
    assert_output_contains "#100"
    # Running session skipped with the same message as the real path.
    assert_output_contains "#200: skipped (still running"
    # Summary line uses dry-run language.
    assert_output_contains "Would commit"
    assert_output_contains "no changes were sent"

    [[ "${patch_called}" == false ]] || { echo "PATCH should not have fired in dry-run"; return 1; }
    [[ "${archive_called}" == false ]] || { echo "session_mark_committed should not have fired"; return 1; }
}

@test "cmd_commit --dry-run: leaves session files in place (not archived)" {
    require_binary jq
    require_binary bc
    twk_write_fake_config

    local now hour_ago
    now="$(date +%s)"
    hour_ago=$(( now - 3600 ))
    mkdir -p "${TWK_DATA_DIR}"
    {
        echo "start|${hour_ago}"
        echo "end|${now}"
    } > "${TWK_DATA_DIR}/100.session"

    azdo_resolve_time_field() { echo "Custom.TaskTime"; }
    azdo_fetch_work_item() { printf '%s' '{"id":100,"fields":{"Custom.TaskTime":0}}'; }

    run cmd_commit --dry-run
    assert_status 0

    [[ -f "${TWK_DATA_DIR}/100.session" ]] || { echo "session file should remain"; return 1; }
    [[ ! -d "${TWK_DATA_DIR}/committed" ]] || {
        local archived
        archived="$(ls "${TWK_DATA_DIR}/committed" 2>/dev/null)"
        [[ -z "${archived}" ]] || { echo "committed/ unexpectedly populated: ${archived}"; return 1; }
    }
}

@test "cmd_commit --dry-run: reports the right hours total in the summary" {
    require_binary jq
    require_binary bc
    twk_write_fake_config

    local now two_hours_ago
    now="$(date +%s)"
    two_hours_ago=$(( now - 7200 ))
    mkdir -p "${TWK_DATA_DIR}"
    {
        echo "start|${two_hours_ago}"
        echo "end|${now}"
    } > "${TWK_DATA_DIR}/100.session"

    azdo_resolve_time_field() { echo "Custom.TaskTime"; }
    azdo_fetch_work_item() { printf '%s' '{"id":100,"fields":{"Custom.TaskTime":1.0}}'; }

    run cmd_commit --dry-run
    assert_status 0
    # 2h tracked + 1h existing = 3.00h total. Dry-run "would commit" reports tracked hours.
    assert_output_contains "would commit 2.00h"
    assert_output_contains "existing 1.0h"
    assert_output_contains "total 3.00h"
    # Summary shows 2h to be committed across 1 session.
    assert_output_contains "Would commit 2.00h across 1 session"
}

@test "cmd_commit --dry-run: 'no entries' early return is unchanged" {
    twk_write_fake_config

    run cmd_commit --dry-run
    assert_status 0
    assert_output_contains "No uncommitted time entries to commit."
}

@test "cmd_log: rejects unknown arguments" {
    run cmd_log --bogus
    assert_status 1
    assert_output_contains "unknown argument '--bogus'"
}

@test "cmd_log: rejects non-numeric --days" {
    run cmd_log --days=abc
    assert_status 1
    assert_output_contains "non-negative integer"
}

@test "cmd_log: prints 'No commits yet' when committed/ doesn't exist" {
    [[ ! -d "${TWK_DATA_DIR}/committed" ]] || rm -rf "${TWK_DATA_DIR}/committed"

    run cmd_log
    assert_status 0
    assert_output_contains "No commits yet."
}

@test "cmd_log: prints 'No commits found' with --all when committed/ is empty" {
    mkdir -p "${TWK_DATA_DIR}/committed"

    run cmd_log --all
    assert_status 0
    assert_output_contains "No commits found."
}

@test "cmd_log: prints 'No commits in the last N days' when window has nothing" {
    mkdir -p "${TWK_DATA_DIR}/committed"
    # File from 100 days ago — outside the default 7-day window.
    local old_ts=$(( $(date +%s) - 100 * 86400 ))
    {
        echo "start|${old_ts}"
        echo "end|$((old_ts + 3600))"
    } > "${TWK_DATA_DIR}/committed/100_${old_ts}.session"

    run cmd_log
    assert_status 0
    assert_output_contains "No commits in the last 7 days."
}

@test "cmd_log: default (last 7 days, by date): groups, sorts, totals correctly" {
    require_binary jq
    require_binary bc
    mkdir -p "${TWK_DATA_DIR}/committed"

    local now=$(( $(date +%s) ))
    local today=$(( now - 100 ))           # ~now (today)
    local yesterday=$(( now - 86400 ))     # 1 day ago
    local twoDaysAgo=$(( now - 2 * 86400 ))

    # Three commits: two today (different IDs), one yesterday, one 2 days ago.
    {
        echo "start|$((today - 3600))"
        echo "end|${today}"                  # 60m
    } > "${TWK_DATA_DIR}/committed/100_${today}.session"
    printf '%s' '{"title":"Login bug","type":"Task"}' > "${TWK_DATA_DIR}/committed/100_${today}.meta"

    {
        echo "start|$((today - 1800))"
        echo "end|${today}"                  # 30m
    } > "${TWK_DATA_DIR}/committed/200_${today}.session"
    printf '%s' '{"title":"Auth refactor","type":"Task"}' > "${TWK_DATA_DIR}/committed/200_${today}.meta"

    {
        echo "start|$((yesterday - 3600))"
        echo "end|${yesterday}"              # 60m
    } > "${TWK_DATA_DIR}/committed/100_${yesterday}.session"
    printf '%s' '{"title":"Login bug","type":"Task"}' > "${TWK_DATA_DIR}/committed/100_${yesterday}.meta"

    {
        echo "start|$((twoDaysAgo - 1800))"
        echo "end|${twoDaysAgo}"             # 30m
    } > "${TWK_DATA_DIR}/committed/300_${twoDaysAgo}.session"

    run cmd_log
    assert_status 0
    assert_output_contains "Login bug"
    assert_output_contains "Auth refactor"
    assert_output_contains "(no title cached)"     # 300 has no .meta
    assert_output_contains "Total"
    assert_output_contains "across 4 sessions"

    # Newest day appears before older days.
    local p_today p_yesterday p_two
    p_today="$(grep -n "$(date -d "@${today}" +%Y-%m-%d)" <<< "${output}" | head -1 | cut -d: -f1)"
    p_yesterday="$(grep -n "$(date -d "@${yesterday}" +%Y-%m-%d)" <<< "${output}" | head -1 | cut -d: -f1)"
    p_two="$(grep -n "$(date -d "@${twoDaysAgo}" +%Y-%m-%d)" <<< "${output}" | head -1 | cut -d: -f1)"
    [[ "${p_today}" -lt "${p_yesterday}" ]] || { echo "today not before yesterday"; return 1; }
    [[ "${p_yesterday}" -lt "${p_two}" ]] || { echo "yesterday not before two days ago"; return 1; }
}

@test "cmd_log --days=N: filters history by window" {
    require_binary jq
    require_binary bc
    mkdir -p "${TWK_DATA_DIR}/committed"

    local now=$(( $(date +%s) ))
    local recent=$(( now - 2 * 86400 ))     # 2 days ago
    local old=$(( now - 20 * 86400 ))       # 20 days ago

    {
        echo "start|$((recent - 1800))"
        echo "end|${recent}"
    } > "${TWK_DATA_DIR}/committed/100_${recent}.session"
    {
        echo "start|$((old - 1800))"
        echo "end|${old}"
    } > "${TWK_DATA_DIR}/committed/200_${old}.session"

    # Default 7 days: only the recent one.
    run cmd_log
    assert_status 0
    assert_output_contains "#100"
    [[ "${output}" != *"#200"* ]] || { echo "old item leaked into 7-day window"; return 1; }

    # --days=30: both included.
    run cmd_log --days=30
    assert_status 0
    assert_output_contains "#100"
    assert_output_contains "#200"

    # --all: both included.
    run cmd_log --all
    assert_status 0
    assert_output_contains "#100"
    assert_output_contains "#200"
}

@test "cmd_log --by-id: groups by work item, prints subtotals" {
    require_binary jq
    require_binary bc
    mkdir -p "${TWK_DATA_DIR}/committed"

    local now=$(( $(date +%s) ))
    local d1=$(( now - 3600 ))
    local d2=$(( now - 86400 ))

    {
        echo "start|$((d1 - 3600))"
        echo "end|${d1}"
    } > "${TWK_DATA_DIR}/committed/100_${d1}.session"   # 60m on item 100, today
    printf '%s' '{"title":"Login bug","type":"Task"}' > "${TWK_DATA_DIR}/committed/100_${d1}.meta"

    {
        echo "start|$((d2 - 1800))"
        echo "end|${d2}"
    } > "${TWK_DATA_DIR}/committed/100_${d2}.session"   # 30m on item 100, yesterday
    printf '%s' '{"title":"Login bug","type":"Task"}' > "${TWK_DATA_DIR}/committed/100_${d2}.meta"

    {
        echo "start|$((d1 - 1800))"
        echo "end|${d1}"
    } > "${TWK_DATA_DIR}/committed/200_${d1}.session"   # 30m on item 200
    printf '%s' '{"title":"Auth refactor","type":"Task"}' > "${TWK_DATA_DIR}/committed/200_${d1}.meta"

    run cmd_log --by-id
    assert_status 0
    # Per-item headers and subtotals appear.
    assert_output_contains "#100  Login bug"
    assert_output_contains "#200  Auth refactor"
    assert_output_contains "Subtotal:"
    assert_output_contains "Total:"
    assert_output_contains "across 3 sessions"

    # Within an item, dates should be in descending order. For #100,
    # newer (d1) line should appear before older (d2).
    local p_d1 p_d2
    p_d1="$(grep -n "$(date -d "@${d1}" +%Y-%m-%d)" <<< "${output}" | head -1 | cut -d: -f1)"
    p_d2="$(grep -n "$(date -d "@${d2}" +%Y-%m-%d)" <<< "${output}" | head -1 | cut -d: -f1)"
    [[ "${p_d1}" -lt "${p_d2}" ]] || { echo "newer date should appear before older within item: ${p_d1} vs ${p_d2}"; return 1; }
}

@test "cmd_log: skips malformed filenames in committed/" {
    require_binary jq
    require_binary bc
    mkdir -p "${TWK_DATA_DIR}/committed"

    local now=$(( $(date +%s) - 100 ))

    # One valid session.
    {
        echo "start|$((now - 1800))"
        echo "end|${now}"
    } > "${TWK_DATA_DIR}/committed/100_${now}.session"

    # Malformed names that must be skipped silently.
    : > "${TWK_DATA_DIR}/committed/junk.session"
    : > "${TWK_DATA_DIR}/committed/no-underscore.session"
    : > "${TWK_DATA_DIR}/committed/100_notanumber.session"

    run cmd_log --all
    assert_status 0
    assert_output_contains "#100"
    assert_output_contains "across 1 session"
}

@test "cmd_log: default rows lead with commit time as HH:MM" {
    require_binary jq
    require_binary bc
    mkdir -p "${TWK_DATA_DIR}/committed"

    local now
    now=$(( $(date +%s) - 100 ))
    {
        echo "start|$((now - 3600))"
        echo "end|${now}"
    } > "${TWK_DATA_DIR}/committed/100_${now}.session"
    printf '%s' '{"title":"With time","type":"Task"}' > "${TWK_DATA_DIR}/committed/100_${now}.meta"

    run cmd_log --all
    assert_status 0
    # The expected HH:MM that should appear on the row.
    local expected_time
    expected_time="$(date -d "@${now}" +%H:%M)"
    assert_output_contains "${expected_time}"
    # Time should appear before the ID on the same row.
    local time_col_line
    time_col_line="$(grep -F "${expected_time}" <<< "${output}" | grep -F "#100" | head -1)"
    [[ -n "${time_col_line}" ]] || { echo "no row contains both time and #100"; return 1; }
    # The HH:MM should appear before the #ID.
    local time_pos id_pos
    time_pos="$(awk -v s="${expected_time}" '{print index($0, s); exit}' <<< "${time_col_line}")"
    id_pos="$(awk '{print index($0, "#100"); exit}' <<< "${time_col_line}")"
    [[ "${time_pos}" -lt "${id_pos}" ]] || { echo "time should precede ID on the row: ${time_col_line}"; return 1; }
}

@test "cmd_log --by-id: shows full 'YYYY-MM-DD HH:MM' on each entry" {
    require_binary jq
    require_binary bc
    mkdir -p "${TWK_DATA_DIR}/committed"

    local now
    now=$(( $(date +%s) - 100 ))
    {
        echo "start|$((now - 3600))"
        echo "end|${now}"
    } > "${TWK_DATA_DIR}/committed/100_${now}.session"

    run cmd_log --by-id --all
    assert_status 0
    local expected_dt
    expected_dt="$(date -d "@${now}" +"%Y-%m-%d %H:%M")"
    assert_output_contains "${expected_dt}"
}

@test "cmd_log --by-id: trailing 'session' uses singular for one entry" {
    require_binary jq
    require_binary bc
    mkdir -p "${TWK_DATA_DIR}/committed"

    local now=$(( $(date +%s) - 100 ))
    {
        echo "start|$((now - 1800))"
        echo "end|${now}"
    } > "${TWK_DATA_DIR}/committed/100_${now}.session"

    run cmd_log --by-id
    assert_status 0
    assert_output_contains "across 1 session."
    [[ "${output}" != *"sessions."* ]] || { echo "should be singular: ${output}"; return 1; }
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
