# lib/azdo.sh — the Azure DevOps REST client.
#
# Every request goes through azdo_api_request, which:
#   - hands the credential to curl on stdin (curl's --config -), never on
#     the command line, so it cannot be read from `ps` or /proc;
#   - authenticates with a PAT (TWK_AUTH=pat) or with an Entra ID token
#     from the Azure CLI (TWK_AUTH=azcli);
#   - retries throttling (429) and, for requests that are safe to repeat,
#     server errors and network failures;
#   - prints Azure DevOps's own error message on failure;
#   - strips terminal control characters from every response, so text
#     written by other people (titles, descriptions, comments) cannot
#     drive the user's terminal.
#
# Exit codes of azdo_api_request (and of every function that ends in it):
#   0  success
#   1  Azure DevOps refused the request (4xx): it was not applied
#   2  outcome unknown (network failure or 5xx after retries)

# The Entra ID resource (application) ID of Azure DevOps. Fixed by
# Microsoft; the same for every organisation.
readonly AZDO_RESOURCE_ID="499b84ac-1321-427f-aa17-267ca6975798"
readonly AZDO_MAX_ATTEMPTS=4
readonly AZDO_BATCH_LIMIT=200
readonly AZDO_RC_REFUSED=1
readonly AZDO_RC_UNKNOWN=2

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

azdo_access_token() {
    # Prints an Entra ID access token for Azure DevOps from the Azure CLI.
    # Cached in TWK_TOKEN_CACHE (a file in a private directory that
    # bin/twk creates and removes on exit) so one twk invocation asks az
    # once, even though requests run in command substitutions.
    if [[ -n "${TWK_TOKEN_CACHE:-}" ]] && [[ -s "${TWK_TOKEN_CACHE}" ]]; then
        cat "${TWK_TOKEN_CACHE}"
        return
    fi

    if ! command -v az &> /dev/null; then
        echo "Error: TWK_AUTH=azcli but the Azure CLI ('az') is not installed." >&2
        return 1
    fi

    local token
    if ! token="$(az account get-access-token \
            --resource "${AZDO_RESOURCE_ID}" \
            --query accessToken --output tsv 2>/dev/null)" || [[ -z "${token}" ]]; then
        echo "Error: could not get an Azure DevOps token from the Azure CLI." >&2
        echo "       Run 'az login' and try again." >&2
        return 1
    fi

    if [[ -n "${TWK_TOKEN_CACHE:-}" ]]; then
        ( umask 077; printf '%s' "${token}" > "${TWK_TOKEN_CACHE}" )
    fi
    printf '%s' "${token}"
}

azdo_auth_header() {
    # Prints the Authorization header for the configured auth mode.
    case "${TWK_AUTH:-pat}" in
        azcli)
            local token
            token="$(azdo_access_token)" || return 1
            printf 'Authorization: Bearer %s' "${token}"
            ;;
        pat)
            if [[ -z "${TWK_PAT:-}" ]]; then
                echo "Error: no Personal Access Token configured. Run 'twk init'." >&2
                return 1
            fi
            # `tr -d '\n'` rather than GNU-only `base64 -w 0`.
            printf 'Authorization: Basic %s' \
                "$(printf '%s' ":${TWK_PAT}" | base64 | tr -d '\n')"
            ;;
        *)
            echo "Error: unknown TWK_AUTH '${TWK_AUTH}'. Use 'pat' or 'azcli'." >&2
            return 1
            ;;
    esac
}

azdo_sanitise_json() {
    # Removes C0/C1 control characters (bar tab and newline) from every
    # string in a JSON document. Non-JSON input is passed through.
    local json="$1"
    if [[ -z "${json}" ]]; then
        return
    fi
    printf '%s' "${json}" | jq -c '
        def clean:
            if type == "string" then
                explode
                | map(select(. == 9 or . == 10
                    or (. >= 32 and . != 127 and (. < 128 or . > 159))))
                | implode
            elif type == "array" then map(clean)
            elif type == "object" then map_values(clean)
            else . end;
        clean
    ' 2>/dev/null || printf '%s' "${json}"
}

azdo_error_message() {
    # Prints a one-line reason for a failed request from the status and
    # the response body (Azure DevOps puts it in .message).
    local status="$1"
    local body="$2"

    local message=""
    if [[ -n "${body}" ]]; then
        message="$(printf '%s' "${body}" | jq -r '.message // empty' 2>/dev/null | head -n 1)"
        message="$(printf '%s' "${message}" | tr -d '\000-\010\013-\037\177')"
    fi

    local hint=""
    case "${status}" in
        401) hint="authentication failed: check your PAT, or run 'az login' (TWK_AUTH=azcli)" ;;
        403) hint="permission denied: your account or PAT lacks the scope for this" ;;
        404) hint="not found: check the organisation, project, team, or work item ID" ;;
        429) hint="Azure DevOps is throttling requests; try again shortly" ;;
    esac

    if [[ -n "${message}" ]] && [[ -n "${hint}" ]]; then
        printf 'HTTP %s, %s (%s)' "${status}" "${hint}" "${message}"
    elif [[ -n "${message}" ]]; then
        printf 'HTTP %s: %s' "${status}" "${message}"
    elif [[ -n "${hint}" ]]; then
        printf 'HTTP %s, %s' "${status}" "${hint}"
    else
        printf 'HTTP %s' "${status}"
    fi
}

azdo_request_is_repeatable() {
    # A request may be retried after an unknown outcome only if repeating
    # it cannot apply it twice: reads, and the batch read (a POST).
    local method="$1"
    local url="$2"
    [[ "${method}" == "GET" ]] || [[ "${url}" == *"/_apis/wit/workitemsbatch"* ]]
}

azdo_curl() {
    # One HTTP exchange. Prints the body, a newline, then the status code.
    # The Authorization header is read from stdin as curl config.
    local method="$1"
    local url="$2"
    local body="$3"
    local auth_header="$4"

    local curl_args=(
        --silent
        --show-error
        --location
        --connect-timeout 10
        --max-time 30
        --request "${method}"
        --write-out '\n%{http_code}'
        --config -
    )

    if [[ -n "${body}" ]]; then
        if [[ "${method}" == "PATCH" ]]; then
            curl_args+=(--header "Content-Type: application/json-patch+json")
        else
            curl_args+=(--header "Content-Type: application/json")
        fi
        curl_args+=(--data-binary "${body}")
    fi

    printf 'header = "%s"\n' "${auth_header}" | curl "${curl_args[@]}" "${url}"
}

azdo_api_request() {
    local method="$1"
    local url="$2"
    local body="${3:-}"

    local auth_header
    auth_header="$(azdo_auth_header)" || return "${AZDO_RC_REFUSED}"

    local repeatable=false
    if azdo_request_is_repeatable "${method}" "${url}"; then
        repeatable=true
    fi

    local attempt=1
    local response status response_body retry
    while true; do
        retry=false
        if response="$(azdo_curl "${method}" "${url}" "${body}" "${auth_header}")"; then
            status="${response##*$'\n'}"
            response_body="${response%$'\n'*}"
            [[ "${response}" == *$'\n'* ]] || response_body=""

            if [[ "${status}" =~ ^2[0-9][0-9]$ ]]; then
                azdo_sanitise_json "${response_body}"
                return 0
            fi

            if [[ "${status}" == "429" ]]; then
                retry=true
            elif [[ "${status}" =~ ^5[0-9][0-9]$ ]] && [[ "${repeatable}" == true ]]; then
                retry=true
            fi
        else
            status=""
            response_body=""
            [[ "${repeatable}" == true ]] && retry=true
        fi

        if [[ "${retry}" == true ]] && (( attempt < AZDO_MAX_ATTEMPTS )); then
            sleep "$(( ${TWK_RETRY_BASE_DELAY:-1} * (1 << (attempt - 1)) ))"
            attempt=$(( attempt + 1 ))
            continue
        fi
        break
    done

    local where="${url%%\?*}"
    if [[ -z "${status}" ]] || [[ "${status}" == "000" ]]; then
        echo "Error: could not reach Azure DevOps (${where})." >&2
        return "${AZDO_RC_UNKNOWN}"
    fi

    echo "Error: ${method} ${where} failed: $(azdo_error_message "${status}" "${response_body}")" >&2
    if [[ "${status}" =~ ^5[0-9][0-9]$ ]]; then
        return "${AZDO_RC_UNKNOWN}"
    fi
    return "${AZDO_RC_REFUSED}"
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
    azdo_api_request "GET" "${url}" > /dev/null
}

azdo_fetch_current_iteration() {
    local url
    url="$(azdo_base_url)$(azdo_team_segment)/_apis/work/teamsettings/iterations?\$timeframe=current&api-version=7.1"
    azdo_api_request "GET" "${url}"
}

azdo_fetch_iteration_work_items() {
    local iteration_id="$1"

    local url
    url="$(azdo_base_url)$(azdo_team_segment)/_apis/work/teamsettings/iterations/$(url_encode "${iteration_id}")/workitems?api-version=7.1"
    azdo_api_request "GET" "${url}"
}

azdo_fetch_work_item() {
    local work_item_id="$1"
    validate_work_item_id "${work_item_id}" || return 1

    local url
    url="$(azdo_base_url)/_apis/wit/workitems/${work_item_id}?\$expand=fields&api-version=7.1"
    azdo_api_request "GET" "${url}"
}

azdo_fetch_comments() {
    local work_item_id="$1"
    validate_work_item_id "${work_item_id}" || return 1

    local url
    url="$(azdo_base_url)/_apis/wit/workitems/${work_item_id}/comments?api-version=7.1-preview.4"
    azdo_api_request "GET" "${url}"
}

azdo_post_comment() {
    local work_item_id="$1"
    local text="$2"
    validate_work_item_id "${work_item_id}" || return 1

    local url
    url="$(azdo_base_url)/_apis/wit/workitems/${work_item_id}/comments?api-version=7.1-preview.4"

    # jq builds the JSON body so any quotes/newlines/special chars in
    # the comment body are escaped correctly.
    local body
    body="$(jq -nc --arg t "${text}" '{text: $t}')"

    azdo_api_request "POST" "${url}" "${body}"
}

azdo_fetch_batch() {
    # Fetches the given fields for any number of work items. The batch
    # endpoint takes at most 200 IDs, so larger lists are split and the
    # pages merged into one {count, value} document.
    local ids_json="$1"
    local fields_json="$2"

    local url
    url="$(azdo_base_url)/_apis/wit/workitemsbatch?api-version=7.1"

    local chunks
    chunks="$(printf '%s' "${ids_json}" | jq -c --argjson n "${AZDO_BATCH_LIMIT}" \
        '. as $ids | range(0; $ids | length; $n) | $ids[. : . + $n]')" || return 1

    local pages=""
    local chunk body page
    while IFS= read -r chunk; do
        [[ -z "${chunk}" ]] && continue
        body="$(jq -nc --argjson ids "${chunk}" --argjson f "${fields_json}" \
            '{ids: $ids, fields: ($f | unique)}')"
        page="$(azdo_api_request "POST" "${url}" "${body}")" || return
        pages+="${page}"$'\n'
    done <<< "${chunks}"

    printf '%s' "${pages}" | jq -sc '{
        count: (map(.value | length) | add // 0),
        value: (map(.value) | add // [])
    }'
}

azdo_fetch_work_items_batch() {
    local ids_json="$1"
    azdo_fetch_batch "${ids_json}" '[
        "System.Id",
        "System.Title",
        "System.WorkItemType",
        "System.State",
        "System.AssignedTo",
        "Microsoft.VSTS.Scheduling.RemainingWork",
        "Microsoft.VSTS.Scheduling.StartDate",
        "Microsoft.VSTS.Scheduling.TargetDate"
    ]'
}

azdo_fetch_sprint_with_details() {
    local ids_json="$1"
    azdo_fetch_batch "${ids_json}" "$(jq -nc \
        --arg t "${TWK_TIME_FIELD_TASK}" \
        --arg f "${TWK_TIME_FIELD_FEATURE}" '[
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
        ]')"
}

azdo_fetch_existing_times() {
    local ids_json="$1"
    azdo_fetch_batch "${ids_json}" "$(jq -nc \
        --arg t "${TWK_TIME_FIELD_TASK}" \
        --arg f "${TWK_TIME_FIELD_FEATURE}" \
        '["System.Id", "System.WorkItemType", $t, $f]')"
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

azdo_time_field_for_type() {
    local work_item_type="$1"
    case "${work_item_type}" in
        Feature) echo "${TWK_TIME_FIELD_FEATURE}" ;;
        *)       echo "${TWK_TIME_FIELD_TASK}" ;;
    esac
}

azdo_resolve_time_field() {
    local work_item_id="$1"

    local work_item_json
    work_item_json="$(azdo_fetch_work_item "${work_item_id}" 2>/dev/null)" || {
        echo "${TWK_TIME_FIELD_TASK}"
        return
    }

    azdo_time_field_for_type \
        "$(printf '%s' "${work_item_json}" | jq -r '.fields["System.WorkItemType"] // ""')"
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
    body="$(jq -nc --arg s "${new_state}" '[{op:"replace",path:"/fields/System.State",value:$s}]')"

    azdo_api_request "PATCH" "${url}" "${body}" > /dev/null
}

azdo_update_time_spent() {
    # Sets <time_field> to <hours> (a decimal such as "1.50").
    # When <rev> is given, the patch first tests that the work item is
    # still at that revision, so a change made by someone else since it
    # was read makes the update fail instead of being overwritten.
    local work_item_id="$1"
    local hours="$2"
    local time_field="$3"
    local rev="${4:-}"
    validate_work_item_id "${work_item_id}" || return 1

    if [[ ! "${hours}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "Error: invalid hours value '${hours}'." >&2
        return 1
    fi
    if [[ -n "${rev}" ]] && [[ ! "${rev}" =~ ^[0-9]+$ ]]; then
        echo "Error: invalid revision '${rev}'." >&2
        return 1
    fi

    local url
    url="$(azdo_base_url)/_apis/wit/workitems/${work_item_id}?api-version=7.1"

    local body
    body="$(jq -nc \
        --arg field "${time_field}" \
        --argjson hours "${hours}" \
        --arg rev "${rev}" '
        (if $rev == "" then [] else [{op: "test", path: "/rev", value: ($rev | tonumber)}] end)
        + [{op: "replace", path: ("/fields/" + $field), value: $hours}]
    ')"

    azdo_api_request "PATCH" "${url}" "${body}"
}
