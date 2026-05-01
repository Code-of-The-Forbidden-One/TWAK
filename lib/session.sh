readonly STATE_RUNNING="running"
readonly STATE_PAUSED="paused"
readonly STATE_ENDED="ended"
readonly STATE_NONE="none"

validate_work_item_id() {
    local work_item_id="$1"
    if [[ ! "${work_item_id}" =~ ^[0-9]+$ ]]; then
        echo "Error: invalid work item ID '${work_item_id}'. Must be a numeric value." >&2
        return 1
    fi
}

session_file_path() {
    local work_item_id="$1"
    validate_work_item_id "${work_item_id}" || return 1
    echo "${TWK_DATA_DIR}/${work_item_id}.session"
}

session_meta_file_path() {
    local work_item_id="$1"
    validate_work_item_id "${work_item_id}" || return 1
    echo "${TWK_DATA_DIR}/${work_item_id}.meta"
}

session_meta_exists() {
    local work_item_id="$1"
    [[ -f "$(session_meta_file_path "${work_item_id}")" ]]
}

session_cache_meta() {
    local work_item_id="$1"
    if session_meta_exists "${work_item_id}"; then
        return 0
    fi

    local meta_json
    meta_json="$(azdo_fetch_work_item_meta "${work_item_id}" 2>/dev/null)" || return 1

    if [[ -z "${meta_json}" ]]; then
        return 1
    fi

    session_ensure_data_dir
    printf '%s\n' "${meta_json}" > "$(session_meta_file_path "${work_item_id}")"
}

session_read_meta_title() {
    local work_item_id="$1"
    local meta_file
    meta_file="$(session_meta_file_path "${work_item_id}")" || return 1

    if [[ ! -f "${meta_file}" ]]; then
        return
    fi

    jq -r '.title // ""' "${meta_file}" 2>/dev/null
}

session_ensure_data_dir() {
    mkdir -p "${TWK_DATA_DIR}"
}

session_exists() {
    local work_item_id="$1"
    [[ -f "$(session_file_path "${work_item_id}")" ]]
}

session_read_state() {
    local work_item_id="$1"
    local session_file
    session_file="$(session_file_path "${work_item_id}")" || return 1

    if [[ ! -f "${session_file}" ]]; then
        echo "${STATE_NONE}"
        return
    fi

    local last_event
    last_event="$(tail -n 1 "${session_file}" | cut -d'|' -f1)"

    case "${last_event}" in
        start|resume) echo "${STATE_RUNNING}" ;;
        pause)        echo "${STATE_PAUSED}" ;;
        end)          echo "${STATE_ENDED}" ;;
        *)            echo "${STATE_NONE}" ;;
    esac
}

session_append() {
    local work_item_id="$1"
    local event_type="$2"
    local timestamp
    timestamp="$(date +%s)"

    session_ensure_data_dir
    echo "${event_type}|${timestamp}" >> "$(session_file_path "${work_item_id}")"
}

session_calculate_elapsed_seconds() {
    local work_item_id="$1"
    local session_file
    session_file="$(session_file_path "${work_item_id}")" || return 1

    if [[ ! -f "${session_file}" ]]; then
        echo "0"
        return
    fi

    local total_seconds=0
    local segment_start=""
    local event_type timestamp

    while IFS='|' read -r event_type timestamp; do
        case "${event_type}" in
            start|resume)
                segment_start="${timestamp}"
                ;;
            pause|end)
                if [[ -n "${segment_start}" ]]; then
                    total_seconds=$(( total_seconds + timestamp - segment_start ))
                    segment_start=""
                fi
                ;;
        esac
    done < "${session_file}"

    # If still running, count time up to now
    if [[ -n "${segment_start}" ]]; then
        local now
        now="$(date +%s)"
        total_seconds=$(( total_seconds + now - segment_start ))
    fi

    echo "${total_seconds}"
}

session_list_uncommitted() {
    session_ensure_data_dir

    local files=("${TWK_DATA_DIR}"/*.session)

    if [[ ! -e "${files[0]}" ]]; then
        return
    fi

    printf '%s\n' "${files[@]}"
}

session_archive_meta() {
    local work_item_id="$1"
    local archive_dir="$2"
    local timestamp="$3"

    local meta_file
    meta_file="$(session_meta_file_path "${work_item_id}")" || return 0

    if [[ -f "${meta_file}" ]]; then
        mv "${meta_file}" "${archive_dir}/${work_item_id}_${timestamp}.meta"
    fi
}

session_mark_committed() {
    local work_item_id="$1"
    local session_file
    session_file="$(session_file_path "${work_item_id}")" || return 1

    local committed_dir="${TWK_DATA_DIR}/committed"
    mkdir -p "${committed_dir}"

    local timestamp
    timestamp="$(date +%s)"
    mv "${session_file}" "${committed_dir}/${work_item_id}_${timestamp}.session"
    session_archive_meta "${work_item_id}" "${committed_dir}" "${timestamp}"
}

session_mark_cancelled() {
    local work_item_id="$1"
    local session_file
    session_file="$(session_file_path "${work_item_id}")" || return 1

    local cancelled_dir="${TWK_DATA_DIR}/cancelled"
    mkdir -p "${cancelled_dir}"

    local timestamp
    timestamp="$(date +%s)"
    mv "${session_file}" "${cancelled_dir}/${work_item_id}_${timestamp}.session"
    session_archive_meta "${work_item_id}" "${cancelled_dir}" "${timestamp}"
}

session_pop_last_event() {
    local work_item_id="$1"
    local session_file
    session_file="$(session_file_path "${work_item_id}")" || return 1

    # Distinct exit codes:
    #   2 - session file does not exist
    #   3 - session file exists but contains no events
    if [[ ! -f "${session_file}" ]]; then
        return 2
    fi

    if [[ ! -s "${session_file}" ]]; then
        rm -f "${session_file}"
        return 3
    fi

    local last_event
    # awk handles missing-trailing-newline correctly; END $1 is the last record's first field
    last_event="$(awk -F'|' 'END { print $1 }' "${session_file}")"
    if [[ -z "${last_event}" ]]; then
        rm -f "${session_file}"
        return 3
    fi

    local tmp
    tmp="$(mktemp "${session_file}.XXXXXX")" || return 1
    # Drop the last line; works regardless of trailing newline.
    awk 'NR>1 { print prev } { prev=$0 }' "${session_file}" > "${tmp}"

    if [[ -s "${tmp}" ]]; then
        mv "${tmp}" "${session_file}"
    else
        rm -f "${tmp}" "${session_file}"
    fi

    printf '%s\n' "${last_event}"
}

session_work_item_id_from_path() {
    local file_path="$1"
    basename "${file_path}" .session
}

parse_state_flag() {
    local args=("$@")
    local i
    for (( i=0; i<${#args[@]}; i++ )); do
        if [[ "${args[i]}" == "--state" ]] && [[ $(( i + 1 )) -lt ${#args[@]} ]]; then
            echo "${args[i+1]}"
            return
        fi
    done
}

parse_query_arg() {
    local args=("$@")
    local i
    for (( i=0; i<${#args[@]}; i++ )); do
        if [[ "${args[i]}" == "--state" ]]; then
            i=$(( i + 1 ))
            continue
        fi
        echo "${args[i]}"
        return
    done
}

apply_state_change() {
    local work_item_id="$1"
    local new_state="$2"

    if [[ -z "${new_state}" ]]; then
        return
    fi

    if azdo_update_state "${work_item_id}" "${new_state}" 2>/dev/null; then
        echo "  State set to ${new_state}"
    else
        echo "  Warning: could not set state to ${new_state}" >&2
    fi
}

cmd_start() {
    config_require
    local query
    query="$(parse_query_arg "$@")"
    local target_state
    target_state="$(parse_state_flag "$@")"

    local work_item_id
    work_item_id="$(resolve_work_item "${query}")" || return 1

    local current_state
    current_state="$(session_read_state "${work_item_id}")"

    if [[ "${current_state}" == "${STATE_RUNNING}" ]]; then
        echo "Error: work item #${work_item_id} is already running." >&2
        return 1
    fi

    session_cache_meta "${work_item_id}" || true

    if [[ "${current_state}" == "${STATE_PAUSED}" ]]; then
        session_append "${work_item_id}" "resume"
        echo "Resumed tracking #${work_item_id}"
    else
        session_append "${work_item_id}" "start"
        echo "Started tracking #${work_item_id}"
    fi

    apply_state_change "${work_item_id}" "${target_state}"
}

cmd_pause() {
    config_require
    local query
    query="$(parse_query_arg "$@")"
    local target_state
    target_state="$(parse_state_flag "$@")"

    local work_item_id
    work_item_id="$(resolve_for_session_action "${query}" "${STATE_RUNNING}" "pause")" || return 1

    local current_state
    current_state="$(session_read_state "${work_item_id}")"

    if [[ "${current_state}" != "${STATE_RUNNING}" ]]; then
        echo "Error: work item #${work_item_id} is not currently running." >&2
        return 1
    fi

    session_append "${work_item_id}" "pause"

    local elapsed_seconds
    elapsed_seconds="$(session_calculate_elapsed_seconds "${work_item_id}")"
    echo "Paused #${work_item_id} ($(format_duration "${elapsed_seconds}") tracked)"

    apply_state_change "${work_item_id}" "${target_state}"
}

cmd_end() {
    config_require
    local query
    query="$(parse_query_arg "$@")"
    local target_state
    target_state="$(parse_state_flag "$@")"

    local work_item_id
    work_item_id="$(resolve_for_session_action "${query}" "${STATE_RUNNING}|${STATE_PAUSED}" "end")" || return 1

    local current_state
    current_state="$(session_read_state "${work_item_id}")"

    if [[ "${current_state}" == "${STATE_NONE}" ]]; then
        echo "Error: no active session for work item #${work_item_id}." >&2
        return 1
    fi

    if [[ "${current_state}" == "${STATE_ENDED}" ]]; then
        echo "Error: work item #${work_item_id} is already ended." >&2
        return 1
    fi

    session_append "${work_item_id}" "end"

    local elapsed_seconds
    elapsed_seconds="$(session_calculate_elapsed_seconds "${work_item_id}")"
    echo "Ended #${work_item_id} ($(format_duration "${elapsed_seconds}") total)"

    apply_state_change "${work_item_id}" "${target_state}"
}

cmd_done() {
    config_require
    local query
    query="$(parse_query_arg "$@")"
    local target_state
    target_state="$(parse_state_flag "$@")"

    if [[ -z "${target_state}" ]]; then
        target_state="${TWK_STATE_DONE}"
    fi

    local work_item_id
    work_item_id="$(resolve_work_item "${query}")" || return 1

    apply_state_change "${work_item_id}" "${target_state}"
}

cmd_assign() {
    config_require

    local me=false
    local all=false
    local positional=()
    local arg
    for arg in "$@"; do
        case "${arg}" in
            --me)  me=true ;;
            --all) all=true ;;
            *)     positional+=("${arg}") ;;
        esac
    done

    if [[ ${#positional[@]} -gt 2 ]]; then
        echo "Error: too many arguments." >&2
        echo "Usage: twk assign [task] [user] [--me] [--all]" >&2
        return 1
    fi

    local task_query="${positional[0]:-}"
    local user="${positional[1]:-}"

    if [[ "${me}" == true ]] && [[ -n "${user}" ]]; then
        echo "Error: --me cannot be combined with an explicit user." >&2
        return 1
    fi
    if [[ "${me}" == true ]] && [[ "${all}" == true ]]; then
        echo "Error: --me and --all are mutually exclusive." >&2
        return 1
    fi
    if [[ "${all}" == true ]] && [[ -n "${user}" ]]; then
        echo "Error: --all cannot be combined with an explicit user (it scopes the picker)." >&2
        return 1
    fi

    local work_item_id
    work_item_id="$(resolve_work_item "${task_query}")" || return 1

    if [[ "${me}" == true ]]; then
        user="$(resolve_self)" || return 1
    elif [[ -z "${user}" ]]; then
        local scope="sprint"
        [[ "${all}" == true ]] && scope="org"
        user="$(resolve_user_interactive "${scope}")" || return 1
    fi

    if [[ -z "${user}" ]]; then
        echo "Error: user must not be empty." >&2
        echo "Usage: twk assign [task] [user] [--me] [--all]" >&2
        return 1
    fi

    if azdo_update_assigned_to "${work_item_id}" "${user}" > /dev/null 2>&1; then
        echo "Assigned #${work_item_id} to ${user}"
    else
        echo "Error: failed to assign #${work_item_id} to ${user}." >&2
        echo "       Check that the user (email, display name, or unique name) is" >&2
        echo "       recognised in this Azure DevOps organisation." >&2
        return 1
    fi
}

cmd_pull() {
    config_require

    if [[ $# -gt 0 ]]; then
        echo "Error: 'twk pull' takes no arguments." >&2
        echo "Usage: twk pull" >&2
        return 1
    fi

    local session_files
    session_files="$(session_list_uncommitted)"

    if [[ -z "${session_files}" ]]; then
        echo "No sessions to refresh."
        return
    fi

    local total=0
    local f
    while read -r f; do
        total=$(( total + 1 ))
    done <<< "${session_files}"

    echo "Refreshing metadata for ${total} session$( (( total != 1 )) && echo s )..."
    echo ""

    local refreshed=0 failed=0
    local session_file work_item_id meta_json title meta_target
    while read -r session_file; do
        work_item_id="$(session_work_item_id_from_path "${session_file}")"
        meta_target="$(session_meta_file_path "${work_item_id}")"

        if meta_json="$(azdo_fetch_work_item_meta "${work_item_id}" 2>/dev/null)" && [[ -n "${meta_json}" ]]; then
            session_ensure_data_dir
            printf '%s\n' "${meta_json}" > "${meta_target}"
            title="$(printf '%s' "${meta_json}" | jq -r '.title // ""')"
            if [[ -n "${title}" ]]; then
                echo "  #${work_item_id}: refreshed (\"${title}\")"
            else
                echo "  #${work_item_id}: refreshed"
            fi
            refreshed=$(( refreshed + 1 ))
        else
            echo "  #${work_item_id}: failed (work item not found or unreachable)" >&2
            failed=$(( failed + 1 ))
        fi
    done <<< "${session_files}"

    echo ""
    echo "Done: ${refreshed} refreshed, ${failed} failed."
}

cmd_cancel() {
    config_require
    local query
    query="$(parse_query_arg "$@")"
    local target_state
    target_state="$(parse_state_flag "$@")"

    local work_item_id
    work_item_id="$(resolve_for_session_action "${query}" "${STATE_RUNNING}|${STATE_PAUSED}|${STATE_ENDED}" "cancel")" || return 1

    if ! session_exists "${work_item_id}"; then
        echo "Error: no session for work item #${work_item_id}." >&2
        return 1
    fi

    local elapsed_seconds
    elapsed_seconds="$(session_calculate_elapsed_seconds "${work_item_id}")"

    session_mark_cancelled "${work_item_id}"
    echo "Cancelled #${work_item_id} ($(format_duration "${elapsed_seconds}") discarded)"

    apply_state_change "${work_item_id}" "${target_state}"
}

cmd_undo() {
    config_require
    local query
    query="$(parse_query_arg "$@")"
    local target_state
    target_state="$(parse_state_flag "$@")"

    local work_item_id
    work_item_id="$(resolve_for_session_action "${query}" "${STATE_RUNNING}|${STATE_PAUSED}|${STATE_ENDED}" "undo")" || return 1

    if ! session_exists "${work_item_id}"; then
        echo "Error: no session for work item #${work_item_id}." >&2
        return 1
    fi

    local popped_event pop_status=0
    popped_event="$(session_pop_last_event "${work_item_id}")" || pop_status=$?
    if [[ "${pop_status}" -ne 0 ]]; then
        case "${pop_status}" in
            2) echo "Error: no session for work item #${work_item_id}." >&2 ;;
            3) echo "Error: nothing to undo for #${work_item_id} (session is empty)." >&2 ;;
            *) echo "Error: failed to undo last event for #${work_item_id}." >&2 ;;
        esac
        return 1
    fi

    if session_exists "${work_item_id}"; then
        local new_state
        new_state="$(session_read_state "${work_item_id}")"
        echo "Undid '${popped_event}' on #${work_item_id} (now ${new_state})"
    else
        echo "Undid '${popped_event}' on #${work_item_id} (session removed)"
    fi

    apply_state_change "${work_item_id}" "${target_state}"
}
