azdo_base_url() {
    echo "https://dev.azure.com/${TWK_ORGANIZATION}/${TWK_PROJECT}"
}

azdo_team_segment() {
    if [[ -n "${TWK_TEAM}" ]]; then
        echo "/${TWK_TEAM}"
    fi
}

azdo_api_request() {
    local method="$1"
    local url="$2"
    local body="${3:-}"

    local auth_header
    auth_header="$(printf '%s' ":${TWK_PAT}" | base64)"

    local curl_args=(
        --silent
        --fail
        --show-error
        --connect-timeout 10
        --max-time 30
        -H @<(printf 'Authorization: Basic %s' "${auth_header}")
        --header "Content-Type: application/json-patch+json"
        --request "${method}"
    )

    if [[ -n "${body}" ]]; then
        curl_args+=(--data "${body}")
    fi

    curl "${curl_args[@]}" "${url}"
}

azdo_test_connection() {
    local url
    url="$(azdo_base_url)/_apis/projects?api-version=7.1"
    azdo_api_request "GET" "${url}" > /dev/null 2>&1
}

azdo_fetch_current_iteration() {
    local url
    url="$(azdo_base_url)$(azdo_team_segment)/_apis/work/teamsettings/iterations?\$timeframe=current&api-version=7.1"
    azdo_api_request "GET" "${url}"
}

azdo_fetch_iteration_work_items() {
    local iteration_id="$1"

    local url
    url="$(azdo_base_url)$(azdo_team_segment)/_apis/work/teamsettings/iterations/${iteration_id}/workitems?api-version=7.1"
    azdo_api_request "GET" "${url}"
}

azdo_fetch_work_item() {
    local work_item_id="$1"
    validate_work_item_id "${work_item_id}" || return 1

    local url
    url="$(azdo_base_url)/_apis/wit/workitems/${work_item_id}?\$expand=fields&api-version=7.1"
    azdo_api_request "GET" "${url}"
}

azdo_fetch_work_items_batch() {
    local ids_json="$1"

    local url
    url="$(azdo_base_url)/_apis/wit/workitemsbatch?api-version=7.1"

    local body
    body=$(cat <<EOF
{
    "ids": ${ids_json},
    "fields": [
        "System.Id",
        "System.Title",
        "System.WorkItemType",
        "System.State",
        "System.AssignedTo",
        "Microsoft.VSTS.Scheduling.CompletedWork",
        "Microsoft.VSTS.Scheduling.RemainingWork",
        "Microsoft.VSTS.Scheduling.StartDate",
        "Microsoft.VSTS.Scheduling.TargetDate"
    ]
}
EOF
    )
    azdo_api_request "POST" "${url}" "${body}"
}

azdo_update_completed_work() {
    local work_item_id="$1"
    local completed_hours="$2"
    validate_work_item_id "${work_item_id}" || return 1

    local url
    url="$(azdo_base_url)/_apis/wit/workitems/${work_item_id}?api-version=7.1"

    local body
    body=$(cat <<EOF
[
    {
        "op": "replace",
        "path": "/fields/Microsoft.VSTS.Scheduling.CompletedWork",
        "value": ${completed_hours}
    }
]
EOF
    )
    azdo_api_request "PATCH" "${url}" "${body}"
}
