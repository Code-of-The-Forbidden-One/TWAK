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

build_existing_times_map() {
    local ids_json="$1"

    local response
    response="$(azdo_fetch_existing_times "${ids_json}" 2>/dev/null)" || return 1

    echo "${response}" | jq -r \
        --arg t "${TWK_TIME_FIELD_TASK}" \
        --arg f "${TWK_TIME_FIELD_FEATURE}" '
        .value[]
        | . as $w
        | (if $w.fields["System.WorkItemType"] == "Feature" then $f else $t end) as $field
        | "\($w.id)\t\($w.fields[$field] // 0)"
    '
}

lookup_existing_time() {
    local work_item_id="$1"
    local map="$2"
    local hit
    hit="$(printf '%s\n' "${map}" | awk -F'\t' -v id="${work_item_id}" '$1 == id { print $2; exit }')"
    if [[ -z "${hit}" ]]; then
        echo "?"
    else
        echo "${hit}"
    fi
}

cmd_status() {
    config_require

    local with_existing=false
    local arg
    for arg in "$@"; do
        case "${arg}" in
            --with-existing) with_existing=true ;;
            *)
                echo "Error: unknown argument '${arg}' for status." >&2
                echo "Usage: twk status [--with-existing]" >&2
                return 1
                ;;
        esac
    done

    local session_files
    session_files="$(session_list_uncommitted)"

    echo "Config: $(config_active_file) ($(config_active_scope) scope)"

    if [[ -z "${session_files}" ]]; then
        echo "No uncommitted time entries."
        return
    fi

    local existing_map=""
    if [[ "${with_existing}" == true ]]; then
        local ids=()
        local f
        while read -r f; do
            ids+=("$(session_work_item_id_from_path "${f}")")
        done <<< "${session_files}"
        local ids_json
        ids_json="$(printf '%s\n' "${ids[@]}" | jq -Rcn '[inputs | tonumber]')"
        existing_map="$(build_existing_times_map "${ids_json}" || true)"
    fi

    local rule_width=81
    [[ "${with_existing}" == true ]] && rule_width=101
    local rule
    rule="$(printf '─%.0s' $(seq 1 "${rule_width}"))"

    echo ""
    echo "Uncommitted time entries:"
    echo "${rule}"
    if [[ "${with_existing}" == true ]]; then
        printf "  %-8s %-${STATUS_TITLE_WIDTH}s %-10s %-12s %-8s %-8s %s\n" \
            "ID" "Title" "State" "Time" "Hours" "+ AzDO" "= Total"
    else
        printf "  %-8s %-${STATUS_TITLE_WIDTH}s %-10s %-12s %s\n" \
            "ID" "Title" "State" "Time" "Hours"
    fi
    echo "${rule}"

    local total_seconds=0
    local total_existing=0
    local total_combined=0
    local work_item_id state elapsed_seconds hours_decimal title
    local existing existing_display total_display

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

        if [[ "${with_existing}" == true ]]; then
            existing="$(lookup_existing_time "${work_item_id}" "${existing_map}")"
            if [[ "${existing}" == "?" ]]; then
                existing_display="?"
                total_display="?"
            else
                existing_display="${existing}h"
                total_display="$(echo "scale=2; ${existing} + ${hours_decimal}" | bc)h"
                total_existing="$(echo "scale=2; ${total_existing} + ${existing}" | bc)"
                total_combined="$(echo "scale=2; ${total_combined} + ${existing} + ${hours_decimal}" | bc)"
            fi
            printf "  #%-7s %-${STATUS_TITLE_WIDTH}s %-10s %-12s %-8s %-8s %s\n" \
                "${work_item_id}" \
                "$(truncate_title "${title}")" \
                "${state}" \
                "$(format_duration "${elapsed_seconds}")" \
                "${hours_decimal}h" \
                "${existing_display}" \
                "${total_display}"
        else
            printf "  #%-7s %-${STATUS_TITLE_WIDTH}s %-10s %-12s %sh\n" \
                "${work_item_id}" \
                "$(truncate_title "${title}")" \
                "${state}" \
                "$(format_duration "${elapsed_seconds}")" \
                "${hours_decimal}"
        fi
    done <<< "${session_files}"

    echo "${rule}"
    if [[ "${with_existing}" == true ]]; then
        printf "  %-8s %-${STATUS_TITLE_WIDTH}s %-10s %-12s %-8s %-8s %s\n" \
            "Total" "" "" \
            "$(format_duration "${total_seconds}")" \
            "$(seconds_to_hours "${total_seconds}")h" \
            "${total_existing}h" \
            "${total_combined}h"
    else
        printf "  %-8s %-${STATUS_TITLE_WIDTH}s %-10s %-12s %sh\n" \
            "Total" "" "" \
            "$(format_duration "${total_seconds}")" \
            "$(seconds_to_hours "${total_seconds}")"
    fi
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
