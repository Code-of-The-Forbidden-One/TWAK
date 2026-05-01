show_subcommand_help() {
    local subcommand="$1"

    case "${subcommand}" in
        init)
            cat <<'HELP'
twk init - Configure Azure DevOps connection

Usage:
    twk init [--global]

Options:
    --global    Write the configuration to ~/.config/twk/config
                instead of a project-local .twk/config

Prompts for your organisation, project, team, personal access token,
and the Azure DevOps field names used for time tracking.

By default, writes a project-local config to .twk/config in the
current directory. When twk runs, it walks up from the current
directory looking for .twk/config; if none is found, it falls back
to the global config at ~/.config/twk/config.

If the project-local config is created inside a git repository,
twk will append '.twk/' to .gitignore (creating the file if needed)
to keep your Personal Access Token out of version control.

Both files are stored with restrictive permissions (600 file, 700
directory). Re-run to update your configuration at any time.
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

When omitted, the interactive picker lists current sprint items
with running sessions hidden (you can't start something already
running). Items with a paused session show 'paused HH:MM:SS' to
the right of their title so you can see how much time is already
on them before resuming. The picker also shows the AzDO assignee
(displayName) per item so you can tell at a glance who owns
what. Long titles are truncated to 40 chars and assignee names
to 15 chars, both with '...'.

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

When omitted, the interactive picker only lists currently running
sessions (not the full sprint). If exactly one is running, it is
selected automatically.

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

When omitted, the interactive picker only lists running or paused
sessions (not already-ended ones, and not the full sprint). If
exactly one is in a valid state, it is selected automatically.

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
        assign)
            cat <<'HELP'
twk assign - Assign a work item to a user in Azure DevOps

Usage:
    twk assign [task] [user] [--me] [--all]

Arguments:
    [task]   Work item ID, partial title, or omit for the
             current-sprint interactive picker
    [user]   Email, display name, or unique name as recognised
             by your Azure DevOps organisation. Omit for the
             interactive user picker

Options:
    --me     Assign yourself, derived from the PAT's identity
             via /_apis/connectionData. Cannot be combined with
             an explicit user or with --all.
    --all    Use the org-wide user picker (Graph API) instead of
             the default sprint-scoped one. Useful when assigning
             someone who isn't yet on a sprint item. Requires
             'Graph (Read)' scope on your PAT in addition to
             'Work Items (Read & Write)'.

PATCHes System.AssignedTo on the work item. Does not touch any
local session — assignment is purely an AzDO state change.

The user picker (default) only lists people already assigned to
a sprint item. Use --all to pick from the entire org. Use --me
to skip the picker and assign yourself.

Examples:
    twk assign                    Pick task, then pick user (sprint)
    twk assign 12345              Task is set, pick user (sprint)
    twk assign 12345 --me         Assign yourself
    twk assign 12345 --all        Pick user from org-wide list
    twk assign 12345 luke@...     Both set, no pickers
    twk assign --me               Pick task, assign yourself
HELP
            ;;
        undo)
            cat <<'HELP'
twk undo - Undo the last event on a session

Usage:
    twk undo [task] [--state <state>]

Arguments:
    [task]            Work item ID, partial title, or omit for interactive picker
    --state <state>   Set the work item state in Azure DevOps

Removes the most recent event (start, resume, pause, or end) from
the session file. Use this to recover from a typo such as hitting
'end' when you meant 'pause'. If the only event is removed, the
session file is deleted.

When omitted, the interactive picker only lists existing sessions
(not the full sprint). If exactly one session exists, it is
selected automatically.

Examples:
    twk undo 12345                      Undo the last event
    twk undo 12345 --state Doing        Undo and reset AzDO state
HELP
            ;;
        cancel)
            cat <<'HELP'
twk cancel - Discard an uncommitted session

Usage:
    twk cancel [task] [--state <state>]

Arguments:
    [task]            Work item ID, partial title, or omit for interactive picker
    --state <state>   Set the work item state in Azure DevOps

Discards the local session for a work item without committing
anything to Azure DevOps. The session file is moved to
~/.local/share/twk/sessions/cancelled/ for audit rather than
deleted outright. Use this when you started tracking the wrong
work item, or left a timer running by mistake.

When omitted, the interactive picker only lists existing sessions
(not the full sprint). If exactly one session exists, it is
selected automatically.

Examples:
    twk cancel 12345                    Discard session, keep AzDO state
    twk cancel 12345 --state "To Do"    Discard and revert AzDO state
HELP
            ;;
        list)
            cat <<'HELP'
twk list - List current sprint items with metadata

Usage:
    twk list [-i|--interactive]

Options:
    -i, --interactive   Open the list in fzf with a preview pane
                        showing the full description and metadata
                        for whichever row is highlighted. On enter,
                        the selected work item ID is printed to
                        stdout (so you can pipe it: e.g.
                        'twk start "$(twk list -i)"'). Esc/Ctrl-C
                        exits without selecting. Requires fzf on
                        PATH.

Prints every work item in the current sprint as a single-row
table summary plus a description sub-line indented underneath:

    ID       Title                            State      Pri  Est      Done     Assigned
    ───────────────────────────────────────────────────────────────────────────────────────
      #12345  Implement login button           Active     2    8h       2.5h     Luke McCann
              OAuth2 with PKCE flow. Needs to handle redirects from the
              legacy callback URLs.
      #12346  Refactor auth middleware         Doing      1    4h       -        Sarah Khan
              Split into auth-core and auth-azdo packages.

The summary row mirrors 'twk status' for consistency. Titles
are truncated to 32 chars with '...' if longer; assignee names
are truncated to 15 chars; descriptions are HTML-stripped,
whitespace-collapsed, and truncated to 240 chars with '...'.
Missing values render as '-'. The "Done" value comes from the
AzDO time field configured in 'twk init' (Task vs Feature is
resolved per item). The "Assigned" column is read from
System.AssignedTo.displayName.

Long output is automatically piped through 'less -FRX' when
stdout is a TTY (set TWK_NO_PAGER=1 to opt out, or PAGER='' to
force cat). Short output skips the pager because of less's -F
flag. Falls back to cat if less isn't installed.
HELP
            ;;
        show)
            cat <<'HELP'
twk show - Show one work item's full metadata and description

Usage:
    twk show [task] [--discussion]

Arguments:
    [task]         Work item ID, partial title, or omit for the
                   current-sprint interactive picker

Options:
    --discussion   After the metadata block, append the AzDO
                   Discussion thread (System.History comments)
                   in chronological order. One block per
                   comment showing [timestamp] author and the
                   HTML-stripped body wrapped to 76 chars.

Fetches the work item from Azure DevOps and prints a single
labelled block with type, state, priority, assignee, estimate,
time taken, iteration path, and the full description (HTML-
stripped, whitespace-collapsed, line-wrapped to 78 chars - no
truncation).

Use this when 'twk list' truncates the description and you
need to read the whole thing without leaving the terminal.
Use --discussion when context lives in the comment thread —
no need to leave the terminal for the AzDO web UI.

Output is piped through 'less -FRX' when stdout is a TTY (set
TWK_NO_PAGER=1 to opt out, or PAGER='' to disable; respects an
explicit $PAGER). Falls back to cat if less isn't installed.

Examples:
    twk show 12345                  Look up by ID
    twk show 12345 --discussion     Include the comment thread
    twk show "login bug"            Title-search the current sprint
    twk show                        Pick interactively
HELP
            ;;
        users)
            cat <<'HELP'
twk users - List users from the sprint or the entire org

Usage:
    twk users [--all]

Options:
    --all    Pull the user list from the AzDO Graph API instead
             of aggregating from sprint items. Requires the PAT
             to have 'Graph (Read)' scope on top of 'Work Items
             (Read & Write)'. Returns every user in the org, not
             just those assigned to current sprint items.

Default (sprint-scoped) aggregates System.AssignedTo across
every work item in the current sprint and prints unique users
as a three-column table: ID (AzDO user UUID), Username
(displayName), and Email (uniqueName / UPN).

With --all, the same table is populated from the org Graph API.
Group entries are filtered out — only individual users appear.
The ID column shows the user's descriptor (a longer opaque ID)
rather than the UUID, since that's what the Graph API returns.

Useful for finding the right identifier to pass to
'twk assign <task> <user>'. Email tends to be the most reliable
identifier; AzDO accepts any of the three columns when assigning.

Output is piped through 'less -FRX' when stdout is a TTY (set
TWK_NO_PAGER=1 to opt out, or PAGER='' to disable). Falls back
to cat if less isn't installed.
HELP
            ;;
        pull)
            cat <<'HELP'
twk pull - Refresh cached metadata for every active session

Usage:
    twk pull

For every uncommitted session, fetches the latest title and type
from Azure DevOps and writes a fresh .meta sidecar file. Useful
after starting a session offline (which leaves the title as
"(no title cached)") or when a work item has been renamed and you
want 'twk status' to reflect the new title without restarting the
session.

Per-session status is printed:

    Refreshing metadata for 3 sessions...

      #48210: refreshed ("Implement login button")
      #48215: refreshed ("Refactor auth middleware")
      #48220: failed (work item not found or unreachable)

    Done: 2 refreshed, 1 failed.

Best-effort: a single session failing does not abort the others.
The work item must exist in Azure DevOps for the refresh to
succeed; deleted or out-of-scope items are reported as failed.
HELP
            ;;
        status)
            cat <<'HELP'
twk status - View active config and uncommitted time entries

Usage:
    twk status [--with-existing]

Options:
    --with-existing   Fetch the current AzDO time field for each
                      session (one batched API call) and add two
                      columns: '+ AzDO' (current value in the work
                      item) and '= Total' (what would land on commit).

Prints the active config path and its scope (local or global),
followed by every tracked session that hasn't been committed to
Azure DevOps. For each session, shows the work item ID, cached
title (truncated to 40 chars), current state (running, paused,
or ended), elapsed time, and decimal hours.

Titles are cached on first 'twk start <id>' to a sidecar .meta
file, so 'status' itself never hits the network by default.
Sessions without a cached title display '(no title cached)' -
resume once with 'twk start' while online to backfill.

With --with-existing, status hits AzDO once via the work-items
batch endpoint to read the current time field on every uncommitted
work item, then renders two extra columns showing the projected
post-commit value. Cells display '?' if the lookup fails (network
down, work item deleted, etc.); the command does not fail.

The table portion is piped through 'less -FRX' when stdout is a
TTY (set TWK_NO_PAGER=1 to opt out, or PAGER='' to disable;
respects an explicit $PAGER). Falls back to cat if less isn't
installed. The 'Config:' line above the table prints unpaged.
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

contains_help_flag() {
    local arg
    for arg in "$@"; do
        case "${arg}" in
            --help|-h) return 0 ;;
        esac
    done
    return 1
}
