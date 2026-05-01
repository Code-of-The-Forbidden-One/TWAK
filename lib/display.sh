format_duration() {
    local total_seconds="$1"
    local hours=$(( total_seconds / 3600 ))
    local minutes=$(( (total_seconds % 3600) / 60 ))
    local seconds=$(( total_seconds % 60 ))

    printf "%02d:%02d:%02d" "${hours}" "${minutes}" "${seconds}"
}

seconds_to_hours() {
    local total_seconds="$1"
    echo "scale=2; ${total_seconds} / 3600" | bc
}

readonly STATUS_TITLE_WIDTH=40

truncate_title() {
    local title="$1"
    local max_len="${2:-${STATUS_TITLE_WIDTH}}"
    if [[ "${#title}" -gt "${max_len}" ]]; then
        printf '%s...' "${title:0:$((max_len - 3))}"
    else
        printf '%s' "${title}"
    fi
}

cmd_status() {
    config_require

    local session_files
    session_files="$(session_list_uncommitted)"

    echo "Config: $(config_active_file) ($(config_active_scope) scope)"

    if [[ -z "${session_files}" ]]; then
        echo "No uncommitted time entries."
        return
    fi

    local rule
    rule="$(printf '─%.0s' $(seq 1 81))"

    echo ""
    echo "Uncommitted time entries:"
    echo "${rule}"
    printf "  %-8s %-${STATUS_TITLE_WIDTH}s %-10s %-12s %s\n" "ID" "Title" "State" "Time" "Hours"
    echo "${rule}"

    local total_seconds=0
    local work_item_id state elapsed_seconds hours_decimal title

    while read -r session_file; do
        work_item_id="$(session_work_item_id_from_path "${session_file}")"
        state="$(session_read_state "${work_item_id}")"
        elapsed_seconds="$(session_calculate_elapsed_seconds "${work_item_id}")"
        total_seconds=$(( total_seconds + elapsed_seconds ))

        hours_decimal="$(seconds_to_hours "${elapsed_seconds}")"

        title="$(session_read_meta_title "${work_item_id}")"
        if [[ -z "${title}" ]]; then
            title="(no title cached)"
        fi

        printf "  #%-7s %-${STATUS_TITLE_WIDTH}s %-10s %-12s %sh\n" \
            "${work_item_id}" \
            "$(truncate_title "${title}")" \
            "${state}" \
            "$(format_duration "${elapsed_seconds}")" \
            "${hours_decimal}"
    done <<< "${session_files}"

    echo "${rule}"
    printf "  %-8s %-${STATUS_TITLE_WIDTH}s %-10s %-12s %sh\n" \
        "Total" "" "" \
        "$(format_duration "${total_seconds}")" \
        "$(seconds_to_hours "${total_seconds}")"
}

cmd_commit() {
    config_require

    local session_files
    session_files="$(session_list_uncommitted)"

    if [[ -z "${session_files}" ]]; then
        echo "No uncommitted time entries to commit."
        return
    fi

    echo "Committing time entries to Azure DevOps..."
    echo ""

    local success_count=0
    local failure_count=0
    local work_item_id current_state elapsed_seconds new_hours
    local existing_work_item existing_hours total_hours time_field

    while read -r session_file; do
        work_item_id="$(session_work_item_id_from_path "${session_file}")"
        current_state="$(session_read_state "${work_item_id}")"

        if [[ "${current_state}" == "${STATE_RUNNING}" ]]; then
            echo "  #${work_item_id}: skipped (still running - end or pause first)"
            failure_count=$(( failure_count + 1 ))
            continue
        fi

        elapsed_seconds="$(session_calculate_elapsed_seconds "${work_item_id}")"
        new_hours="$(seconds_to_hours "${elapsed_seconds}")"

        time_field="$(azdo_resolve_time_field "${work_item_id}")"

        existing_work_item="$(azdo_fetch_work_item "${work_item_id}" 2>/dev/null)"

        existing_hours=0
        if [[ -n "${existing_work_item}" ]]; then
            existing_hours="$(echo "${existing_work_item}" | jq -r --arg field "${time_field}" '.fields[$field] // 0')"
        fi

        total_hours="$(echo "scale=2; ${existing_hours} + ${new_hours}" | bc)"

        if azdo_update_time_spent "${work_item_id}" "${total_hours}" "${time_field}" > /dev/null 2>&1; then
            session_mark_committed "${work_item_id}"
            echo "  #${work_item_id}: committed ${new_hours}h (total: ${total_hours}h)"
            success_count=$(( success_count + 1 ))
        else
            echo "  #${work_item_id}: failed to update Azure DevOps" >&2
            failure_count=$(( failure_count + 1 ))
        fi
    done <<< "${session_files}"

    echo ""
    echo "Done: ${success_count} committed, ${failure_count} failed/skipped."
}
