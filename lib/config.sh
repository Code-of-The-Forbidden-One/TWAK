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

    mkdir -p "${TWK_CONFIG_DIR}"
    chmod 700 "${TWK_CONFIG_DIR}"

    local escaped_organization escaped_project escaped_team escaped_pat
    printf -v escaped_organization '%q' "${organization}"
    printf -v escaped_project '%q' "${project}"
    printf -v escaped_team '%q' "${team}"
    printf -v escaped_pat '%q' "${personal_access_token}"

    cat > "$(config_file_path)" <<EOF
TWK_ORGANIZATION=${escaped_organization}
TWK_PROJECT=${escaped_project}
TWK_TEAM=${escaped_team}
TWK_PAT=${escaped_pat}
EOF

    chmod 600 "$(config_file_path)"
}

cmd_init() {
    echo "twk - Azure DevOps Configuration"
    echo "================================="
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

    config_write "${organization}" "${project}" "${team}" "${personal_access_token}"

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
