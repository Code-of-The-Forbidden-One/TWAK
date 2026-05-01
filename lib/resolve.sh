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

resolve_for_session_action() {
    local query="${1:-}"
    local state_filter="$2"
    local action_label="$3"

    if [[ -n "${query}" ]]; then
        resolve_work_item "${query}"
        return
    fi

    resolve_session_interactive "${state_filter}" "${action_label}"
}

resolve_session_interactive() {
    local state_filter="$1"
    local action_label="$2"

    local session_files
    session_files="$(session_list_uncommitted)"
    if [[ -z "${session_files}" ]]; then
        echo "Error: no uncommitted sessions to ${action_label}." >&2
        return 1
    fi

    local items=()
    local session_file id state title elapsed_seconds elapsed
    while read -r session_file; do
        id="$(session_work_item_id_from_path "${session_file}")"
        state="$(session_read_state "${id}")"

        if [[ -n "${state_filter}" ]] && ! [[ "${state}" =~ ^(${state_filter})$ ]]; then
            continue
        fi

        elapsed_seconds="$(session_calculate_elapsed_seconds "${id}")"
        elapsed="$(format_duration "${elapsed_seconds}")"
        title="$(session_read_meta_title "${id}")"
        [[ -z "${title}" ]] && title="(no title cached)"

        items+=("$(printf '%s\t%s\t%s\t%s' "${id}" "${state}" "${elapsed}" "${title}")")
    done <<< "${session_files}"

    if [[ ${#items[@]} -eq 0 ]]; then
        echo "Error: no sessions to ${action_label}." >&2
        return 1
    fi

    if [[ ${#items[@]} -eq 1 ]]; then
        printf '%s\n' "${items[0]}" | cut -f1
        return
    fi

    if command -v fzf &> /dev/null; then
        resolve_session_with_fzf "${action_label}" "${items[@]}"
    else
        resolve_session_with_numbered_list "${action_label}" "${items[@]}"
    fi
}

resolve_session_with_fzf() {
    local action_label="$1"
    shift
    local items=("$@")

    local display_list
    display_list="$(printf '%s\n' "${items[@]}" \
        | awk -F'\t' '{ printf "#%-7s %-10s %-12s %s\n", $1, $2, $3, $4 }')"

    local selected
    selected="$(echo "${display_list}" | fzf --prompt="Select session to ${action_label}: " --height=20 --reverse)"

    if [[ -z "${selected}" ]]; then
        echo "Error: no session selected." >&2
        return 1
    fi

    echo "${selected}" | grep -oP '(?<=#)\d+'
}

resolve_session_with_numbered_list() {
    local action_label="$1"
    shift
    local items=("$@")

    echo "Sessions available to ${action_label}:" >&2
    local index=1
    local id state elapsed title item
    for item in "${items[@]}"; do
        IFS=$'\t' read -r id state elapsed title <<< "${item}"
        printf "  %2d) #%-7s %-10s %-12s %s\n" "${index}" "${id}" "${state}" "${elapsed}" "${title}" >&2
        index=$((index + 1))
    done

    local total=${#items[@]}
    local selection
    read -rp "Select [1-${total}]: " selection

    if [[ -z "${selection}" ]] || [[ "${selection}" -lt 1 ]] || [[ "${selection}" -gt "${total}" ]]; then
        echo "Error: invalid selection." >&2
        return 1
    fi

    printf '%s\n' "${items[$((selection - 1))]}" | cut -f1
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

    local raw_items
    raw_items="$(echo "${work_items_json}" | jq -r '
        .value[]
        | "\(.id)\t\(.fields["System.WorkItemType"])\t\(.fields["System.Title"])\t\(.fields["System.State"])"
    ')"

    if [[ -z "${raw_items}" ]]; then
        echo "Error: no work items found in current sprint." >&2
        return 1
    fi

    # Augment with local session info and drop items we can't start (running).
    # Each output row: id<TAB>type<TAB>title<TAB>azdo_state<TAB>session_state<TAB>elapsed
    local items_list=""
    local id type title azdo_state sess_state elapsed_str
    local hidden_running=0
    while IFS=$'\t' read -r id type title azdo_state; do
        sess_state=""
        elapsed_str=""
        if session_exists "${id}"; then
            sess_state="$(session_read_state "${id}")"
            if [[ "${sess_state}" == "${STATE_RUNNING}" ]]; then
                hidden_running=$(( hidden_running + 1 ))
                continue
            fi
            elapsed_str="$(format_duration "$(session_calculate_elapsed_seconds "${id}")")"
        fi
        items_list+="${id}"$'\t'"${type}"$'\t'"$(truncate_title "${title}")"$'\t'"${azdo_state}"$'\t'"${sess_state}"$'\t'"${elapsed_str}"$'\n'
    done <<< "${raw_items}"

    items_list="${items_list%$'\n'}"

    if [[ -z "${items_list}" ]]; then
        echo "Error: every sprint item is currently being tracked. Pause or end one first." >&2
        return 1
    fi

    if [[ "${hidden_running}" -gt 0 ]]; then
        echo "(${hidden_running} running session$( [[ ${hidden_running} -gt 1 ]] && echo s ) hidden)" >&2
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
    display_list="$(echo "${items_list}" | awk -F'\t' '{
        if ($5 == "paused") {
            printf "#%-7s [%-12s] %-10s %-40s paused %s\n", $1, $2, $4, $3, $6
        } else {
            printf "#%-7s [%-12s] %-10s %s\n", $1, $2, $4, $3
        }
    }')"

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
    local item_id item_type item_title item_state sess_state elapsed
    while IFS=$'\t' read -r item_id item_type item_title item_state sess_state elapsed; do
        if [[ "${sess_state}" == "paused" ]]; then
            printf "  %2d) #%-7s [%-12s] %-10s %-40s paused %s\n" \
                "${index}" "${item_id}" "${item_type}" "${item_state}" "${item_title}" "${elapsed}" >&2
        else
            printf "  %2d) #%-7s [%-12s] %-10s %s\n" \
                "${index}" "${item_id}" "${item_type}" "${item_state}" "${item_title}" >&2
        fi
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
