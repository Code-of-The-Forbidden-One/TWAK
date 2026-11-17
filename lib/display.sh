format_duration() {
    local total_seconds="$1"
    local hours=$(( total_seconds / 3600 ))
    local minutes=$(( (total_seconds % 3600) / 60 ))
    local seconds=$(( total_seconds % 60 ))

    printf "%02d:%02d:%02d" "${hours}" "${minutes}" "${seconds}"
}

# Hours are handled as integer hundredths of an hour ("cents"), rounded
# to the nearest, and printed with a leading zero ("0.50", never ".50":
# the value goes into JSON, where ".50" is not a number).

seconds_to_hundredths() {
    local total_seconds="$1"
    echo $(( (total_seconds * 100 + 1800) / 3600 ))
}

hundredths_to_hours() {
    local hundredths="$1"
    local sign=""
    if [[ "${hundredths}" -lt 0 ]]; then
        sign="-"
        hundredths=$(( -hundredths ))
    fi
    printf '%s%d.%02d' "${sign}" $(( hundredths / 100 )) $(( hundredths % 100 ))
}

hours_to_hundredths() {
    # Converts an hours value from Azure DevOps (4, 4.2, "1.5", null) to
    # hundredths, rounded. Anything unreadable counts as 0.
    local hours="${1:-0}"
    jq -n --arg h "${hours}" '(($h | tonumber?) // 0) * 100 | round'
}

seconds_to_hours() {
    local total_seconds="$1"
    hundredths_to_hours "$(seconds_to_hundredths "${total_seconds}")"
}

format_epoch() {
    # "YYYY-MM-DD HH:MM" for an epoch, with GNU date or BSD/macOS date.
    local epoch="$1"
    date -d "@${epoch}" +"%Y-%m-%d %H:%M" 2>/dev/null \
        || date -r "${epoch}" +"%Y-%m-%d %H:%M" 2>/dev/null \
        || echo "?"
}

parse_duration() {
    # Accepts:
    #   - decimal hours alone:  "2.5h", "0.25h"
    #   - integer combos:       "30m", "1h", "1h30m", "1h30m45s", "45s"
    # Echoes the total seconds. Returns 1 on parse failure.
    local input="$1"

    if [[ -z "${input}" ]]; then
        return 1
    fi

    # Decimal hours is its own special form.
    if [[ "${input}" =~ ^[0-9]+\.[0-9]+h$ ]]; then
        local h="${input%h}"
        jq -n --arg h "${h}" '($h | tonumber) * 3600 | floor'
        return 0
    fi

    # Integer h/m/s combinations. The whole string must match.
    if [[ ! "${input}" =~ ^([0-9]+h)?([0-9]+m)?([0-9]+s)?$ ]] || [[ "${input}" == "" ]]; then
        return 1
    fi

    # Each anchor used at most once. Empty match → 0.
    local total=0
    if [[ "${input}" =~ ([0-9]+)h ]]; then
        total=$(( total + BASH_REMATCH[1] * 3600 ))
    fi
    if [[ "${input}" =~ ([0-9]+)m ]]; then
        total=$(( total + BASH_REMATCH[1] * 60 ))
    fi
    if [[ "${input}" =~ ([0-9]+)s ]]; then
        total=$(( total + BASH_REMATCH[1] ))
    fi

    echo "${total}"
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
        # LESSCHARSET=utf-8 forces less to handle multi-byte UTF-8 (box-
        # drawing chars, em-dashes, etc.) correctly even when the system
        # locale is POSIX/C — common in slim Docker images. Other pagers
        # ignore the unfamiliar env var.
        # shellcheck disable=SC2086  # intentional word-splitting on pager command
        LESSCHARSET=utf-8 ${pager}
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
    # Replace tags with a single space (not empty) so adjacent tags
    # like </div><br> don't fuse the surrounding words together.
    # The whitespace-collapse step below normalises any double-spacing
    # that introduces.
    plain="$(printf '%s' "${html}" \
        | sed 's/<[^>]*>/ /g
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

    local id title type state priority est done_hours assigned
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
    done_hours="$(echo "${item_json}" | jq -r --arg f "${time_field}" '.fields[$f] // empty')"
    [[ -z "${done_hours}" ]] && done_hours="-" || done_hours="${done_hours}h"

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
        "${done_hours}" \
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

sort_list_items() {
    # Sort a workitemsbatch response's .value[] by the named column.
    # Args: <batch_json> <column> <desc-bool>
    # Echoes the sorted JSON. Missing/null values for the sort key sort to
    # the end (high sentinel for numbers, "zzz" for strings).
    local batch="$1"
    local col="$2"
    local desc="$3"

    local sorted
    sorted="$(printf '%s' "${batch}" | jq \
        --arg col "${col}" \
        --arg task_field "${TWK_TIME_FIELD_TASK}" \
        --arg feat_field "${TWK_TIME_FIELD_FEATURE}" '
        .value = (
            .value
            | sort_by(
                if   $col == "id"       then .id
                elif $col == "title"    then (.fields["System.Title"] // "" | ascii_downcase)
                elif $col == "state"    then (.fields["System.State"] // "")
                elif $col == "pri"      then (.fields["Microsoft.VSTS.Common.Priority"] // 999)
                elif $col == "est"      then (.fields["Microsoft.VSTS.Scheduling.OriginalEstimate"] // 999999)
                elif $col == "done"     then (
                    if .fields["System.WorkItemType"] == "Feature"
                    then (.fields[$feat_field] // 999999)
                    else (.fields[$task_field] // 999999)
                    end
                )
                elif $col == "assigned" then (.fields["System.AssignedTo"].displayName? // "zzz" | ascii_downcase)
                else 0
                end
            )
        )
    ')"

    if [[ "${desc}" == true ]]; then
        sorted="$(printf '%s' "${sorted}" | jq '.value |= reverse')"
    fi

    printf '%s' "${sorted}"
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
    local sort_col=""
    local sort_desc=false
    local arg
    for arg in "$@"; do
        case "${arg}" in
            -i|--interactive) interactive=true ;;
            --sort=*)
                sort_col="${arg#--sort=}"
                if [[ "${sort_col}" == -* ]]; then
                    sort_desc=true
                    sort_col="${sort_col#-}"
                fi
                case "${sort_col}" in
                    id|title|state|pri|est|done|assigned) ;;
                    "")
                        echo "Error: --sort requires a column name." >&2
                        echo "Valid: id, title, state, pri, est, done, assigned" >&2
                        return 1
                        ;;
                    *)
                        echo "Error: unknown sort column '${sort_col}'." >&2
                        echo "Valid: id, title, state, pri, est, done, assigned" >&2
                        return 1
                        ;;
                esac
                ;;
            *)
                echo "Error: unknown argument '${arg}' for list." >&2
                echo "Usage: twk list [-i|--interactive] [--sort=<col>]" >&2
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

    if [[ -n "${sort_col}" ]]; then
        batch_response="$(sort_list_items "${batch_response}" "${sort_col}" "${sort_desc}")"
    fi

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

    local id title type state priority est done_hours assigned iteration description
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
    done_hours="$(echo "${item_json}" | jq -r --arg f "${time_field}" '.fields[$f] // empty')"
    [[ -z "${done_hours}" ]] && done_hours="-" || done_hours="${done_hours}h"

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
    printf "  Done:       %s\n" "${done_hours}"
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
        response="$(azdo_fetch_org_users)" || {
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
    response="$(azdo_fetch_comments "${work_item_id}")" || {
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

cmd_comment() {
    config_require

    local positional=()
    local arg
    for arg in "$@"; do
        positional+=("${arg}")
    done

    if [[ ${#positional[@]} -gt 2 ]]; then
        echo "Error: too many arguments." >&2
        echo "Usage: twk comment [task] [text|-]" >&2
        return 1
    fi

    local task_query="${positional[0]:-}"
    local text_arg=""
    local has_text_arg=false
    if [[ ${#positional[@]} -ge 2 ]]; then
        has_text_arg=true
        text_arg="${positional[1]}"
    fi

    local work_item_id
    work_item_id="$(resolve_work_item "${task_query}")" || return 1

    local text
    if [[ "${has_text_arg}" == true ]]; then
        if [[ "${text_arg}" == "-" ]]; then
            # Read from stdin (e.g. piped: cat notes.txt | twk comment 12345 -)
            text="$(cat)"
        else
            text="${text_arg}"
        fi
    else
        # Open $EDITOR (or $VISUAL, falling back to vi). The editor takes
        # over the terminal directly — no command substitution wrapping.
        local editor="${VISUAL:-${EDITOR:-vi}}"
        local tmpfile
        tmpfile="$(mktemp -t twk-comment-XXXXXX)" || {
            echo "Error: failed to create temp file." >&2
            return 1
        }

        cat > "${tmpfile}" <<EOF


# Enter your comment for #${work_item_id} above.
# Lines starting with '#' are stripped from the comment.
# Save empty content to abort.
EOF

        if ! "${editor}" "${tmpfile}"; then
            rm -f "${tmpfile}"
            echo "Error: editor exited non-zero, aborting." >&2
            return 1
        fi

        text="$(grep -v '^#' "${tmpfile}")"
        rm -f "${tmpfile}"
    fi

    if [[ -z "${text//[[:space:]]/}" ]]; then
        echo "Error: empty comment, aborting." >&2
        return 1
    fi

    local response
    response="$(azdo_post_comment "${work_item_id}" "${text}")" || {
        echo "Error: failed to post comment on #${work_item_id}." >&2
        return 1
    }

    local ts
    ts="$(echo "${response}" | jq -r '.createdDate // "" | sub("T"; " ") | .[0:16]')"

    if [[ -n "${ts}" ]]; then
        echo "Posted comment on #${work_item_id} at ${ts}:"
    else
        echo "Posted comment on #${work_item_id}:"
    fi
    printf '%s\n' "${text}" | sed 's/^/  /'
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

cmd_log() {
    local days=7
    local show_all=false
    local by_id=false
    local arg
    for arg in "$@"; do
        case "${arg}" in
            --all)     show_all=true ;;
            --by-id)   by_id=true ;;
            --days=*)
                days="${arg#--days=}"
                if ! [[ "${days}" =~ ^[0-9]+$ ]]; then
                    echo "Error: --days requires a non-negative integer." >&2
                    return 1
                fi
                ;;
            *)
                echo "Error: unknown argument '${arg}' for log." >&2
                echo "Usage: twk log [--days=N | --all] [--by-id]" >&2
                return 1
                ;;
        esac
    done

    # Reads only local files, but needs the config to know which
    # organisation's and project's history to show.
    config_require

    local committed_dir="${TWK_DATA_DIR}/committed"
    if [[ ! -d "${committed_dir}" ]]; then
        echo "No commits yet."
        return
    fi

    local cutoff=0
    if [[ "${show_all}" == false ]]; then
        cutoff=$(( $(date +%s) - days * 86400 ))
    fi

    # Collect TSV rows: datetime<TAB>id<TAB>elapsed_seconds<TAB>title
    # datetime format: "YYYY-MM-DD HH:MM" (sorts naturally lexically).
    local rows=""
    local f fname id ts elapsed_seconds datetime_str title meta_file
    for f in "${committed_dir}"/*.session; do
        [[ -f "${f}" ]] || continue
        fname="$(basename "${f}" .session)"
        # Skip malformed names (need <id>_<ts> shape).
        [[ "${fname}" == *_* ]] || continue
        id="${fname%_*}"
        ts="${fname##*_}"
        # Numeric ts only.
        [[ "${ts}" =~ ^[0-9]+$ ]] || continue

        if [[ "${show_all}" == false ]] && [[ "${ts}" -lt "${cutoff}" ]]; then
            continue
        fi

        elapsed_seconds="$(session_elapsed_from_path "${f}")"
        datetime_str="$(format_epoch "${ts}")"

        title=""
        meta_file="${committed_dir}/${id}_${ts}.meta"
        if [[ -f "${meta_file}" ]]; then
            title="$(jq -r '.title // ""' "${meta_file}" 2>/dev/null)"
        fi
        [[ -z "${title}" ]] && title="(no title cached)"

        rows+="${datetime_str}"$'\t'"${id}"$'\t'"${elapsed_seconds}"$'\t'"${title}"$'\n'
    done

    if [[ -z "${rows}" ]]; then
        if [[ "${show_all}" == true ]]; then
            echo "No commits found."
        else
            echo "No commits in the last ${days} day$( (( days != 1 )) && echo s )."
        fi
        return
    fi

    {
        local total_seconds=0
        local count=0
        local sorted

        if [[ "${by_id}" == true ]]; then
            # Group by id (numeric asc), within group datetime desc.
            sorted="$(printf '%s' "${rows}" | sort -t$'\t' -k2,2n -k1,1r)"

            local last_id="" id_subtotal=0 row_id row_datetime row_elapsed row_title
            while IFS=$'\t' read -r row_datetime row_id row_elapsed row_title; do
                [[ -z "${row_datetime}" ]] && continue
                if [[ "${row_id}" != "${last_id}" ]]; then
                    if [[ -n "${last_id}" ]]; then
                        printf "  Subtotal: %sh\n\n" "$(seconds_to_hours "${id_subtotal}")"
                        id_subtotal=0
                    fi
                    printf "#%s  %s\n" "${row_id}" "${row_title}"
                    last_id="${row_id}"
                fi
                # Full datetime per row (e.g. "2026-05-02 14:22  3.38h").
                printf "  %s  %sh\n" "${row_datetime}" "$(seconds_to_hours "${row_elapsed}")"
                id_subtotal=$(( id_subtotal + row_elapsed ))
                total_seconds=$(( total_seconds + row_elapsed ))
                count=$(( count + 1 ))
            done <<< "${sorted}"
            if [[ -n "${last_id}" ]]; then
                printf "  Subtotal: %sh\n" "$(seconds_to_hours "${id_subtotal}")"
            fi
        else
            # Group by date (desc), within day datetime desc (newer commits
            # first within the same day), tie-break by id asc.
            sorted="$(printf '%s' "${rows}" | sort -t$'\t' -k1,1r -k2,2n)"

            local last_date="" row_id row_datetime row_date row_time row_elapsed row_title
            while IFS=$'\t' read -r row_datetime row_id row_elapsed row_title; do
                [[ -z "${row_datetime}" ]] && continue
                # Split datetime into date (group key) and time (column on each row).
                row_date="${row_datetime%% *}"
                row_time="${row_datetime#* }"
                if [[ "${row_date}" != "${last_date}" ]]; then
                    [[ -n "${last_date}" ]] && echo ""
                    printf "%s\n" "${row_date}"
                    last_date="${row_date}"
                fi
                printf "  %s  #%-7s %-40s %sh\n" \
                    "${row_time}" \
                    "${row_id}" \
                    "$(truncate_title "${row_title}")" \
                    "$(seconds_to_hours "${row_elapsed}")"
                total_seconds=$(( total_seconds + row_elapsed ))
                count=$(( count + 1 ))
            done <<< "${sorted}"
        fi

        echo ""
        echo "Total: $(seconds_to_hours "${total_seconds}")h across ${count} session$( (( count != 1 )) && echo s )."
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
    local existing_hundredths tracked_hundredths

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
                # Normalise to 2dp so a JSON value like 4.2 renders as 4.20h,
                # matching the formatting of tracked/total columns.
                existing_hundredths="$(hours_to_hundredths "${existing}")"
                tracked_hundredths="$(seconds_to_hundredths "${elapsed_seconds}")"
                existing_display="$(hundredths_to_hours "${existing_hundredths}")h"
                total_display="$(hundredths_to_hours $(( existing_hundredths + tracked_hundredths )))h"
                total_existing=$(( total_existing + existing_hundredths ))
                total_combined=$(( total_combined + existing_hundredths + tracked_hundredths ))
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
            "$(hundredths_to_hours "${total_existing}")h" \
            "$(hundredths_to_hours "${total_combined}")h"
    else
        printf "  %-8s %-${STATUS_TITLE_WIDTH}s %-10s %-12s %sh\n" \
            "Total" "" "" \
            "$(format_duration "${total_seconds}")" \
            "$(seconds_to_hours "${total_seconds}")"
    fi
    } | twk_pager
}

commit_pending_path() {
    local work_item_id="$1"
    echo "${TWK_DATA_DIR}/${work_item_id}.pending"
}

commit_one_locked() {
    # Commits one session. Echoes one line of output. Returns:
    #   0 committed (or would be, on a dry run); 1 failed; 3 skipped.
    # Prints the tracked hundredths on fd 3 for the dry-run total.
    local work_item_id="$1"
    local dry_run="$2"

    if [[ "$(session_read_state "${work_item_id}")" == "${STATE_RUNNING}" ]]; then
        echo "  #${work_item_id}: skipped (still running - end or pause first)"
        return 3
    fi

    local elapsed_seconds new_hundredths
    elapsed_seconds="$(session_calculate_elapsed_seconds "${work_item_id}")"
    new_hundredths="$(seconds_to_hundredths "${elapsed_seconds}")"

    # Never write without the current value: a failed read must not be
    # taken as zero, or the commit would overwrite the hours already there.
    local work_item
    if ! work_item="$(azdo_fetch_work_item "${work_item_id}")" || [[ -z "${work_item}" ]]; then
        echo "  #${work_item_id}: failed (could not read the current hours; nothing was written)" >&2
        return 1
    fi

    local time_field rev existing_hundredths
    time_field="$(azdo_time_field_for_type \
        "$(printf '%s' "${work_item}" | jq -r '.fields["System.WorkItemType"] // ""')")"
    rev="$(printf '%s' "${work_item}" | jq -r '.rev // empty')"
    existing_hundredths="$(hours_to_hundredths \
        "$(printf '%s' "${work_item}" | jq -r --arg f "${time_field}" '.fields[$f] // 0')")"

    # A previous commit whose response was lost leaves a pending record.
    # If the work item has since moved on and holds exactly the total
    # that commit wrote, it landed: archive the session, don't add again.
    local pending_file
    pending_file="$(commit_pending_path "${work_item_id}")"
    if [[ -f "${pending_file}" ]]; then
        local pending_rev pending_total
        read -r pending_rev pending_total < "${pending_file}" || true
        if [[ "${pending_rev}" =~ ^[0-9]+$ ]] && [[ "${pending_total}" =~ ^[0-9]+$ ]] \
            && [[ -n "${rev}" ]] && [[ "${rev}" -gt "${pending_rev}" ]] \
            && [[ "${existing_hundredths}" -eq "${pending_total}" ]]; then
            if [[ "${dry_run}" == true ]]; then
                echo "  #${work_item_id}: already committed by an earlier run; would be archived"
                return 3
            fi
            session_mark_committed "${work_item_id}"
            rm -f "${pending_file}"
            echo "  #${work_item_id}: already committed by an earlier run (total: $(hundredths_to_hours "${pending_total}")h); archived"
            return 0
        fi
        [[ "${dry_run}" == true ]] || rm -f "${pending_file}"
    fi

    local total_hundredths=$(( existing_hundredths + new_hundredths ))
    local new_hours existing_hours total_hours
    new_hours="$(hundredths_to_hours "${new_hundredths}")"
    existing_hours="$(hundredths_to_hours "${existing_hundredths}")"
    total_hours="$(hundredths_to_hours "${total_hundredths}")"

    if [[ "${dry_run}" == true ]]; then
        echo "  #${work_item_id}: would commit ${new_hours}h (existing ${existing_hours}h → total ${total_hours}h)"
        echo "${new_hundredths}" >&3
        return 0
    fi

    printf '%s %s\n' "${rev:-0}" "${total_hundredths}" > "${pending_file}"

    local rc=0
    azdo_update_time_spent "${work_item_id}" "${total_hours}" "${time_field}" "${rev}" > /dev/null || rc=$?
    if [[ "${rc}" -eq 0 ]]; then
        session_mark_committed "${work_item_id}"
        rm -f "${pending_file}"
        echo "  #${work_item_id}: committed ${new_hours}h (total: ${total_hours}h)"
        return 0
    fi

    if [[ "${rc}" -eq "${AZDO_RC_UNKNOWN}" ]]; then
        echo "  #${work_item_id}: outcome unknown; run 'twk commit' again to check and finish" >&2
    else
        rm -f "${pending_file}"
        echo "  #${work_item_id}: failed to update Azure DevOps (nothing was written)" >&2
    fi
    return 1
}

cmd_commit() {
    config_require

    local dry_run=false
    local arg
    for arg in "$@"; do
        case "${arg}" in
            --dry-run) dry_run=true ;;
            *)
                echo "Error: unknown argument '${arg}' for commit." >&2
                echo "Usage: twk commit [--dry-run]" >&2
                return 1
                ;;
        esac
    done

    local session_files
    session_files="$(session_list_uncommitted)"

    if [[ -z "${session_files}" ]]; then
        echo "No uncommitted time entries to commit."
        return
    fi

    if [[ "${dry_run}" == true ]]; then
        echo "DRY RUN — no changes will be sent to Azure DevOps."
    else
        echo "Committing time entries to Azure DevOps..."
    fi
    echo ""

    local success_count=0
    local failure_count=0
    local would_hundredths_total=0
    local tracked_file
    tracked_file="$(mktemp)"

    local session_file work_item_id rc
    while read -r session_file; do
        work_item_id="$(session_work_item_id_from_path "${session_file}")"
        rc=0
        session_locked commit_one_locked "${work_item_id}" "${dry_run}" 3>> "${tracked_file}" || rc=$?
        if [[ "${rc}" -eq 0 ]]; then
            success_count=$(( success_count + 1 ))
        else
            failure_count=$(( failure_count + 1 ))
        fi
    done <<< "${session_files}"

    local hundredths
    while read -r hundredths; do
        [[ -n "${hundredths}" ]] && would_hundredths_total=$(( would_hundredths_total + hundredths ))
    done < "${tracked_file}"
    rm -f "${tracked_file}"

    echo ""
    if [[ "${dry_run}" == true ]]; then
        echo "Would commit $(hundredths_to_hours "${would_hundredths_total}")h across ${success_count} session$( (( success_count != 1 )) && echo s ), skipping ${failure_count}."
        echo "(no changes were sent to Azure DevOps; sessions remain uncommitted)"
    else
        echo "Done: ${success_count} committed, ${failure_count} failed/skipped."
    fi
}
