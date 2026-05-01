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
    last_event="$(tail -1 "${session_file}" | cut -d'|' -f1)"

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

session_mark_committed() {
    local work_item_id="$1"
    local session_file
    session_file="$(session_file_path "${work_item_id}")" || return 1

    local committed_dir="${TWK_DATA_DIR}/committed"
    mkdir -p "${committed_dir}"

    local timestamp
    timestamp="$(date +%s)"
    mv "${session_file}" "${committed_dir}/${work_item_id}_${timestamp}.session"
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
    work_item_id="$(resolve_work_item "${query}")" || return 1

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
    work_item_id="$(resolve_work_item "${query}")" || return 1

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
