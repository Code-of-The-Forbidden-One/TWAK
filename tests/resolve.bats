#!/usr/bin/env bats
# shellcheck disable=SC2329,SC2034,SC2030,SC2031
#   SC2329: stub overrides invoked indirectly by SUT
#   SC2034: helper-set vars consumed by SUT
#   SC2030/SC2031: bats wraps each @test in a subshell; `export` is the
#     correct pattern for env vars that the SUT (or mock layer) reads.
#
# Tests for lib/resolve.sh — work item resolution dispatch:
#   resolve_work_item            (numeric short-circuit, title fallback, picker)
#   resolve_for_session_action   (forwards to picker / direct query)
#   resolve_session_interactive  (state filter, auto-select-on-single-match)
#   resolve_interactive          (hides running, truncates titles, paused flag)

load 'helpers/setup.bash'
load 'helpers/mock_azdo.bash'

setup() {
    twk_setup_env
    twk_source_libs
    twk_load_stub_path
    mock_azdo_install
    twk_write_fake_config
}

# -----------------------------------------------------------------------------
# resolve_work_item — numeric ID short-circuits to no AzDO call.
# -----------------------------------------------------------------------------

@test "resolve_work_item: numeric query echoes the id and never hits AzDO" {
    run resolve_work_item 12345
    assert_status 0
    [[ "${output}" == "12345" ]]

    # No AzDO calls should have been made.
    [[ "$(mock_azdo_call_count azdo_fetch_current_iteration)" -eq 0 ]]
    [[ "$(mock_azdo_call_count azdo_fetch_work_items_batch)" -eq 0 ]]
}

@test "resolve_work_item: empty query delegates to resolve_interactive" {
    # Stub resolve_interactive locally and verify it gets called.
    local interactive_called=0
    resolve_interactive() {
        interactive_called=1
        echo "1234"
    }
    run resolve_work_item ""
    assert_status 0
    [[ "${output}" == "1234" ]]
    # We can't read interactive_called via run (subshell), but the output
    # would be empty if the real resolve_interactive ran (no fixture). The
    # echo "1234" is the proof.
}

@test "resolve_work_item: non-numeric query delegates to resolve_by_title" {
    resolve_by_title() {
        printf '%s\n' "title-stub-output"
    }
    run resolve_work_item "login bug"
    assert_status 0
    [[ "${output}" == "title-stub-output" ]]
}

# -----------------------------------------------------------------------------
# resolve_for_session_action — query present → resolve_work_item;
# query empty → resolve_session_interactive.
# -----------------------------------------------------------------------------

@test "resolve_for_session_action: with query, forwards to resolve_work_item" {
    local got_query=""
    resolve_work_item() { got_query="$1"; echo "${got_query}"; }
    run resolve_for_session_action 12345 "running" "pause"
    assert_status 0
    [[ "${output}" == "12345" ]]
}

@test "resolve_for_session_action: empty query, forwards to resolve_session_interactive with state filter" {
    local got_filter="" got_label=""
    resolve_session_interactive() {
        got_filter="$1"
        got_label="$2"
        echo "${got_filter}|${got_label}"
    }
    run resolve_for_session_action "" "running|paused" "end"
    assert_status 0
    [[ "${output}" == "running|paused|end" ]]
}

# -----------------------------------------------------------------------------
# resolve_session_interactive — filters by state and auto-selects when
# exactly one session matches.
# -----------------------------------------------------------------------------

@test "resolve_session_interactive: rc=1 when no uncommitted sessions" {
    run resolve_session_interactive "running" "pause"
    assert_status 1
    assert_output_contains "no uncommitted sessions"
}

@test "resolve_session_interactive: auto-selects single matching session by state" {
    # Need jq for session_read_meta_title (called in the loop). Skip otherwise.
    require_binary jq

    # Two sessions: 100 running, 200 ended. Filter for running -> only #100.
    local now hour_ago
    now="$(date +%s)"
    hour_ago=$(( now - 3600 ))
    {
        echo "start|${hour_ago}"
    } > "${TWK_DATA_DIR}/100.session"
    {
        echo "start|${hour_ago}"
        echo "end|${now}"
    } > "${TWK_DATA_DIR}/200.session"

    run resolve_session_interactive "running" "pause"
    assert_status 0
    [[ "${output}" == "100" ]]
}

@test "resolve_session_interactive: rc=1 when filter excludes all sessions" {
    require_binary jq
    local now
    now="$(date +%s)"
    echo "start|${now}" > "${TWK_DATA_DIR}/100.session"
    echo "start|${now}" >> "${TWK_DATA_DIR}/100.session"
    echo "end|${now}" >> "${TWK_DATA_DIR}/100.session"

    # Filter for 'running' but only ended exists.
    run resolve_session_interactive "running" "pause"
    assert_status 1
    assert_output_contains "no sessions to pause"
}

@test "resolve_session_interactive: empty state filter accepts any session" {
    require_binary jq
    local now
    now="$(date +%s)"
    echo "start|${now}" > "${TWK_DATA_DIR}/300.session"

    run resolve_session_interactive "" "cancel"
    assert_status 0
    [[ "${output}" == "300" ]]
}

# -----------------------------------------------------------------------------
# resolve_interactive — hides running sessions, truncates titles to 40,
# flags paused with `paused HH:MM:SS`, surfaces hidden-running count.
# -----------------------------------------------------------------------------

@test "resolve_interactive: hides running sessions and reports hidden count" {
    require_binary jq

    # Make 100 'running' so it gets hidden.
    local now
    now="$(date +%s)"
    echo "start|${now}" > "${TWK_DATA_DIR}/100.session"

    # No fzf binary in test env, so resolve_with_numbered_list gets called.
    # That function reads from stdin → use heredoc to feed selection.
    # Item order after hiding 100: 200, 300. Pick "1" → 200.
    run bash -c "
        source '${TWK_REPO}/lib/config.sh'
        source '${TWK_REPO}/lib/azdo.sh'
        source '${TWK_REPO}/lib/resolve.sh'
        source '${TWK_REPO}/lib/session.sh'
        source '${TWK_REPO}/lib/display.sh'
        export TWK_DATA_DIR='${TWK_DATA_DIR}'
        export PATH='${PATH}'
        fetch_current_sprint_items() { cat <<'JSON'
$(cat <<'EOFINNER'
{ "value": [
  { "id": 100, "fields": { "System.WorkItemType": "Task",    "System.Title": "Short title",                                                                          "System.State": "Active" } },
  { "id": 200, "fields": { "System.WorkItemType": "Bug",     "System.Title": "This is a very long title that exceeds forty characters total length easily", "System.State": "Active" } },
  { "id": 300, "fields": { "System.WorkItemType": "Feature", "System.Title": "Feature C",                                                                            "System.State": "Active" } }
] }
EOFINNER
)
JSON
        }
        echo 1 | resolve_interactive
    "
    assert_status 0
    # hidden-running notice goes to stderr, but bats captures combined under run.
    assert_output_contains "1 running session hidden"
    # Selected id should be 200.
    assert_output_contains "200"
    # The truncated long title (40 chars including '...') must appear.
    assert_output_contains "This is a very long title that exceed..."
}

@test "resolve_interactive: paused sessions render with 'paused HH:MM:SS' suffix" {
    require_binary jq

    # Single sprint item, paused locally with 600 seconds elapsed.
    local now hour_ago
    now="$(date +%s)"
    hour_ago=$(( now - 600 ))
    {
        echo "start|${hour_ago}"
        echo "pause|${now}"
    } > "${TWK_DATA_DIR}/100.session"

    run bash -c "
        source '${TWK_REPO}/lib/config.sh'
        source '${TWK_REPO}/lib/azdo.sh'
        source '${TWK_REPO}/lib/resolve.sh'
        source '${TWK_REPO}/lib/session.sh'
        source '${TWK_REPO}/lib/display.sh'
        export TWK_DATA_DIR='${TWK_DATA_DIR}'
        export PATH='${PATH}'
        fetch_current_sprint_items() {
            printf '%s\n' '{\"value\":[{\"id\":100,\"fields\":{\"System.WorkItemType\":\"Task\",\"System.Title\":\"Paused item\",\"System.State\":\"Active\"}}]}'
        }
        echo 1 | resolve_interactive
    "
    assert_status 0
    assert_output_contains "paused"
    assert_output_contains "00:10:00"
}

@test "resolve_interactive: rc=1 with helpful error when every sprint item is currently running" {
    require_binary jq

    local now
    now="$(date +%s)"
    # Both sprint items have running sessions locally.
    echo "start|${now}" > "${TWK_DATA_DIR}/100.session"
    echo "start|${now}" > "${TWK_DATA_DIR}/200.session"

    run bash -c "
        source '${TWK_REPO}/lib/config.sh'
        source '${TWK_REPO}/lib/azdo.sh'
        source '${TWK_REPO}/lib/resolve.sh'
        source '${TWK_REPO}/lib/session.sh'
        source '${TWK_REPO}/lib/display.sh'
        export TWK_DATA_DIR='${TWK_DATA_DIR}'
        export PATH='${PATH}'
        fetch_current_sprint_items() {
            printf '%s' '{\"value\":[{\"id\":100,\"fields\":{\"System.WorkItemType\":\"Task\",\"System.Title\":\"a\",\"System.State\":\"Active\"}},{\"id\":200,\"fields\":{\"System.WorkItemType\":\"Task\",\"System.Title\":\"b\",\"System.State\":\"Active\"}}]}'
        }
        resolve_interactive </dev/null
    "
    assert_status 1
    assert_output_contains "every sprint item is currently being tracked"
}

@test "resolve_interactive: titles longer than 40 chars are truncated with '...'" {
    require_binary jq

    run bash -c "
        source '${TWK_REPO}/lib/config.sh'
        source '${TWK_REPO}/lib/azdo.sh'
        source '${TWK_REPO}/lib/resolve.sh'
        source '${TWK_REPO}/lib/session.sh'
        source '${TWK_REPO}/lib/display.sh'
        export TWK_DATA_DIR='${TWK_DATA_DIR}'
        export PATH='${PATH}'
        fetch_current_sprint_items() {
            printf '%s' '{\"value\":[{\"id\":100,\"fields\":{\"System.WorkItemType\":\"Task\",\"System.Title\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\",\"System.State\":\"Active\"}}]}'
        }
        echo 1 | resolve_interactive
    "
    assert_status 0
    # 37 As followed by '...' = 40 chars total.
    assert_output_contains "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA..."
    # The original 42-A title should NOT appear in the output.
    assert_output_not_contains "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
}

@test "resolve_interactive: shows assigned displayName column for each item" {
    require_binary jq

    run bash -c "
        source '${TWK_REPO}/lib/config.sh'
        source '${TWK_REPO}/lib/azdo.sh'
        source '${TWK_REPO}/lib/resolve.sh'
        source '${TWK_REPO}/lib/session.sh'
        source '${TWK_REPO}/lib/display.sh'
        export TWK_DATA_DIR='${TWK_DATA_DIR}'
        export PATH='${PATH}'
        fetch_current_sprint_items() { cat <<'JSON'
$(cat <<'EOFINNER'
{ "value": [
  { "id": 401, "fields": { "System.WorkItemType": "Task", "System.Title": "Login bug",       "System.State": "Active", "System.AssignedTo": {"displayName": "Luke McCann"} } },
  { "id": 402, "fields": { "System.WorkItemType": "Task", "System.Title": "Refactor auth",   "System.State": "Doing",  "System.AssignedTo": {"displayName": "Sarah Khan"} } },
  { "id": 403, "fields": { "System.WorkItemType": "Task", "System.Title": "Audit code paths","System.State": "New" } }
] }
EOFINNER
)
JSON
        }
        echo 1 | resolve_interactive
    "
    assert_status 0
    # Assigned names appear on their respective rows.
    assert_output_contains "Luke McCann"
    assert_output_contains "Sarah Khan"
    # Unassigned third row renders '-' as the assignee.
    assert_output_contains " -"
    # The numbered row order matches the input order, so the selected ID
    # should be 401 (the first item).
    [[ "${output}" == *"401"* ]] || { echo "expected 401 in output"; return 1; }
}

@test "resolve_interactive: long assignee names truncate at 15 chars with '...'" {
    require_binary jq

    run bash -c "
        source '${TWK_REPO}/lib/config.sh'
        source '${TWK_REPO}/lib/azdo.sh'
        source '${TWK_REPO}/lib/resolve.sh'
        source '${TWK_REPO}/lib/session.sh'
        source '${TWK_REPO}/lib/display.sh'
        export TWK_DATA_DIR='${TWK_DATA_DIR}'
        export PATH='${PATH}'
        fetch_current_sprint_items() { cat <<'JSON'
$(cat <<'EOFINNER'
{ "value": [
  { "id": 500, "fields": { "System.WorkItemType": "Task", "System.Title": "T",
    "System.State": "Active",
    "System.AssignedTo": {"displayName": "Maximilian Bartholomew Cunningham"} } }
] }
EOFINNER
)
JSON
        }
        echo 1 | resolve_interactive
    "
    assert_status 0
    [[ "${output}" == *"Maximilian"* ]] || { echo "no head: ${output}"; return 1; }
    [[ "${output}" == *"..."* ]] || { echo "no truncation suffix"; return 1; }
    [[ "${output}" != *"Cunningham"* ]] || { echo "tail not truncated"; return 1; }
}

@test "resolve_interactive: rc=1 when sprint contains no items" {
    require_binary jq

    run bash -c "
        source '${TWK_REPO}/lib/config.sh'
        source '${TWK_REPO}/lib/azdo.sh'
        source '${TWK_REPO}/lib/resolve.sh'
        source '${TWK_REPO}/lib/session.sh'
        source '${TWK_REPO}/lib/display.sh'
        export TWK_DATA_DIR='${TWK_DATA_DIR}'
        export PATH='${PATH}'
        fetch_current_sprint_items() {
            printf '%s' '{\"value\":[]}'
        }
        resolve_interactive </dev/null
    "
    assert_status 1
    assert_output_contains "no work items"
}

# -----------------------------------------------------------------------------
# fetch_current_sprint_items — orchestrates three AzDO endpoints:
#   azdo_fetch_current_iteration   → .value[0].id
#   azdo_fetch_iteration_work_items → [.workItemRelations[].target.id] | unique
#   azdo_fetch_work_items_batch     → final response
#
# Round-2 review #5: the resolve_interactive tests above stub
# fetch_current_sprint_items directly, bypassing this orchestration. These
# tests drop fixtures into MOCK_AZDO_FIXTURES_DIR and let the real function
# run through the public mock-azdo layer to lock in the wiring.
# -----------------------------------------------------------------------------

@test "fetch_current_sprint_items: happy path returns batch response with work items" {
    require_binary jq

    export MOCK_AZDO_FIXTURES_DIR="${TWK_BATS_TMP}/fixtures/sprint"
    mkdir -p "${MOCK_AZDO_FIXTURES_DIR}"

    cat > "${MOCK_AZDO_FIXTURES_DIR}/current_iteration.json" <<'EOF'
{ "value": [ { "id": "iter-abc123", "name": "Sprint 7" } ] }
EOF
    cat > "${MOCK_AZDO_FIXTURES_DIR}/iteration_iter-abc123_items.json" <<'EOF'
{
  "workItemRelations": [
    { "target": { "id": 100 } },
    { "target": { "id": 200 } },
    { "target": { "id": 100 } }
  ]
}
EOF
    cat > "${MOCK_AZDO_FIXTURES_DIR}/batch_response.json" <<'EOF'
{ "value": [
    { "id": 100, "fields": { "System.WorkItemType": "Task", "System.Title": "Item 100", "System.State": "Active" } },
    { "id": 200, "fields": { "System.WorkItemType": "Bug",  "System.Title": "Item 200", "System.State": "Active" } }
] }
EOF

    run fetch_current_sprint_items
    assert_status 0
    assert_output_contains '"id": 100'
    assert_output_contains '"id": 200'
    assert_output_contains "Item 100"
    assert_output_contains "Item 200"

    # All three public AzDO functions should have been called in order.
    [[ "$(mock_azdo_call_count azdo_fetch_current_iteration)" -eq 1 ]]
    [[ "$(mock_azdo_call_count azdo_fetch_iteration_work_items)" -eq 1 ]]
    [[ "$(mock_azdo_call_count azdo_fetch_work_items_batch)" -eq 1 ]]

    # The iteration id must have been forwarded as the work-items arg.
    [[ "$(mock_azdo_call_args azdo_fetch_iteration_work_items)" == "iter-abc123" ]] \
        || { echo "iteration id not forwarded; got: $(mock_azdo_call_args azdo_fetch_iteration_work_items)" >&2; return 1; }

    # The batch call should have been invoked with a unique-sorted JSON array
    # of ids. With 100,200,100 in the relations, unique → [100, 200]. jq's
    # default (non-compact) output is multi-line; the mock_azdo log loses
    # content past the first newline of the arg, so we read the whole call
    # log directly to verify the ids are present.
    local call_log_content
    call_log_content="$(cat "${MOCK_AZDO_CALL_LOG}")"
    [[ "${call_log_content}" == *"100"* && "${call_log_content}" == *"200"* ]] \
        || { echo "expected ids 100 and 200 in batch payload; log:"; echo "${call_log_content}"; return 1; }
}

@test "fetch_current_sprint_items: rc=1 with 'no current iteration' when iteration response is empty" {
    require_binary jq

    export MOCK_AZDO_FIXTURES_DIR="${TWK_BATS_TMP}/fixtures/sprint_empty_iter"
    mkdir -p "${MOCK_AZDO_FIXTURES_DIR}"

    # Empty .value array — no current iteration.
    cat > "${MOCK_AZDO_FIXTURES_DIR}/current_iteration.json" <<'EOF'
{ "value": [] }
EOF

    run fetch_current_sprint_items
    assert_status 1
    assert_output_contains "no current iteration"
    # Must NOT have proceeded to fetch items or batch.
    [[ "$(mock_azdo_call_count azdo_fetch_iteration_work_items)" -eq 0 ]]
    [[ "$(mock_azdo_call_count azdo_fetch_work_items_batch)" -eq 0 ]]
}

@test "resolve_self: returns principalName from connectionData" {
    require_binary jq

    azdo_fetch_authenticated_user() {
        printf '%s' '{"authenticatedUser":{"principalName":"luke@example.com","displayName":"Luke McCann"}}'
    }

    run resolve_self
    assert_status 0
    [[ "${output}" == "luke@example.com" ]] || { echo "got: ${output}"; return 1; }
}

@test "resolve_self: falls back to mailAddress when principalName is missing" {
    require_binary jq

    azdo_fetch_authenticated_user() {
        printf '%s' '{"authenticatedUser":{"mailAddress":"luke@example.com"}}'
    }

    run resolve_self
    assert_status 0
    [[ "${output}" == "luke@example.com" ]] || { echo "got: ${output}"; return 1; }
}

@test "resolve_self: errors when fetch fails" {
    azdo_fetch_authenticated_user() { return 1; }

    run resolve_self
    assert_status 1
    assert_output_contains "could not query authenticated user"
}

@test "resolve_self: errors when response has no identifiable user" {
    require_binary jq

    azdo_fetch_authenticated_user() {
        printf '%s' '{"authenticatedUser":{}}'
    }

    run resolve_self
    assert_status 1
    assert_output_contains "could not extract your identity"
}

@test "resolve_user_interactive: org scope auto-selects single user from Graph API" {
    require_binary jq

    azdo_fetch_org_users() {
        printf '%s' '{"value":[
            {"subjectKind":"user","displayName":"Solo","principalName":"solo@example.com"}
        ]}'
    }

    run resolve_user_interactive org
    assert_status 0
    [[ "${output}" == "solo@example.com" ]] || { echo "got: ${output}"; return 1; }
}

@test "resolve_user_interactive: org scope filters out non-user subjects" {
    require_binary jq

    azdo_fetch_org_users() {
        printf '%s' '{"value":[
            {"subjectKind":"group","displayName":"Team","principalName":"team@example.com"},
            {"subjectKind":"user","displayName":"Real Person","principalName":"real@example.com"}
        ]}'
    }

    run resolve_user_interactive org
    assert_status 0
    # Only the user (auto-selected since it's the only one) is returned.
    [[ "${output}" == "real@example.com" ]] || { echo "got: ${output}"; return 1; }
}

@test "resolve_user_interactive: org scope error mentions PAT scope when fetch fails" {
    azdo_fetch_org_users() { return 1; }

    run resolve_user_interactive org
    assert_status 1
    assert_output_contains "Graph"
}

@test "resolve_user_interactive: rejects unknown scope" {
    run resolve_user_interactive bogus
    assert_status 1
    assert_output_contains "unknown user scope"
}

@test "resolve_user_interactive: errors when sprint has no assigned users" {
    require_binary jq

    fetch_current_sprint_items() {
        printf '%s' '{"value":[
            {"id":1,"fields":{"System.Title":"Unassigned"}}
        ]}'
    }

    run resolve_user_interactive
    assert_status 1
    assert_output_contains "no users assigned to current sprint"
}

@test "resolve_user_interactive: auto-selects when exactly one user is assigned" {
    require_binary jq

    fetch_current_sprint_items() {
        printf '%s' '{"value":[
            {"id":1,"fields":{"System.AssignedTo":{"id":"a","displayName":"Alone","uniqueName":"alone@example.com"}}}
        ]}'
    }

    run resolve_user_interactive
    assert_status 0
    [[ "${output}" == "alone@example.com" ]] || { echo "got: ${output}"; return 1; }
}

@test "resolve_user_interactive: deduplicates users assigned to multiple items" {
    require_binary jq

    fetch_current_sprint_items() {
        # Same user assigned to two items.
        printf '%s' '{"value":[
            {"id":1,"fields":{"System.AssignedTo":{"id":"a","displayName":"Alice","uniqueName":"alice@example.com"}}},
            {"id":2,"fields":{"System.AssignedTo":{"id":"a","displayName":"Alice","uniqueName":"alice@example.com"}}}
        ]}'
    }

    run resolve_user_interactive
    assert_status 0
    # Only one unique user → auto-selected.
    [[ "${output}" == "alice@example.com" ]] || { echo "got: ${output}"; return 1; }
}

@test "resolve_user_interactive: numbered list path returns the picked email" {
    require_binary jq

    fetch_current_sprint_items() {
        printf '%s' '{"value":[
            {"id":1,"fields":{"System.AssignedTo":{"id":"a","displayName":"Alice","uniqueName":"alice@example.com"}}},
            {"id":2,"fields":{"System.AssignedTo":{"id":"b","displayName":"Bob","uniqueName":"bob@example.com"}}}
        ]}'
    }

    # Pick #2 (Bob). fzf is hidden by twk_setup_env so the numbered-list
    # path runs. Feed the selection on stdin.
    run bash -c '
        source "'"${TWK_REPO}"'/lib/config.sh"
        source "'"${TWK_REPO}"'/lib/azdo.sh"
        source "'"${TWK_REPO}"'/lib/resolve.sh"
        source "'"${TWK_REPO}"'/lib/session.sh"
        source "'"${TWK_REPO}"'/lib/display.sh"
        # Hide fzf in this subshell so the numbered-list branch runs.
        command() {
            if [[ "${1:-}" == "-v" && "${2:-}" == "fzf" ]]; then return 1; fi
            builtin command "$@"
        }
        export -f command
        fetch_current_sprint_items() {
            printf "%s" '"'"'{"value":[
                {"id":1,"fields":{"System.AssignedTo":{"id":"a","displayName":"Alice","uniqueName":"alice@example.com"}}},
                {"id":2,"fields":{"System.AssignedTo":{"id":"b","displayName":"Bob","uniqueName":"bob@example.com"}}}
            ]}'"'"'
        }
        echo 2 | resolve_user_interactive
    '
    assert_status 0
    assert_output_contains "bob@example.com"
}

@test "fetch_current_sprint_items: rc=1 with 'no work items' when iteration has no relations" {
    require_binary jq

    export MOCK_AZDO_FIXTURES_DIR="${TWK_BATS_TMP}/fixtures/sprint_empty_items"
    mkdir -p "${MOCK_AZDO_FIXTURES_DIR}"

    cat > "${MOCK_AZDO_FIXTURES_DIR}/current_iteration.json" <<'EOF'
{ "value": [ { "id": "iter-empty", "name": "Sprint X" } ] }
EOF
    cat > "${MOCK_AZDO_FIXTURES_DIR}/iteration_iter-empty_items.json" <<'EOF'
{ "workItemRelations": [] }
EOF

    run fetch_current_sprint_items
    assert_status 1
    assert_output_contains "no work items in current sprint"
    # Iteration id was forwarded, but batch must not have been called.
    [[ "$(mock_azdo_call_count azdo_fetch_iteration_work_items)" -eq 1 ]]
    [[ "$(mock_azdo_call_count azdo_fetch_work_items_batch)" -eq 0 ]]
}
