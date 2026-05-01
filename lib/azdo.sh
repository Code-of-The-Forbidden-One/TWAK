url_encode() {
    local string="$1"
    printf '%s' "${string}" | jq -sRr @uri
}

azdo_base_url() {
    echo "https://dev.azure.com/$(url_encode "${TWK_ORGANIZATION}")/$(url_encode "${TWK_PROJECT}")"
}

azdo_team_segment() {
    if [[ -n "${TWK_TEAM}" ]]; then
        echo "/$(url_encode "${TWK_TEAM}")"
    fi
}

azdo_api_request() {
    local method="$1"
    local url="$2"
    local body="${3:-}"

    local auth_header
    auth_header="$(printf '%s' ":${TWK_PAT}" | base64 -w 0)"

    local curl_args=(
        --silent
        --fail
        --show-error
        --location
        --connect-timeout 10
        --max-time 30
        --header "Authorization: Basic ${auth_header}"
        --request "${method}"
    )

    if [[ -n "${body}" ]]; then
        if [[ "${method}" == "PATCH" ]]; then
            curl_args+=(--header "Content-Type: application/json-patch+json")
        else
            curl_args+=(--header "Content-Type: application/json")
        fi
        curl_args+=(--data "${body}")
    fi

    curl "${curl_args[@]}" "${url}"
}

azdo_fetch_authenticated_user() {
    # Returns the connectionData JSON, including .authenticatedUser. The
    # authenticatedUser.principalName is typically the UPN (email) and is
    # what AzDO accepts as the value for System.AssignedTo on a PATCH.
    local url
    url="https://dev.azure.com/$(url_encode "${TWK_ORGANIZATION}")/_apis/connectionData?api-version=7.1"
    azdo_api_request "GET" "${url}"
}

azdo_fetch_org_users() {
    # Org-wide user list via the Graph API (preview). Requires the PAT
    # to have at least 'Graph (Read)' scope on top of the standard
    # 'Work Items (Read & Write)'. Returns a JSON object with a 'value'
    # array of user descriptors.
    local url
    url="https://vssps.dev.azure.com/$(url_encode "${TWK_ORGANIZATION}")/_apis/graph/users?api-version=7.1-preview.1"
    azdo_api_request "GET" "${url}"
}

azdo_test_connection() {
    local url
    url="https://dev.azure.com/$(url_encode "${TWK_ORGANIZATION}")/_apis/projects?api-version=7.1"
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
        "Microsoft.VSTS.Scheduling.RemainingWork",
        "Microsoft.VSTS.Scheduling.StartDate",
        "Microsoft.VSTS.Scheduling.TargetDate"
    ]
}
EOF
    )
    azdo_api_request "POST" "${url}" "${body}"
}

azdo_fetch_sprint_with_details() {
    local ids_json="$1"

    local url
    url="$(azdo_base_url)/_apis/wit/workitemsbatch?api-version=7.1"

    local body
    body="$(jq -nc \
        --arg t "${TWK_TIME_FIELD_TASK}" \
        --arg f "${TWK_TIME_FIELD_FEATURE}" \
        --argjson ids "${ids_json}" '
        {
            ids: $ids,
            fields: ([
                "System.Id",
                "System.Title",
                "System.Description",
                "System.WorkItemType",
                "System.State",
                "System.AssignedTo",
                "Microsoft.VSTS.Common.Priority",
                "Microsoft.VSTS.Scheduling.OriginalEstimate",
                $t,
                $f
            ] | unique)
        }
    ')"

    azdo_api_request "POST" "${url}" "${body}"
}

azdo_fetch_existing_times() {
    local ids_json="$1"

    local url
    url="$(azdo_base_url)/_apis/wit/workitemsbatch?api-version=7.1"

    local body
    body="$(jq -nc \
        --arg t "${TWK_TIME_FIELD_TASK}" \
        --arg f "${TWK_TIME_FIELD_FEATURE}" \
        --argjson ids "${ids_json}" '
        {
            ids: $ids,
            fields: (["System.Id", "System.WorkItemType", $t, $f] | unique)
        }
    ')"

    azdo_api_request "POST" "${url}" "${body}"
}

azdo_fetch_work_item_meta() {
    local work_item_id="$1"

    local work_item_json
    work_item_json="$(azdo_fetch_work_item "${work_item_id}" 2>/dev/null)" || return 1

    printf '%s' "${work_item_json}" | jq -c '{
        title: (.fields["System.Title"] // ""),
        type:  (.fields["System.WorkItemType"] // "")
    }'
}

azdo_resolve_time_field() {
    local work_item_id="$1"

    local work_item_json
    work_item_json="$(azdo_fetch_work_item "${work_item_id}" 2>/dev/null)" || {
        echo "${TWK_TIME_FIELD_TASK}"
        return
    }

    local work_item_type
    work_item_type="$(echo "${work_item_json}" | jq -r '.fields["System.WorkItemType"]')"

    case "${work_item_type}" in
        Feature)  echo "${TWK_TIME_FIELD_FEATURE}" ;;
        *)        echo "${TWK_TIME_FIELD_TASK}" ;;
    esac
}

azdo_update_assigned_to() {
    local work_item_id="$1"
    local user="$2"
    validate_work_item_id "${work_item_id}" || return 1

    local url
    url="$(azdo_base_url)/_apis/wit/workitems/${work_item_id}?api-version=7.1"

    # JSON-encode the user string via jq so quotes / special characters
    # in display names don't corrupt the patch body.
    local body
    body="$(jq -nc --arg u "${user}" '[{op:"replace",path:"/fields/System.AssignedTo",value:$u}]')"

    azdo_api_request "PATCH" "${url}" "${body}"
}

azdo_update_state() {
    local work_item_id="$1"
    local new_state="$2"
    validate_work_item_id "${work_item_id}" || return 1

    local url
    url="$(azdo_base_url)/_apis/wit/workitems/${work_item_id}?api-version=7.1"

    local body
    body=$(cat <<EOF
[
    {
        "op": "replace",
        "path": "/fields/System.State",
        "value": "${new_state}"
    }
]
EOF
    )
    azdo_api_request "PATCH" "${url}" "${body}" > /dev/null 2>&1
}

azdo_update_time_spent() {
    local work_item_id="$1"
    local hours="$2"
    local time_field="$3"
    validate_work_item_id "${work_item_id}" || return 1

    local url
    url="$(azdo_base_url)/_apis/wit/workitems/${work_item_id}?api-version=7.1"

    local body
    body=$(cat <<EOF
[
    {
        "op": "replace",
        "path": "/fields/${time_field}",
        "value": ${hours}
    }
]
EOF
    )
    azdo_api_request "PATCH" "${url}" "${body}"
}
