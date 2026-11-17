# lib/config.sh — finding, trusting, reading, and writing twk's config.
#
# A config file is data, never code: it is parsed line by line as
# KEY=value, and only the keys in TWK_CONFIG_KEYS are accepted. (Earlier
# versions `source`d it, so any .twk/config in a parent directory, such
# as one committed to a cloned repository, ran as the user.)
#
# Before a file is used, twk checks that the current user owns it and
# that nobody else can write to it or its directory. A project-local
# .twk/config must also be trusted: `twk init` trusts the file it writes,
# and `twk trust` trusts one after the user has reviewed it. The trust
# record holds the file's checksum, so a trusted file that changes must
# be trusted again.

readonly TWK_LOCAL_CONFIG_DIR_NAME=".twk"
readonly TWK_LOCAL_CONFIG_FILE_NAME="config"
readonly TWK_TRUST_FILE_NAME="trusted"
readonly TWK_CONFIG_KEYS=(
    TWK_ORGANIZATION
    TWK_PROJECT
    TWK_TEAM
    TWK_AUTH
    TWK_PAT
    TWK_TIME_FIELD_TASK
    TWK_TIME_FIELD_FEATURE
    TWK_STATE_ON_START
    TWK_STATE_ON_PAUSE
    TWK_STATE_DONE
    TWK_STATE_ACTIVE
    TWK_STATE_PAUSED
)
# TWK_STATE_ACTIVE and TWK_STATE_PAUSED were written by twk 0.1.x but never
# used. They are still accepted, so old configs load without warnings, and
# still ignored: their values were defaults nobody chose, so treating them
# as "move the item on start/pause" would surprise everyone who upgrades.
readonly TWK_FIELD_NAME_PATTERN='^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)*$'

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

# --- Ownership and trust -------------------------------------------------

config_writable_by_others() {
    # True if group or others can write to <path>. `find -perm -mode`
    # (all bits set) is understood by GNU and BSD find alike.
    local path="$1"
    [[ -n "$(find "${path}" -maxdepth 0 \( -perm -020 -o -perm -002 \) -print 2>/dev/null)" ]]
}

config_check_file_safety() {
    # Refuses a config file another user could have written.
    local file="$1"
    local dir
    dir="$(dirname "${file}")"

    if [[ ! -O "${file}" ]]; then
        echo "Error: ${file} is not owned by you; refusing to use it." >&2
        return 1
    fi
    if config_writable_by_others "${file}"; then
        echo "Error: ${file} can be written by other users; refusing to use it." >&2
        echo "       Fix with: chmod 600 '${file}'" >&2
        return 1
    fi
    if config_writable_by_others "${dir}"; then
        echo "Error: ${dir} can be written by other users; refusing to use ${file}." >&2
        echo "       Fix with: chmod 700 '${dir}'" >&2
        return 1
    fi
}

config_trust_file() {
    echo "${TWK_CONFIG_DIR}/${TWK_TRUST_FILE_NAME}"
}

config_fingerprint() {
    # POSIX cksum: "<crc> <size>". Enough to notice that a file changed.
    local file="$1"
    cksum < "${file}" | awk '{ print $1 " " $2 }'
}

config_is_trusted() {
    local file="$1"
    local trust_file
    trust_file="$(config_trust_file)"
    [[ -f "${trust_file}" ]] || return 1

    local expected
    expected="$(config_fingerprint "${file}")"$'\t'"${file}"
    grep -qxF -- "${expected}" "${trust_file}"
}

config_trust() {
    # Records <file>'s current fingerprint, replacing any older record.
    local file="$1"
    if [[ "${file}" == *$'\n'* ]] || [[ "${file}" == *$'\t'* ]]; then
        echo "Error: cannot trust a path containing a tab or newline." >&2
        return 1
    fi

    local trust_file
    trust_file="$(config_trust_file)"
    mkdir -p "$(dirname "${trust_file}")"
    chmod 700 "$(dirname "${trust_file}")"

    local tmp
    tmp="$(mktemp "${trust_file}.XXXXXX")" || return 1
    if [[ -f "${trust_file}" ]]; then
        awk -F'\t' -v path="${file}" '$2 != path' "${trust_file}" > "${tmp}"
    fi
    printf '%s\t%s\n' "$(config_fingerprint "${file}")" "${file}" >> "${tmp}"
    chmod 600 "${tmp}"
    mv "${tmp}" "${trust_file}"
}

# --- Parsing -------------------------------------------------------------

config_decode_value() {
    # Decodes a value as written by config_write (printf %q) or by hand:
    #   ''            empty
    #   'text'        literal, single-quoted
    #   "text"        literal, double-quoted (\" and \\ unescaped)
    #   text\ more    backslash escapes removed
    # Nothing is expanded or executed. $'...' is refused.
    local raw="$1"

    if [[ "${raw}" == "''" ]] || [[ "${raw}" == '""' ]]; then
        return 0
    fi
    if [[ "${raw}" == "\$'"* ]]; then
        return 1
    fi
    if [[ "${raw}" == \'*\' ]] && [[ ${#raw} -ge 2 ]]; then
        printf '%s' "${raw:1:${#raw}-2}"
        return 0
    fi
    if [[ "${raw}" == \"*\" ]] && [[ ${#raw} -ge 2 ]]; then
        raw="${raw:1:${#raw}-2}"
    fi
    printf '%s' "${raw}" | sed 's/\\\(.\)/\1/g'
}

config_is_known_key() {
    local candidate="$1"
    local key
    for key in "${TWK_CONFIG_KEYS[@]}"; do
        [[ "${key}" == "${candidate}" ]] && return 0
    done
    return 1
}

config_parse_file() {
    # Reads KEY=value lines from <file> into the TWK_* variables.
    local file="$1"

    local key
    for key in "${TWK_CONFIG_KEYS[@]}"; do
        printf -v "${key}" '%s' ""
    done

    local line line_number=0 raw value
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line_number=$(( line_number + 1 ))
        line="${line%$'\r'}"
        [[ "${line}" =~ ^[[:space:]]*(#.*)?$ ]] && continue

        if [[ ! "${line}" =~ ^([A-Z_]+)=(.*)$ ]]; then
            echo "Error: ${file}:${line_number}: expected KEY=value." >&2
            return 1
        fi
        key="${BASH_REMATCH[1]}"
        raw="${BASH_REMATCH[2]}"

        if ! config_is_known_key "${key}"; then
            echo "Warning: ${file}:${line_number}: ignoring unknown key ${key}." >&2
            continue
        fi
        if ! value="$(config_decode_value "${raw}")"; then
            echo "Error: ${file}:${line_number}: unsupported quoting for ${key}." >&2
            return 1
        fi
        printf -v "${key}" '%s' "${value}"
    done < "${file}"

    TWK_AUTH="${TWK_AUTH:-pat}"
    TWK_STATE_DONE="${TWK_STATE_DONE:-Done}"
    if [[ -z "${TWK_TIME_FIELD_FEATURE}" ]]; then
        TWK_TIME_FIELD_FEATURE="${TWK_TIME_FIELD_TASK}"
    fi
}

config_validate() {
    local file="$1"
    local problems=()

    [[ -n "${TWK_ORGANIZATION}" ]] || problems+=("TWK_ORGANIZATION is required")
    [[ -n "${TWK_PROJECT}" ]] || problems+=("TWK_PROJECT is required")

    case "${TWK_AUTH}" in
        pat)   [[ -n "${TWK_PAT}" ]] || problems+=("TWK_PAT is required when TWK_AUTH=pat") ;;
        azcli) ;;
        *)     problems+=("TWK_AUTH must be 'pat' or 'azcli', not '${TWK_AUTH}'") ;;
    esac

    if [[ ! "${TWK_TIME_FIELD_TASK}" =~ ${TWK_FIELD_NAME_PATTERN} ]]; then
        problems+=("TWK_TIME_FIELD_TASK must be a field reference name such as Custom.TimeSpent")
    fi
    if [[ ! "${TWK_TIME_FIELD_FEATURE}" =~ ${TWK_FIELD_NAME_PATTERN} ]]; then
        problems+=("TWK_TIME_FIELD_FEATURE must be a field reference name such as Custom.TimeSpent")
    fi

    if [[ ${#problems[@]} -gt 0 ]]; then
        echo "Error: invalid config ${file}:" >&2
        printf '         %s\n' "${problems[@]}" >&2
        return 1
    fi
}

config_scope_data_dir() {
    # Keeps each organisation's and project's sessions apart: work item
    # IDs are only unique within an organisation, and a commit must only
    # ever push to the organisation the time was tracked against.
    # bin/twk sets TWK_DATA_ROOT; tests that set TWK_DATA_DIR directly
    # leave it unset and keep their own directory.
    [[ -n "${TWK_DATA_ROOT:-}" ]] || return 0

    local org project
    org="$(printf '%s' "${TWK_ORGANIZATION}" | tr '[:upper:]' '[:lower:]')"
    project="$(printf '%s' "${TWK_PROJECT}" | tr '[:upper:]' '[:lower:]')"
    TWK_DATA_DIR="${TWK_DATA_ROOT}/scopes/$(url_encode "${org}")/$(url_encode "${project}")"

    session_migrate_legacy
}

config_load() {
    if ! config_exists; then
        local rel="${TWK_LOCAL_CONFIG_DIR_NAME}/${TWK_LOCAL_CONFIG_FILE_NAME}"
        echo "Error: twk not initialised. Run 'twk init' first." >&2
        echo "       (no ${rel} in this directory or any parent, and no global config at $(config_global_file))" >&2
        return 1
    fi

    local file
    file="$(config_active_file)"

    config_check_file_safety "${file}" || return 1

    if [[ "$(config_active_scope)" == "local" ]] && ! config_is_trusted "${file}"; then
        echo "Error: the local config ${file} is not trusted." >&2
        echo "       twk uses a local config only if 'twk init' wrote it or you have" >&2
        echo "       reviewed and approved it. Check its contents, then run 'twk trust'." >&2
        return 1
    fi

    config_parse_file "${file}" || return 1
    config_validate "${file}" || return 1
    config_scope_data_dir
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
    local state_on_start="$8"
    local state_on_pause="$9"
    local state_done="${10}"
    local auth="${11:-pat}"

    local target_dir
    target_dir="$(dirname "${target_file}")"

    mkdir -p "${target_dir}"
    chmod 700 "${target_dir}"

    local escaped_organization escaped_project escaped_team escaped_pat
    local escaped_time_field_task escaped_time_field_feature
    local escaped_state_on_start escaped_state_on_pause escaped_state_done
    local escaped_auth
    printf -v escaped_organization '%q' "${organization}"
    printf -v escaped_project '%q' "${project}"
    printf -v escaped_team '%q' "${team}"
    printf -v escaped_auth '%q' "${auth}"
    printf -v escaped_pat '%q' "${personal_access_token}"
    printf -v escaped_time_field_task '%q' "${time_field_task}"
    printf -v escaped_time_field_feature '%q' "${time_field_feature}"
    printf -v escaped_state_on_start '%q' "${state_on_start}"
    printf -v escaped_state_on_pause '%q' "${state_on_pause}"
    printf -v escaped_state_done '%q' "${state_done}"

    # Created private before anything is written to it.
    ( umask 077; : > "${target_file}" )
    chmod 600 "${target_file}"

    cat > "${target_file}" <<EOF
TWK_ORGANIZATION=${escaped_organization}
TWK_PROJECT=${escaped_project}
TWK_TEAM=${escaped_team}
TWK_AUTH=${escaped_auth}
TWK_PAT=${escaped_pat}
TWK_TIME_FIELD_TASK=${escaped_time_field_task}
TWK_TIME_FIELD_FEATURE=${escaped_time_field_feature}
TWK_STATE_ON_START=${escaped_state_on_start}
TWK_STATE_ON_PAUSE=${escaped_state_on_pause}
TWK_STATE_DONE=${escaped_state_done}
EOF
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

config_prompt_auth() {
    # Prints the chosen auth mode. The Azure CLI is the default when it is
    # installed: no secret is stored, and the organisation's sign-in
    # policy applies.
    local default="pat"
    command -v az &> /dev/null && default="azcli"

    echo "Authentication" >&2
    echo "  azcli  Use your Azure CLI sign-in ('az login'); nothing secret is stored" >&2
    echo "  pat    Use a Personal Access Token, stored in the config file" >&2

    local answer
    read -rp "Authentication method [azcli/pat] (default: ${default}): " answer
    answer="${answer:-${default}}"
    case "${answer}" in
        azcli|pat) echo "${answer}" ;;
        *)
            echo "Error: choose 'azcli' or 'pat'." >&2
            return 1
            ;;
    esac
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

    local organization project team auth personal_access_token=""

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

    echo ""
    auth="$(config_prompt_auth)" || return 1

    if [[ "${auth}" == "pat" ]]; then
        read -rsp "Personal Access Token: " personal_access_token
        echo ""
        if [[ -z "${personal_access_token}" ]]; then
            echo "Error: personal access token is required." >&2
            return 1
        fi
    elif ! command -v az &> /dev/null; then
        echo "Warning: 'az' is not installed. Install the Azure CLI and run 'az login'" >&2
        echo "         before using twk." >&2
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
    if [[ ! "${time_field_task}" =~ ${TWK_FIELD_NAME_PATTERN} ]]; then
        echo "Error: '${time_field_task}' is not a field reference name (e.g. Custom.TimeSpent)." >&2
        return 1
    fi

    read -rp "Time field for Features (leave blank if same as Tasks): " time_field_feature
    if [[ -z "${time_field_feature}" ]]; then
        time_field_feature="${time_field_task}"
    fi
    if [[ ! "${time_field_feature}" =~ ${TWK_FIELD_NAME_PATTERN} ]]; then
        echo "Error: '${time_field_feature}' is not a field reference name (e.g. Custom.TimeSpent)." >&2
        return 1
    fi

    echo ""
    echo "Work item states (optional)"
    echo "twk can move a work item on your board when you start or pause it."
    echo "Use your board's state names (e.g. Active, Doing, In Progress)."
    echo "Leave blank to leave the state alone."
    echo ""

    local state_on_start state_on_pause state_done

    read -rp "State when you start an item (blank: don't change): " state_on_start
    read -rp "State when you pause an item (blank: don't change): " state_on_pause

    read -rp "State for 'twk done' and 'twk end --done' (default: Done): " state_done
    state_done="${state_done:-Done}"

    config_write "${target_file}" \
        "${organization}" "${project}" "${team}" "${personal_access_token}" \
        "${time_field_task}" "${time_field_feature}" \
        "${state_on_start}" "${state_on_pause}" "${state_done}" "${auth}"

    local scope
    if [[ "${use_global}" == true ]]; then
        scope="global"
    else
        scope="local"
        config_trust "${target_file}"
    fi

    echo ""
    echo "Configuration saved to ${target_file} (${scope} scope)"

    if [[ "${use_global}" == false ]]; then
        if [[ "${auth}" == "pat" ]]; then
            config_protect_local "${target_file}"
        fi
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

    config_parse_file "${target_file}" || return 1
    if azdo_test_connection; then
        echo "Connected successfully."
    else
        echo "Warning: connection test failed. Check your settings with 'twk doctor'." >&2
    fi
}

cmd_trust() {
    local skip_confirm=false
    local arg
    for arg in "$@"; do
        case "${arg}" in
            -y|--yes) skip_confirm=true ;;
            *)
                echo "Error: unknown argument '${arg}' for trust." >&2
                echo "Usage: twk trust [-y|--yes]" >&2
                return 1
                ;;
        esac
    done

    local file
    if ! file="$(config_find_local)"; then
        echo "Error: no local ${TWK_LOCAL_CONFIG_DIR_NAME}/${TWK_LOCAL_CONFIG_FILE_NAME} in this directory or any parent." >&2
        return 1
    fi

    config_check_file_safety "${file}" || return 1

    if config_is_trusted "${file}"; then
        echo "${file} is already trusted."
        return
    fi

    echo "Local config: ${file}"
    echo ""
    sed -E 's/^(TWK_PAT=).+$/\1********/' "${file}" | tr -d '\000-\010\013-\037\177' | sed 's/^/    /'
    echo ""

    if [[ "${skip_confirm}" == false ]]; then
        local response
        if ! read -rp "Use this config for twk commands under $(dirname "$(dirname "${file}")")? [y/N] " response; then
            echo "Cancelled." >&2
            return 1
        fi
        case "${response}" in
            y|Y|yes|YES) ;;
            *)
                echo "Cancelled."
                return 1
                ;;
        esac
    fi

    config_trust "${file}"
    echo "Trusted ${file}."
}

doctor_line() {
    local label="$1"
    local text="$2"
    printf '  %-8s %s\n' "${label}" "${text}"
}

cmd_doctor() {
    if [[ $# -gt 0 ]]; then
        echo "Error: 'twk doctor' takes no arguments." >&2
        return 1
    fi

    local healthy=true

    echo "twk ${TWK_VERSION:-?} (bash ${BASH_VERSION})"
    echo ""
    echo "Dependencies"
    local dep
    for dep in curl jq; do
        if command -v "${dep}" &> /dev/null; then
            doctor_line "ok" "${dep}"
        else
            doctor_line "missing" "${dep} (required)"
            healthy=false
        fi
    done
    local optional
    for optional in "fzf:interactive picker" "git:keeps .twk/ out of git" "az:TWK_AUTH=azcli"; do
        dep="${optional%%:*}"
        if command -v "${dep}" &> /dev/null; then
            doctor_line "ok" "${dep}"
        else
            doctor_line "absent" "${dep} (optional: ${optional#*:})"
        fi
    done

    echo ""
    echo "Configuration"
    local file scope
    file="$(config_active_file)"
    scope="$(config_active_scope)"
    if [[ ! -f "${file}" ]]; then
        doctor_line "missing" "no config found; run 'twk init'"
        echo ""
        echo "Problems found."
        return 1
    fi

    local trust_note=""
    if [[ "${scope}" == "local" ]]; then
        if config_is_trusted "${file}"; then
            trust_note=", trusted"
        else
            trust_note=", NOT trusted: review it, then run 'twk trust'"
        fi
    fi
    doctor_line "file" "${file} (${scope}${trust_note})"

    if ! config_load > /dev/null; then
        echo ""
        echo "Problems found."
        return 1
    fi

    doctor_line "org" "${TWK_ORGANIZATION}"
    doctor_line "project" "${TWK_PROJECT}"
    doctor_line "team" "${TWK_TEAM:-(default team)}"
    if [[ "${TWK_AUTH}" == "pat" ]]; then
        doctor_line "auth" "Personal Access Token (set, ${#TWK_PAT} characters)"
    else
        doctor_line "auth" "Azure CLI sign-in"
    fi
    doctor_line "time" "${TWK_TIME_FIELD_TASK} (tasks), ${TWK_TIME_FIELD_FEATURE} (features)"
    doctor_line "states" "start → ${TWK_STATE_ON_START:-(no change)}, pause → ${TWK_STATE_ON_PAUSE:-(no change)}, done → ${TWK_STATE_DONE}"
    local uncommitted
    uncommitted="$(session_list_uncommitted | grep -c . || true)"
    doctor_line "sessions" "${TWK_DATA_DIR} (${uncommitted} uncommitted)"

    echo ""
    echo "Connection"
    local response user
    if response="$(azdo_fetch_authenticated_user)"; then
        user="$(printf '%s' "${response}" | jq -r '.authenticatedUser.properties.Account["$value"] // .authenticatedUser.providerDisplayName // "?"')"
        doctor_line "ok" "connected to ${TWK_ORGANIZATION} as ${user}"
    else
        doctor_line "failed" "could not connect (see the error above)"
        healthy=false
    fi

    echo ""
    if [[ "${healthy}" == true ]]; then
        echo "All good."
    else
        echo "Problems found."
        return 1
    fi
}
