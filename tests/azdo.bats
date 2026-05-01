#!/usr/bin/env bats
# shellcheck disable=SC2329,SC2034
#   SC2329: stub function definitions are invoked indirectly by SUT
#   SC2034: TWK_* env vars are sourced/exported by other lib code
#
# Tests for lib/azdo.sh — url_encode, base/team URL builders, and the
# resolve_time_field Task vs Feature dispatch.
#
# We don't mock any function here; we want to exercise the real azdo.sh
# implementations (which only touch jq for url_encode and the meta filter).
# The actual HTTP-issuing functions (azdo_api_request, azdo_test_connection,
# the fetchers) are tested via the integration test where the mock does the
# heavy lifting.

load 'helpers/setup.bash'
load 'helpers/mock_azdo.bash'

setup() {
    twk_setup_env
    twk_source_libs
    twk_load_stub_path
    require_binary jq
    twk_write_fake_config
}

# -----------------------------------------------------------------------------
# url_encode — wraps jq's @uri filter.
# -----------------------------------------------------------------------------

@test "url_encode: empty string" {
    run url_encode ""
    assert_status 0
    [[ "${output}" == "" ]]
}

@test "url_encode: alphanumeric is unchanged" {
    run url_encode "abcXYZ012"
    [[ "${output}" == "abcXYZ012" ]]
}

@test "url_encode: spaces become %20" {
    run url_encode "a b c"
    [[ "${output}" == "a%20b%20c" ]]
}

@test "url_encode: ampersand and equals get encoded" {
    run url_encode "a=b&c=d"
    [[ "${output}" == "a%3Db%26c%3Dd" ]]
}

@test "url_encode: slash gets encoded" {
    run url_encode "team/sub"
    [[ "${output}" == "team%2Fsub" ]]
}

@test "url_encode: unicode characters are percent-encoded as UTF-8" {
    run url_encode "café"
    # é is U+00E9 → UTF-8 bytes c3 a9 → %C3%A9.
    [[ "${output}" == "caf%C3%A9" ]] \
        || { echo "got: ${output}" >&2; return 1; }
}

# -----------------------------------------------------------------------------
# azdo_base_url / azdo_team_segment — must percent-encode org, project, team.
# -----------------------------------------------------------------------------

@test "azdo_base_url: composes https://dev.azure.com/<org>/<project>" {
    run azdo_base_url
    assert_status 0
    [[ "${output}" == "https://dev.azure.com/fakeorg/FakeProject" ]]
}

@test "azdo_base_url: encodes org with spaces" {
    TWK_ORGANIZATION="my org"
    run azdo_base_url
    [[ "${output}" == "https://dev.azure.com/my%20org/FakeProject" ]]
}

@test "azdo_team_segment: prefixes / when team is set" {
    run azdo_team_segment
    [[ "${output}" == "/FakeTeam" ]]
}

@test "azdo_team_segment: empty when team is unset" {
    TWK_TEAM=""
    run azdo_team_segment
    assert_status 0
    [[ -z "${output}" ]]
}

@test "azdo_team_segment: encodes team name with spaces" {
    TWK_TEAM="My Team"
    run azdo_team_segment
    [[ "${output}" == "/My%20Team" ]]
}

# -----------------------------------------------------------------------------
# azdo_resolve_time_field — Task vs Feature dispatch, with fallback to
# TWK_TIME_FIELD_TASK on fetch failure.
#
# Override azdo_fetch_work_item so we can drive this without going through
# the mock layer.
# -----------------------------------------------------------------------------

@test "azdo_resolve_time_field: returns FEATURE field for Feature work items" {
    azdo_fetch_work_item() {
        printf '%s' '{"fields":{"System.WorkItemType":"Feature"}}'
    }
    run azdo_resolve_time_field 100
    assert_status 0
    [[ "${output}" == "Custom.TimeSpentFeature" ]]
}

@test "azdo_resolve_time_field: returns TASK field for Task work items" {
    azdo_fetch_work_item() {
        printf '%s' '{"fields":{"System.WorkItemType":"Task"}}'
    }
    run azdo_resolve_time_field 100
    [[ "${output}" == "Custom.TimeSpent" ]]
}

@test "azdo_resolve_time_field: returns TASK field for Bug (default branch)" {
    azdo_fetch_work_item() {
        printf '%s' '{"fields":{"System.WorkItemType":"Bug"}}'
    }
    run azdo_resolve_time_field 100
    [[ "${output}" == "Custom.TimeSpent" ]]
}

@test "azdo_resolve_time_field: falls back to TASK field when fetch fails" {
    azdo_fetch_work_item() {
        return 1
    }
    run azdo_resolve_time_field 100
    assert_status 0
    [[ "${output}" == "Custom.TimeSpent" ]]
}

# -----------------------------------------------------------------------------
# azdo_fetch_work_item_meta — projection of {title, type} from the fetched
# work item JSON.
# -----------------------------------------------------------------------------

@test "azdo_fetch_work_item_meta: projects title and type from work item JSON" {
    azdo_fetch_work_item() {
        printf '%s' '{"fields":{"System.Title":"Login bug","System.WorkItemType":"Task"}}'
    }
    run azdo_fetch_work_item_meta 100
    assert_status 0
    # Output should be compact JSON containing both keys.
    assert_output_contains '"title":"Login bug"'
    assert_output_contains '"type":"Task"'
}

@test "azdo_fetch_work_item_meta: missing fields default to empty strings" {
    azdo_fetch_work_item() {
        printf '%s' '{"fields":{}}'
    }
    run azdo_fetch_work_item_meta 100
    assert_status 0
    assert_output_contains '"title":""'
    assert_output_contains '"type":""'
}

@test "azdo_fetch_work_item_meta: rc=1 when fetch fails" {
    azdo_fetch_work_item() { return 1; }
    run azdo_fetch_work_item_meta 100
    assert_status 1
}

# -----------------------------------------------------------------------------
# azdo_fetch_existing_times — POSTs to workitemsbatch with the configured time
# fields plus System.Id/Type, deduplicated when task field == feature field.
# -----------------------------------------------------------------------------

@test "azdo_fetch_sprint_with_details: POSTs with description, priority, estimate, time fields" {
    export TWK_ORGANIZATION="acme" TWK_PROJECT="Platform"
    export TWK_TIME_FIELD_TASK="Custom.TaskTime"
    export TWK_TIME_FIELD_FEATURE="Custom.FeatureTime"

    local captured_method="" captured_url="" captured_body=""
    azdo_api_request() {
        captured_method="$1"
        captured_url="$2"
        captured_body="$3"
        printf '%s' '{"value":[]}'
    }

    azdo_fetch_sprint_with_details "[10,20]"
    [[ "${captured_method}" == "POST" ]] || { echo "method: ${captured_method}"; return 1; }
    [[ "${captured_url}" == *"workitemsbatch"* ]] || { echo "url: ${captured_url}"; return 1; }
    [[ "${captured_body}" == *"System.Description"* ]] || { echo "missing description"; return 1; }
    [[ "${captured_body}" == *"System.AssignedTo"* ]] || { echo "missing assigned-to"; return 1; }
    [[ "${captured_body}" == *"Microsoft.VSTS.Common.Priority"* ]] || { echo "missing priority"; return 1; }
    [[ "${captured_body}" == *"Microsoft.VSTS.Scheduling.OriginalEstimate"* ]] || { echo "missing estimate"; return 1; }
    [[ "${captured_body}" == *"Custom.TaskTime"* ]] || { echo "missing task field"; return 1; }
    [[ "${captured_body}" == *"Custom.FeatureTime"* ]] || { echo "missing feature field"; return 1; }
    [[ "${captured_body}" == *"10"* ]] || { echo "missing id 10"; return 1; }
    [[ "${captured_body}" == *"20"* ]] || { echo "missing id 20"; return 1; }
}

@test "azdo_fetch_comments: rc=1 on invalid id without calling api_request" {
    local sentinel="${BATS_TEST_TMPDIR}/api_request_called"
    azdo_api_request() { : > "${sentinel}"; }
    run azdo_fetch_comments "abc"
    assert_status 1
    [[ ! -e "${sentinel}" ]] || { echo "api_request was unexpectedly called"; return 1; }
}

@test "azdo_fetch_comments: GETs /_apis/wit/workitems/<id>/comments" {
    export TWK_ORGANIZATION="acme" TWK_PROJECT="Platform"

    local captured_method="" captured_url=""
    azdo_api_request() {
        captured_method="$1"
        captured_url="$2"
        printf '%s' '{"comments":[]}'
    }

    azdo_fetch_comments 12345 > /dev/null
    [[ "${captured_method}" == "GET" ]] || { echo "method: ${captured_method}"; return 1; }
    [[ "${captured_url}" == *"/_apis/wit/workitems/12345/comments"* ]] || { echo "url: ${captured_url}"; return 1; }
}

@test "azdo_post_comment: rc=1 on invalid id without calling api_request" {
    local sentinel="${BATS_TEST_TMPDIR}/api_request_called"
    azdo_api_request() { : > "${sentinel}"; }
    run azdo_post_comment "abc" "hello"
    assert_status 1
    [[ ! -e "${sentinel}" ]] || { echo "api_request was unexpectedly called"; return 1; }
}

@test "azdo_post_comment: POSTs to comments endpoint with JSON-encoded text" {
    require_binary jq
    export TWK_ORGANIZATION="acme" TWK_PROJECT="Platform"

    local captured_method="" captured_url="" captured_body=""
    azdo_api_request() {
        captured_method="$1"
        captured_url="$2"
        captured_body="$3"
        printf '%s' '{"id":1,"text":"hello","createdDate":"2026-05-02T10:00:00Z"}'
    }

    azdo_post_comment 12345 "hello world" > /dev/null
    [[ "${captured_method}" == "POST" ]] || { echo "method: ${captured_method}"; return 1; }
    [[ "${captured_url}" == *"/_apis/wit/workitems/12345/comments"* ]] || { echo "url: ${captured_url}"; return 1; }
    # Body should be valid JSON containing the text.
    echo "${captured_body}" | jq -e . > /dev/null || { echo "body not JSON: ${captured_body}"; return 1; }
    [[ "${captured_body}" == *"hello world"* ]] || { echo "body: ${captured_body}"; return 1; }
}

@test "azdo_post_comment: JSON-escapes special characters in body" {
    require_binary jq
    export TWK_ORGANIZATION="acme" TWK_PROJECT="Platform"

    local captured_body=""
    azdo_api_request() { captured_body="$3"; printf '%s' '{}'; }

    azdo_post_comment 1 'has "quotes" and
newline'
    # Round-trip through jq to confirm the payload parses.
    echo "${captured_body}" | jq -e . > /dev/null
}

@test "azdo_fetch_authenticated_user: GETs /_apis/connectionData on org base" {
    export TWK_ORGANIZATION="acme"

    local captured_method="" captured_url=""
    azdo_api_request() {
        captured_method="$1"
        captured_url="$2"
        printf '%s' '{"authenticatedUser":{"principalName":"luke@example.com"}}'
    }

    azdo_fetch_authenticated_user > /dev/null
    [[ "${captured_method}" == "GET" ]] || { echo "method: ${captured_method}"; return 1; }
    [[ "${captured_url}" == *"dev.azure.com/acme/_apis/connectionData"* ]] || { echo "url: ${captured_url}"; return 1; }
}

@test "azdo_fetch_org_users: GETs vssps graph/users on org" {
    export TWK_ORGANIZATION="acme"

    local captured_method="" captured_url=""
    azdo_api_request() {
        captured_method="$1"
        captured_url="$2"
        printf '%s' '{"value":[]}'
    }

    azdo_fetch_org_users > /dev/null
    [[ "${captured_method}" == "GET" ]] || { echo "method: ${captured_method}"; return 1; }
    [[ "${captured_url}" == *"vssps.dev.azure.com/acme/_apis/graph/users"* ]] || { echo "url: ${captured_url}"; return 1; }
}

@test "azdo_update_assigned_to: rc=1 on invalid id without calling api_request" {
    local sentinel="${BATS_TEST_TMPDIR}/api_request_called"
    azdo_api_request() { : > "${sentinel}"; }
    run azdo_update_assigned_to "not-numeric" "luke@example.com"
    assert_status 1
    [[ ! -e "${sentinel}" ]] || { echo "api_request was unexpectedly called"; return 1; }
}

@test "azdo_update_assigned_to: PATCHes System.AssignedTo with the user value" {
    require_binary jq
    export TWK_ORGANIZATION="acme" TWK_PROJECT="Platform"

    local captured_method="" captured_url="" captured_body=""
    azdo_api_request() {
        captured_method="$1"
        captured_url="$2"
        captured_body="$3"
    }

    azdo_update_assigned_to 12345 "luke@example.com"
    [[ "${captured_method}" == "PATCH" ]] || { echo "method: ${captured_method}"; return 1; }
    [[ "${captured_url}" == *"workitems/12345"* ]] || { echo "url: ${captured_url}"; return 1; }
    [[ "${captured_body}" == *"System.AssignedTo"* ]] || { echo "body: ${captured_body}"; return 1; }
    [[ "${captured_body}" == *"luke@example.com"* ]] || { echo "body: ${captured_body}"; return 1; }
    [[ "${captured_body}" == *'"op":"replace"'* ]] || { echo "body: ${captured_body}"; return 1; }
}

@test "azdo_update_assigned_to: JSON-escapes user values containing quotes" {
    require_binary jq
    export TWK_ORGANIZATION="acme" TWK_PROJECT="Platform"

    local captured_body=""
    azdo_api_request() { captured_body="$3"; }

    # A display name with an embedded quote — jq must escape it.
    azdo_update_assigned_to 1 'Quoth "the" Raven'
    # The body must be valid JSON that jq can parse back.
    echo "${captured_body}" | jq -e . > /dev/null || { echo "invalid JSON: ${captured_body}"; return 1; }
}

@test "azdo_fetch_existing_times: POSTs to workitemsbatch with configured fields" {
    export TWK_ORGANIZATION="acme" TWK_PROJECT="Platform"
    export TWK_TIME_FIELD_TASK="Custom.TaskTime"
    export TWK_TIME_FIELD_FEATURE="Custom.FeatureTime"

    local captured_body=""
    local captured_url=""
    local captured_method=""
    azdo_api_request() {
        captured_method="$1"
        captured_url="$2"
        captured_body="$3"
        printf '%s' '{"value":[]}'
    }

    azdo_fetch_existing_times "[100,200]"
    [[ "${captured_method}" == "POST" ]] || { echo "method: ${captured_method}"; return 1; }
    [[ "${captured_url}" == *"workitemsbatch"* ]] || { echo "url: ${captured_url}"; return 1; }
    # Body should include both configured fields plus the standard ones.
    [[ "${captured_body}" == *"Custom.TaskTime"* ]] || { echo "body: ${captured_body}"; return 1; }
    [[ "${captured_body}" == *"Custom.FeatureTime"* ]] || { echo "body: ${captured_body}"; return 1; }
    [[ "${captured_body}" == *"System.WorkItemType"* ]] || { echo "body: ${captured_body}"; return 1; }
    # ids should be in the body.
    [[ "${captured_body}" == *"100"* ]] || { echo "body: ${captured_body}"; return 1; }
    [[ "${captured_body}" == *"200"* ]] || { echo "body: ${captured_body}"; return 1; }
}

@test "azdo_fetch_existing_times: dedupes fields when task and feature share a name" {
    export TWK_ORGANIZATION="acme" TWK_PROJECT="Platform"
    export TWK_TIME_FIELD_TASK="Microsoft.VSTS.Scheduling.CompletedWork"
    export TWK_TIME_FIELD_FEATURE="Microsoft.VSTS.Scheduling.CompletedWork"

    local captured_body=""
    azdo_api_request() {
        captured_body="$3"
        printf '%s' '{"value":[]}'
    }

    azdo_fetch_existing_times "[42]"
    # CompletedWork should appear exactly once in the fields array (jq unique).
    local count
    count="$(grep -o "CompletedWork" <<< "${captured_body}" | wc -l)"
    [[ "${count}" -eq 1 ]] || { echo "appeared ${count} times: ${captured_body}"; return 1; }
}

# -----------------------------------------------------------------------------
# azdo_update_state / azdo_update_time_spent — both validate id and build
# JSON-patch bodies.  We override azdo_api_request to capture method, url,
# body and verify the right shape was sent.
# -----------------------------------------------------------------------------

@test "azdo_update_state: rc=1 on invalid id without calling api_request" {
    # `run` executes the SUT in a subshell, so a parent-scoped `was_called=0`
    # cannot observe a child-scoped `was_called=1` mutation. Use a tmpfile
    # sentinel — the override creates it iff invoked — and assert the file
    # does not exist after the run.
    local sentinel="${BATS_TEST_TMPDIR}/api_request_called"
    azdo_api_request() { : > "${sentinel}"; return 0; }

    run azdo_update_state abc Active
    assert_status 1
    [[ ! -e "${sentinel}" ]]
}

@test "azdo_update_state: issues PATCH with System.State JSON-patch body" {
    local capture_method="" capture_url="" capture_body=""
    azdo_api_request() {
        capture_method="$1"
        capture_url="$2"
        capture_body="$3"
        return 0
    }

    azdo_update_state 100 "Code Review"

    [[ "${capture_method}" == "PATCH" ]]
    [[ "${capture_url}" == *"/_apis/wit/workitems/100"* ]]
    [[ "${capture_body}" == *'"path": "/fields/System.State"'* ]]
    [[ "${capture_body}" == *'"value": "Code Review"'* ]]
}

@test "azdo_update_time_spent: rc=1 on invalid id without calling api_request" {
    # See note on the matching update_state test above — same subshell trap.
    local sentinel="${BATS_TEST_TMPDIR}/api_request_called"
    azdo_api_request() { : > "${sentinel}"; return 0; }
    run azdo_update_time_spent abc 1.5 Custom.TimeSpent
    assert_status 1
    [[ ! -e "${sentinel}" ]]
}

@test "azdo_update_time_spent: issues PATCH with the configured time field" {
    local capture_body=""
    azdo_api_request() { capture_body="$3"; return 0; }

    azdo_update_time_spent 100 2.5 Custom.TimeSpent

    [[ "${capture_body}" == *'"path": "/fields/Custom.TimeSpent"'* ]]
    [[ "${capture_body}" == *'"value": 2.5'* ]]
}

@test "azdo_update_time_spent: numeric value is unquoted in the JSON body" {
    # AzDO's JSON-patch wants numbers unquoted for numeric fields.
    local capture_body=""
    azdo_api_request() { capture_body="$3"; return 0; }

    azdo_update_time_spent 100 3 Custom.TimeSpent
    [[ "${capture_body}" == *'"value": 3'* ]] \
        || { echo "body: ${capture_body}" >&2; return 1; }
    # Crucially no quotes around the value.
    [[ "${capture_body}" != *'"value": "3"'* ]]
}
