show_subcommand_help() {
    local subcommand="$1"

    case "${subcommand}" in
        init)
            cat <<'HELP'
twk init - Configure Azure DevOps connection

Usage:
    twk init

Prompts for your organisation, project, team, personal access token,
and the Azure DevOps field names used for time tracking. Stores
credentials at ~/.config/twk/config with restrictive permissions
(600). Tests the connection after saving.

Re-run to update your configuration at any time.
HELP
            ;;
        start)
            cat <<'HELP'
twk start - Start timing a work item

Usage:
    twk start [task] [--state <state>]

Arguments:
    [task]            Work item ID, partial title, or omit for interactive picker
    --state <state>   Set the work item state in Azure DevOps

Starts a new timing session. If the work item is currently paused,
resumes it instead. Multiple work items can be tracked in parallel.

Examples:
    twk start 12345                     Start by work item ID
    twk start "login bug"               Start by partial title match
    twk start                           Pick from current sprint interactively
    twk start 12345 --state Doing       Start and set state to Doing
HELP
            ;;
        pause)
            cat <<'HELP'
twk pause - Pause timing a work item

Usage:
    twk pause [task] [--state <state>]

Arguments:
    [task]            Work item ID, partial title, or omit for interactive picker
    --state <state>   Set the work item state in Azure DevOps

Pauses an active session. Elapsed time is preserved and can be
resumed with 'twk start'. Only works on currently running items.

Examples:
    twk pause 12345
    twk pause "login bug"
    twk pause 12345 --state Paused
HELP
            ;;
        end)
            cat <<'HELP'
twk end - Stop timing a work item

Usage:
    twk end [task] [--state <state>]

Arguments:
    [task]            Work item ID, partial title, or omit for interactive picker
    --state <state>   Set the work item state in Azure DevOps

Ends a session. The work item can be running or paused. Once ended,
the session is ready to commit to Azure DevOps.

By default, ending a session does not change the work item state.

Examples:
    twk end 12345                       End without changing state
    twk end 12345 --state Done          End and mark as Done
    twk end 12345 --state "Code Review" End and set custom state
HELP
            ;;
        done)
            cat <<'HELP'
twk done - Mark a work item as done

Usage:
    twk done [task] [--state <state>]

Arguments:
    [task]            Work item ID, partial title, or omit for interactive picker
    --state <state>   Override the configured done state with a specific value

Sets the work item state in Azure DevOps without affecting any
active timer session. Uses the configured "done" state by default.

Examples:
    twk done 12345                      Mark as done (configured state)
    twk done "login bug"
    twk done 12345 --state "Code Review"
HELP
            ;;
        status)
            cat <<'HELP'
twk status - View uncommitted time entries

Usage:
    twk status

Displays all tracked sessions that have not been committed to Azure
DevOps. Shows the work item ID, current state (running, paused, or
ended), elapsed time, and decimal hours.
HELP
            ;;
        commit)
            cat <<'HELP'
twk commit - Push time entries to Azure DevOps

Usage:
    twk commit

Pushes accumulated time to the configured time field on each tracked
work item. The target field depends on the work item type (Task vs
Feature) as set during 'twk init'. Time is additive - it reads the
existing value and adds your hours to it. Running sessions are
skipped; end or pause them first. Committed sessions are archived
for audit.
HELP
            ;;
        *)
            echo "No help available for '${subcommand}'." >&2
            return 1
            ;;
    esac
}

is_help_flag() {
    local arg="${1:-}"
    [[ "${arg}" == "--help" ]] || [[ "${arg}" == "-h" ]]
}
