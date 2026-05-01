readonly TWK_LOCAL_CONFIG_DIR_NAME=".twk"
readonly TWK_LOCAL_CONFIG_FILE_NAME="config"

config_global_file() {
    echo "${TWK_CONFIG_DIR}/config"
}

config_local_relative() {
    echo "${TWK_LOCAL_CONFIG_DIR_NAME}/${TWK_LOCAL_CONFIG_FILE_NAME}"
}

config_find_local() {
    local rel="${TWK_LOCAL_CONFIG_DIR_NAME}/${TWK_LOCAL_CONFIG_FILE_NAME}"
    local dir="${PWD}"
    while [[ -n "${dir}" ]]; do
        if [[ -f "${dir}/${rel}" ]]; then
            printf '%s\n' "${dir}/${rel}"
            return 0
        fi
        [[ "${dir}" == "/" ]] && break
        local parent="${dir%/*}"
        [[ -z "${parent}" ]] && parent="/"
        [[ "${parent}" == "${dir}" ]] && break
        dir="${parent}"
    done
    return 1
}

config_active_file() {
    local local_path
    if local_path="$(config_find_local)"; then
        printf '%s\n' "${local_path}"
        return
    fi
    config_global_file
}

config_active_scope() {
    if config_find_local > /dev/null; then
        echo "local"
    else
        echo "global"
    fi
}

config_exists() {
    [[ -f "$(config_active_file)" ]]
}

config_load() {
    if ! config_exists; then
        local rel="${TWK_LOCAL_CONFIG_DIR_NAME}/${TWK_LOCAL_CONFIG_FILE_NAME}"
        echo "Error: twk not initialised. Run 'twk init' first." >&2
        echo "       (no ${rel} in this directory or any parent, and no global config at $(config_global_file))" >&2
        return 1
    fi
    # shellcheck disable=SC1090
    source "$(config_active_file)"
}

config_require() {
    config_load || exit 1
}

config_write() {
    local target_file="$1"
    local organization="$2"
    local project="$3"
    local team="$4"
    local personal_access_token="$5"
    local time_field_task="$6"
    local time_field_feature="$7"
    local state_active="$8"
    local state_paused="$9"
    local state_done="${10}"

    local target_dir
    target_dir="$(dirname "${target_file}")"

    mkdir -p "${target_dir}"
    chmod 700 "${target_dir}"

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

    cat > "${target_file}" <<EOF
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

    chmod 600 "${target_file}"
}

config_protect_local() {
    local config_file="$1"
    local config_parent
    config_parent="$(dirname "$(dirname "${config_file}")")"
    local entry="${TWK_LOCAL_CONFIG_DIR_NAME}/"

    if ! command -v git &> /dev/null; then
        echo ""
        echo "Reminder: 'git' is not installed; cannot determine if ${config_parent} is a git repository."
        echo "If it is, add '${entry}' to your .gitignore to avoid committing your Personal Access Token."
        return
    fi

    if ! git -C "${config_parent}" rev-parse --is-inside-work-tree &> /dev/null; then
        echo ""
        echo "Reminder: ${config_parent} is not a git repository."
        echo "If you initialise one later, add '${entry}' to your .gitignore"
        echo "to avoid committing your Personal Access Token."
        return
    fi

    local repo_root
    if ! repo_root="$(git -C "${config_parent}" rev-parse --show-toplevel)"; then
        echo ""
        echo "Reminder: could not determine git repo root for ${config_parent}."
        echo "Add '${entry}' to your .gitignore manually to avoid committing your PAT."
        return
    fi

    local gitignore="${repo_root}/.gitignore"

    if [[ -L "${gitignore}" ]]; then
        echo ""
        echo "Warning: ${gitignore} is a symlink; refusing to modify." >&2
        echo "         Add '${entry}' to your .gitignore manually to keep your PAT out of git." >&2
        return
    fi

    if [[ -f "${gitignore}" ]] && grep -qxFe ".twk/" -e ".twk" "${gitignore}"; then
        echo ""
        echo "Reminder: '${entry}' (or equivalent) already in ${gitignore}."
        return
    fi

    if [[ -f "${gitignore}" ]]; then
        if [[ -s "${gitignore}" ]] && [[ "$(tail -c 1 "${gitignore}")" != $'\n' ]]; then
            printf '\n' >> "${gitignore}"
        fi
        printf '%s\n' "${entry}" >> "${gitignore}"
        echo ""
        echo "Added '${entry}' to ${gitignore} to keep your PAT out of git."
        echo "Reminder: review and commit the .gitignore change before pushing."
    else
        printf '%s\n' "${entry}" > "${gitignore}"
        echo ""
        echo "Created ${gitignore} with '${entry}' to keep your PAT out of git."
        echo "Reminder: review and commit the new .gitignore before pushing."
    fi
}

cmd_init() {
    local use_global=false
    local arg
    for arg in "$@"; do
        case "${arg}" in
            --global) use_global=true ;;
            --help|-h)
                show_subcommand_help "init"
                return
                ;;
            *)
                echo "Error: unknown argument '${arg}' for init." >&2
                echo "Usage: twk init [--global]" >&2
                return 1
                ;;
        esac
    done

    local target_file
    if [[ "${use_global}" == true ]]; then
        target_file="$(config_global_file)"
    else
        target_file="${PWD}/$(config_local_relative)"
    fi

    print_banner
    echo ""
    if [[ "${use_global}" == true ]]; then
        echo "  Azure DevOps Configuration (global)"
    else
        echo "  Azure DevOps Configuration (local: ${PWD})"
    fi
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

    config_write "${target_file}" \
        "${organization}" "${project}" "${team}" "${personal_access_token}" \
        "${time_field_task}" "${time_field_feature}" \
        "${state_active}" "${state_paused}" "${state_done}"

    local scope
    if [[ "${use_global}" == true ]]; then
        scope="global"
    else
        scope="local"
    fi

    echo ""
    echo "Configuration saved to ${target_file} (${scope} scope)"

    if [[ "${use_global}" == false ]]; then
        config_protect_local "${target_file}"
    else
        local shadowing
        if shadowing="$(config_find_local)"; then
            echo "" >&2
            echo "Warning: a local config exists at ${shadowing}" >&2
            echo "         and will take precedence over the global config you just wrote." >&2
        fi
    fi

    echo ""
    echo "Testing connection..."

    # shellcheck disable=SC1090
    source "${target_file}"
    if azdo_test_connection; then
        echo "Connected successfully."
    else
        echo "Warning: connection test failed. Check your settings with 'twk init'." >&2
    fi
}
