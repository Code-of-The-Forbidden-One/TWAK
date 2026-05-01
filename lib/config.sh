config_file_path() {
    echo "${TWK_CONFIG_DIR}/config"
}

config_exists() {
    [[ -f "$(config_file_path)" ]]
}

config_load() {
    if ! config_exists; then
        echo "Error: twk not initialised. Run 'twk init' first." >&2
        return 1
    fi
    source "$(config_file_path)"
}

config_require() {
    config_load || exit 1
}

config_write() {
    local organization="$1"
    local project="$2"
    local team="$3"
    local personal_access_token="$4"
    local time_field_task="$5"
    local time_field_feature="$6"
    local state_active="$7"
    local state_paused="$8"
    local state_done="$9"

    mkdir -p "${TWK_CONFIG_DIR}"
    chmod 700 "${TWK_CONFIG_DIR}"

    local escaped_organization escaped_project escaped_team escaped_pat
    local escaped_time_field_task escaped_time_field_feature
    local escaped_state_active escaped_state_paused escaped_state_done
    printf -v escaped_organization '%q' "${organization}"
    printf -v escaped_project '%q' "${project}"
    printf -v escaped_team '%q' "${team}"
    printf -v escaped_pat '%q' "${personal_access_token}"
    printf -v escaped_time_field_task '%q' "${time_field_task}"
    printf -v escaped_time_field_feature '%q' "${time_field_feature}"
    printf -v escaped_state_active '%q' "${state_active}"
    printf -v escaped_state_paused '%q' "${state_paused}"
    printf -v escaped_state_done '%q' "${state_done}"

    cat > "$(config_file_path)" <<EOF
TWK_ORGANIZATION=${escaped_organization}
TWK_PROJECT=${escaped_project}
TWK_TEAM=${escaped_team}
TWK_PAT=${escaped_pat}
TWK_TIME_FIELD_TASK=${escaped_time_field_task}
TWK_TIME_FIELD_FEATURE=${escaped_time_field_feature}
TWK_STATE_ACTIVE=${escaped_state_active}
TWK_STATE_PAUSED=${escaped_state_paused}
TWK_STATE_DONE=${escaped_state_done}
EOF

    chmod 600 "$(config_file_path)"
}

cmd_init() {
    print_banner
    echo ""
    echo "  Azure DevOps Configuration"
    echo ""

    local organization project team personal_access_token

    read -rp "Organisation (e.g. myorg): " organization
    if [[ -z "${organization}" ]]; then
        echo "Error: organisation is required." >&2
        return 1
    fi

    read -rp "Project (e.g. MyProject): " project
    if [[ -z "${project}" ]]; then
        echo "Error: project is required." >&2
        return 1
    fi

    read -rp "Team (e.g. MyTeam, or leave blank for default): " team

    read -rsp "Personal Access Token: " personal_access_token
    echo ""
    if [[ -z "${personal_access_token}" ]]; then
        echo "Error: personal access token is required." >&2
        return 1
    fi

    echo ""
    echo "Time tracking fields"
    echo "These are the Azure DevOps field names that twk writes time to."
    echo "Common values: Microsoft.VSTS.Scheduling.CompletedWork, Custom.TimeSpent"
    echo ""

    local time_field_task time_field_feature

    read -rp "Time field for Tasks (e.g. Custom.TimeSpent): " time_field_task
    if [[ -z "${time_field_task}" ]]; then
        echo "Error: task time field is required." >&2
        return 1
    fi

    read -rp "Time field for Features (leave blank if same as Tasks): " time_field_feature
    if [[ -z "${time_field_feature}" ]]; then
        time_field_feature="${time_field_task}"
    fi

    echo ""
    echo "Work item states"
    echo "These map twk actions to your board's column/state names."
    echo "Leave blank to skip state updates for that action."
    echo ""

    local state_active state_paused state_done

    read -rp "State for start (default: Active): " state_active
    state_active="${state_active:-Active}"

    read -rp "State for pause (default: Paused): " state_paused
    state_paused="${state_paused:-Paused}"

    read -rp "State for end --done (default: Done): " state_done
    state_done="${state_done:-Done}"

    config_write "${organization}" "${project}" "${team}" "${personal_access_token}" \
        "${time_field_task}" "${time_field_feature}" \
        "${state_active}" "${state_paused}" "${state_done}"

    echo ""
    echo "Configuration saved to $(config_file_path)"
    echo "Testing connection..."

    config_load
    if azdo_test_connection; then
        echo "Connected successfully."
    else
        echo "Warning: connection test failed. Check your settings with 'twk init'." >&2
    fi
}
