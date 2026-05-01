resolve_work_item() {
    local query="${1:-}"

    if [[ -z "${query}" ]]; then
        resolve_interactive
        return
    fi

    if [[ "${query}" =~ ^[0-9]+$ ]]; then
        echo "${query}"
        return
    fi

    resolve_by_title "${query}"
}

resolve_by_title() {
    local search_term="$1"
    local work_items_json

    work_items_json="$(fetch_current_sprint_items)" || return 1

    local matches
    matches="$(echo "${work_items_json}" | jq -r --arg term "${search_term}" '
        .value[]
        | select(.fields["System.Title"] | ascii_downcase | contains($term | ascii_downcase))
        | "\(.id)\t\(.fields["System.Title"])"
    ')"

    if [[ -z "${matches}" ]]; then
        echo "Error: no work items matching '${search_term}' in current sprint." >&2
        return 1
    fi

    local match_count
    match_count="$(echo "${matches}" | wc -l)"

    if [[ "${match_count}" -eq 1 ]]; then
        echo "${matches}" | cut -f1
        return
    fi

    echo "Multiple matches for '${search_term}':" >&2
    local index=1
    while IFS=$'\t' read -r item_id item_title; do
        echo "  ${index}) #${item_id} - ${item_title}" >&2
        index=$((index + 1))
    done <<< "${matches}"

    local selection
    read -rp "Select [1-${match_count}]: " selection
    if [[ -z "${selection}" ]] || [[ "${selection}" -lt 1 ]] || [[ "${selection}" -gt "${match_count}" ]]; then
        echo "Error: invalid selection." >&2
        return 1
    fi

    echo "${matches}" | sed -n "${selection}p" | cut -f1
}

resolve_interactive() {
    local work_items_json
    work_items_json="$(fetch_current_sprint_items)" || return 1

    local items_list
    items_list="$(echo "${work_items_json}" | jq -r '
        .value[]
        | "\(.id)\t\(.fields["System.WorkItemType"])\t\(.fields["System.Title"])\t\(.fields["System.State"])"
    ')"

    if [[ -z "${items_list}" ]]; then
        echo "Error: no work items found in current sprint." >&2
        return 1
    fi

    if command -v fzf &> /dev/null; then
        resolve_with_fzf "${items_list}"
    else
        resolve_with_numbered_list "${items_list}"
    fi
}

resolve_with_fzf() {
    local items_list="$1"

    local display_list
    display_list="$(echo "${items_list}" | awk -F'\t' '{ printf "#%-6s [%-12s] %-10s %s\n", $1, $2, $4, $3 }')"

    local selected
    selected="$(echo "${display_list}" | fzf --prompt="Select work item: " --height=20 --reverse)"

    if [[ -z "${selected}" ]]; then
        echo "Error: no item selected." >&2
        return 1
    fi

    echo "${selected}" | grep -oP '(?<=#)\d+'
}

resolve_with_numbered_list() {
    local items_list="$1"

    echo "Current sprint work items:" >&2
    local index=1
    while IFS=$'\t' read -r item_id item_type item_title item_state; do
        printf "  %2d) #%-6s [%-12s] %-10s %s\n" "${index}" "${item_id}" "${item_type}" "${item_state}" "${item_title}" >&2
        index=$((index + 1))
    done <<< "${items_list}"

    local total_items=$((index - 1))
    local selection
    read -rp "Select [1-${total_items}]: " selection

    if [[ -z "${selection}" ]] || [[ "${selection}" -lt 1 ]] || [[ "${selection}" -gt "${total_items}" ]]; then
        echo "Error: invalid selection." >&2
        return 1
    fi

    echo "${items_list}" | sed -n "${selection}p" | cut -f1
}

fetch_current_sprint_items() {
    local iteration_response
    iteration_response="$(azdo_fetch_current_iteration)" || {
        echo "Error: failed to fetch current iteration." >&2
        return 1
    }

    local iteration_id
    iteration_id="$(echo "${iteration_response}" | jq -r '.value[0].id')"

    if [[ -z "${iteration_id}" ]] || [[ "${iteration_id}" == "null" ]]; then
        echo "Error: no current iteration found." >&2
        return 1
    fi

    local work_items_response
    work_items_response="$(azdo_fetch_iteration_work_items "${iteration_id}")" || {
        echo "Error: failed to fetch work items for current iteration." >&2
        return 1
    }

    local work_item_ids
    work_item_ids="$(echo "${work_items_response}" | jq '[.workItemRelations[].target.id] | unique')"

    if [[ "${work_item_ids}" == "[]" ]] || [[ -z "${work_item_ids}" ]]; then
        echo "Error: no work items in current sprint." >&2
        return 1
    fi

    azdo_fetch_work_items_batch "${work_item_ids}"
}
