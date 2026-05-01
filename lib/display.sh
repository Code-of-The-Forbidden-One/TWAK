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

readonly LIST_DESC_TRUNCATE=240
readonly LIST_TITLE_WIDTH=32
readonly LIST_ASSIGNED_WIDTH=15
readonly LIST_DESC_INDENT="           "
readonly LIST_DESC_WRAP_WIDTH=78

twk_pager_cmd() {
    # Returns the pager command to invoke (printed to stdout). Empty
    # output means "no pager — use cat passthrough." This is split from
    # twk_pager so the decision logic is unit-testable without a TTY.
    if [[ -n "${TWK_NO_PAGER:-}" ]]; then
        return
    fi
    if [[ -n "${PAGER+x}" ]]; then
        # PAGER explicitly set (possibly to empty). Honour it verbatim.
        printf '%s' "${PAGER}"
        return
    fi
    # Default: less with -F (no-page when output fits one screen),
    # -R (raw control codes), -X (keep output visible after quit).
    # Fall through to cat if less isn't installed (minimal containers).
    if command -v less &> /dev/null; then
        printf 'less -FRX'
    fi
}

twk_pager() {
    # Page only when stdout is a TTY. Piped/redirected output passes through.
    if [[ ! -t 1 ]]; then
        cat
        return
    fi
    local pager
    pager="$(twk_pager_cmd)"
    if [[ -z "${pager}" ]]; then
        cat
    else
        # shellcheck disable=SC2086  # intentional word-splitting on pager command
        ${pager}
    fi
}

normalise_description() {
    local html="$1"
    # Optional max-length. 0 disables truncation (used by `twk show`).
    local max_len="${2:-${LIST_DESC_TRUNCATE}}"

    if [[ -z "${html}" ]]; then
        echo "(no description)"
        return
    fi
    local plain
    plain="$(printf '%s' "${html}" \
        | sed 's/<[^>]*>//g
               s/&nbsp;/ /g
               s/&amp;/\&/g
               s/&lt;/</g
               s/&gt;/>/g
               s/&quot;/"/g
               s/&#39;/'\''/g' \
        | tr -s '[:space:]' ' ' \
        | sed 's/^ //;s/ $//')"
    if [[ -z "${plain}" ]]; then
        echo "(no description)"
        return
    fi
    if (( max_len > 0 && ${#plain} > max_len )); then
        printf '%s...' "${plain:0:max_len}"
    else
        printf '%s' "${plain}"
    fi
}

render_list_row() {
    local item_json="$1"

    local id title type state priority est done assigned
    id="$(echo "${item_json}"          | jq -r '.id')"
    title="$(echo "${item_json}"       | jq -r '.fields["System.Title"] // ""')"
    type="$(echo "${item_json}"        | jq -r '.fields["System.WorkItemType"] // ""')"
    state="$(echo "${item_json}"       | jq -r '.fields["System.State"] // ""')"
    priority="$(echo "${item_json}"    | jq -r '.fields["Microsoft.VSTS.Common.Priority"] // "-"')"
    est="$(echo "${item_json}"         | jq -r '.fields["Microsoft.VSTS.Scheduling.OriginalEstimate"] // empty')"
    [[ -z "${est}" ]] && est="-" || est="${est}h"

    local time_field
    case "${type}" in
        Feature) time_field="${TWK_TIME_FIELD_FEATURE}" ;;
        *)       time_field="${TWK_TIME_FIELD_TASK}" ;;
    esac
    done="$(echo "${item_json}" | jq -r --arg f "${time_field}" '.fields[$f] // empty')"
    [[ -z "${done}" ]] && done="-" || done="${done}h"

    # System.AssignedTo is an object {displayName, uniqueName, ...} when set,
    # null/missing when unassigned. The `?` suppresses errors for the legacy
    # string form (older API versions) so it falls through to "-".
    assigned="$(echo "${item_json}" | jq -r '.fields["System.AssignedTo"].displayName? // "-"')"

    printf "  #%-7s %-${LIST_TITLE_WIDTH}s %-10s %-4s %-8s %-8s %s\n" \
        "${id}" \
        "$(truncate_title "${title}" "${LIST_TITLE_WIDTH}")" \
        "${state}" \
        "${priority}" \
        "${est}" \
        "${done}" \
        "$(truncate_title "${assigned}" "${LIST_ASSIGNED_WIDTH}")"
}

render_list_item() {
    local item_json="$1"

    render_list_row "${item_json}"

    local description
    description="$(normalise_description "$(echo "${item_json}" | jq -r '.fields["System.Description"] // ""')")"
    printf '%s' "${description}" \
        | fold -s -w "${LIST_DESC_WRAP_WIDTH}" \
        | awk -v ind="${LIST_DESC_INDENT}" '{ print ind $0 }'
}

cmd_list_interactive() {
    local batch_response="$1"
    local iteration_name="$2"

    if ! command -v fzf &> /dev/null; then
        echo "Error: 'twk list -i' requires fzf. Install fzf or use 'twk list' for static output." >&2
        return 1
    fi

    local preview_dir
    preview_dir="$(mktemp -d -t twk-list-XXXXXX)" || {
        echo "Error: failed to create temp dir for preview." >&2
        return 1
    }
    # shellcheck disable=SC2064  # expand preview_dir at trap-set time
    trap "rm -rf '${preview_dir}'" RETURN

    local fzf_input=""
    local item id row
    while IFS= read -r item; do
        id="$(echo "${item}" | jq -r '.id')"
        render_show_item "${item}" > "${preview_dir}/${id}.preview"
        row="$(render_list_row "${item}")"
        fzf_input+="${id}"$'\t'"${row}"$'\n'
    done < <(echo "${batch_response}" | jq -c '.value[]')

    local header="Sprint: ${iteration_name}  ·  enter=select  esc=cancel  ctrl-/=preview off"
    local selected
    selected="$(printf '%s' "${fzf_input}" \
        | fzf --header="${header}" \
              --delimiter=$'\t' \
              --with-nth=2 \
              --preview="cat '${preview_dir}/'{1}.preview" \
              --preview-window=right:55%:wrap \
              --bind='ctrl-/:toggle-preview' \
              --reverse \
              --height=95%)" || return 0

    [[ -n "${selected}" ]] || return 0

    printf '%s\n' "${selected}" | cut -f1
}

cmd_list() {
    config_require

    local interactive=false
    local arg
    for arg in "$@"; do
        case "${arg}" in
            -i|--interactive) interactive=true ;;
            *)
                echo "Error: unknown argument '${arg}' for list." >&2
                echo "Usage: twk list [-i|--interactive]" >&2
                return 1
                ;;
        esac
    done

    local iteration_response
    iteration_response="$(azdo_fetch_current_iteration)" || {
        echo "Error: failed to fetch current iteration." >&2
        return 1
    }

    local iteration_id iteration_name
    iteration_id="$(echo "${iteration_response}"   | jq -r '.value[0].id')"
    iteration_name="$(echo "${iteration_response}" | jq -r '.value[0].name // .value[0].path // ""')"

    if [[ -z "${iteration_id}" || "${iteration_id}" == "null" ]]; then
        echo "Error: no current iteration found." >&2
        return 1
    fi

    local items_response
    items_response="$(azdo_fetch_iteration_work_items "${iteration_id}")" || {
        echo "Error: failed to fetch work items for current iteration." >&2
        return 1
    }

    local ids_json
    ids_json="$(echo "${items_response}" | jq '[.workItemRelations[].target.id] | unique')"

    if [[ "${ids_json}" == "[]" || -z "${ids_json}" ]]; then
        echo "Current sprint${iteration_name:+: }${iteration_name}"
        echo "No work items in current sprint."
        return
    fi

    local batch_response
    batch_response="$(azdo_fetch_sprint_with_details "${ids_json}")" || {
        echo "Error: failed to fetch work item details." >&2
        return 1
    }

    if [[ "${interactive}" == true ]]; then
        cmd_list_interactive "${batch_response}" "${iteration_name}"
        return
    fi

    local count
    count="$(echo "${batch_response}" | jq '.value | length')"

    local rule
    rule="$(printf '─%.0s' $(seq 1 95))"

    {
        echo "Current sprint${iteration_name:+: }${iteration_name}"
        echo ""
        echo "${rule}"
        printf "  %-8s %-${LIST_TITLE_WIDTH}s %-10s %-4s %-8s %-8s %s\n" \
            "ID" "Title" "State" "Pri" "Est" "Done" "Assigned"
        echo "${rule}"

        local item
        while IFS= read -r item; do
            render_list_item "${item}"
        done < <(echo "${batch_response}" | jq -c '.value[]')

        echo "${rule}"
        echo "(${count} item$( (( count != 1 )) && echo s ) in sprint)"
    } | twk_pager
}

render_show_item() {
    local item_json="$1"

    local id title type state priority est done assigned iteration description
    id="$(echo "${item_json}"          | jq -r '.id')"
    title="$(echo "${item_json}"       | jq -r '.fields["System.Title"] // ""')"
    type="$(echo "${item_json}"        | jq -r '.fields["System.WorkItemType"] // ""')"
    state="$(echo "${item_json}"       | jq -r '.fields["System.State"] // ""')"
    priority="$(echo "${item_json}"    | jq -r '.fields["Microsoft.VSTS.Common.Priority"] // "-"')"

    est="$(echo "${item_json}"         | jq -r '.fields["Microsoft.VSTS.Scheduling.OriginalEstimate"] // empty')"
    [[ -z "${est}" ]] && est="-" || est="${est}h"

    local time_field
    case "${type}" in
        Feature) time_field="${TWK_TIME_FIELD_FEATURE}" ;;
        *)       time_field="${TWK_TIME_FIELD_TASK}" ;;
    esac
    done="$(echo "${item_json}" | jq -r --arg f "${time_field}" '.fields[$f] // empty')"
    [[ -z "${done}" ]] && done="-" || done="${done}h"

    assigned="$(echo "${item_json}"  | jq -r '.fields["System.AssignedTo"].displayName? // "-"')"
    iteration="$(echo "${item_json}" | jq -r '.fields["System.IterationPath"] // "-"')"

    description="$(normalise_description \
        "$(echo "${item_json}" | jq -r '.fields["System.Description"] // ""')" \
        0)"

    local rule
    rule="$(printf '─%.0s' $(seq 1 78))"

    echo "${rule}"
    echo "#${id} - ${title}"
    echo "${rule}"
    printf "  Type:       %s\n" "${type:--}"
    printf "  State:      %s\n" "${state:--}"
    printf "  Priority:   %s\n" "${priority}"
    printf "  Assigned:   %s\n" "${assigned}"
    printf "  Estimate:   %s\n" "${est}"
    printf "  Done:       %s\n" "${done}"
    printf "  Iteration:  %s\n" "${iteration}"
    echo ""
    echo "Description:"
    printf '%s\n' "${description}" | fold -s -w 78
}

readonly USERS_ID_WIDTH=36
readonly USERS_NAME_WIDTH=25
readonly USERS_EMAIL_WIDTH=32

cmd_users() {
    config_require

    local all=false
    local arg
    for arg in "$@"; do
        case "${arg}" in
            --all) all=true ;;
            *)
                echo "Error: unknown argument '${arg}' for users." >&2
                echo "Usage: twk users [--all]" >&2
                return 1
                ;;
        esac
    done

    local users_tsv
    local heading
    if [[ "${all}" == true ]]; then
        heading="Users in the Azure DevOps organisation:"
        local response
        response="$(azdo_fetch_org_users 2>/dev/null)" || {
            echo "Error: could not query org-wide users from Azure DevOps." >&2
            echo "       The Graph API needs 'Graph (Read)' scope on your PAT, in" >&2
            echo "       addition to 'Work Items (Read & Write)'. Regenerate your" >&2
            echo "       PAT with the extra scope and re-run 'twk init'." >&2
            return 1
        }
        users_tsv="$(echo "${response}" | jq -r '
            [
                .value[]?
                | select(.subjectKind == "user")
                | { id: (.descriptor // "-"), name: (.displayName // "-"), email: (.principalName // .mailAddress // "-") }
                | select(.email != "-")
            ]
            | unique_by(.email)
            | sort_by(.name | ascii_downcase)
            | .[]
            | "\(.id)\t\(.name)\t\(.email)"
        ')"
    else
        heading="Users assigned to current sprint items:"
        local items_json
        items_json="$(fetch_current_sprint_items)" || return 1
        users_tsv="$(echo "${items_json}" | jq -r '
            [
                .value[]
                | .fields["System.AssignedTo"]?
                | select(. != null and (. | type) == "object")
                | { id: (.id // "-"), name: (.displayName // "-"), email: (.uniqueName // "-") }
            ]
            | unique_by(.id)
            | sort_by(.name | ascii_downcase)
            | .[]
            | "\(.id)\t\(.name)\t\(.email)"
        ')"
    fi

    if [[ -z "${users_tsv}" ]]; then
        if [[ "${all}" == true ]]; then
            echo "No users returned from the org Graph API."
        else
            echo "No assigned users in current sprint."
        fi
        return
    fi

    local count
    count="$(printf '%s\n' "${users_tsv}" | grep -c '^')"

    local rule_width=$(( USERS_ID_WIDTH + USERS_NAME_WIDTH + USERS_EMAIL_WIDTH + 6 ))
    local rule
    rule="$(printf '─%.0s' $(seq 1 "${rule_width}"))"

    {
        echo "${heading}"
        echo ""
        echo "${rule}"
        printf "  %-${USERS_ID_WIDTH}s %-${USERS_NAME_WIDTH}s %s\n" \
            "ID" "Username" "Email"
        echo "${rule}"

        local id name email
        while IFS=$'\t' read -r id name email; do
            printf "  %-${USERS_ID_WIDTH}s %-${USERS_NAME_WIDTH}s %s\n" \
                "$(truncate_title "${id}" "${USERS_ID_WIDTH}")" \
                "$(truncate_title "${name}" "${USERS_NAME_WIDTH}")" \
                "$(truncate_title "${email}" "${USERS_EMAIL_WIDTH}")"
        done <<< "${users_tsv}"

        echo "${rule}"
        echo "(${count} user$( (( count != 1 )) && echo s ))"
    } | twk_pager
}

render_discussion() {
    local work_item_id="$1"

    local response
    response="$(azdo_fetch_comments "${work_item_id}" 2>/dev/null)" || {
        echo "Discussion: (could not fetch comments — check PAT and connectivity)"
        return
    }

    local count
    count="$(echo "${response}" | jq -r '.totalCount // (.comments | length) // 0')"

    if [[ "${count}" -eq 0 ]]; then
        echo "Discussion: (no comments)"
        return
    fi

    local rule
    rule="$(printf '─%.0s' $(seq 1 78))"

    echo "Discussion (${count} comment$( (( count != 1 )) && echo s )):"
    echo "${rule}"

    # Stream one comment per line: timestamp<TAB>author<TAB>text-as-base64.
    # Base64 sidesteps any embedded tabs/newlines/quotes in the HTML body.
    echo "${response}" | jq -r '
        .comments
        | sort_by(.createdDate)
        | .[]
        | "\(.createdDate // "" | sub("T"; " ") | .[0:16])\t\(.createdBy.displayName // "Unknown")\t\(.text // "" | @base64)"
    ' | while IFS=$'\t' read -r ts author html_b64; do
        echo ""
        echo "[${ts}] ${author}:"
        local html plain
        html="$(printf '%s' "${html_b64}" | base64 -d)"
        plain="$(normalise_description "${html}" 0)"
        printf '%s\n' "${plain}" | fold -s -w 76 | sed 's/^/  /'
    done

    echo ""
    echo "${rule}"
}

cmd_show() {
    config_require

    local discussion=false
    local positional=()
    local arg
    for arg in "$@"; do
        case "${arg}" in
            --discussion) discussion=true ;;
            *)            positional+=("${arg}") ;;
        esac
    done

    if [[ ${#positional[@]} -gt 1 ]]; then
        echo "Error: too many arguments." >&2
        echo "Usage: twk show [task] [--discussion]" >&2
        return 1
    fi

    local query="${positional[0]:-}"
    local work_item_id
    work_item_id="$(resolve_work_item "${query}")" || return 1

    local item_json
    item_json="$(azdo_fetch_work_item "${work_item_id}")" || {
        echo "Error: failed to fetch work item #${work_item_id}." >&2
        return 1
    }

    {
        render_show_item "${item_json}"
        if [[ "${discussion}" == true ]]; then
            echo ""
            render_discussion "${work_item_id}"
        fi
    } | twk_pager
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

    {
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
    } | twk_pager
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
