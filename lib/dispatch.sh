# lib/dispatch.sh — top-level dispatcher for bin/twk.
#
# Extracted so the dispatcher tests in tests/twk_dispatch.bats can source
# this file directly and exercise the real main()/print_usage() rather
# than maintain a copy. bin/twk sources this last and then calls
# `main "$@"`.
#
# Depends (transitively, via the libs bin/twk sources before this one):
#   - print_banner            (lib/banner.sh)
#   - contains_help_flag      (lib/help.sh)
#   - show_subcommand_help    (lib/help.sh)
#   - cmd_*                   (lib/config.sh, lib/session.sh, lib/display.sh)
#   - TWK_VERSION             (set in bin/twk before this file is sourced)

print_usage() {
    print_banner
    echo ""
    cat <<'USAGE'
Usage:
  Setup
    twk init             Configure Azure DevOps connection

  Time tracking (commit cycle — local until 'twk commit'):
    twk start            Start timing a work item
    twk pause            Pause timing a work item
    twk end              Stop timing a work item
    twk undo             Undo the last event on a session
    twk cancel           Discard an uncommitted session
    twk adjust           Manually adjust recorded time on a session
    twk status           View uncommitted time entries
    twk commit           Push accumulated hours to Azure DevOps

  Direct AzDO actions (immediate — write to AzDO right away):
    twk done             Mark a work item as done (state-only)
    twk assign           Assign a work item to a user
    twk comment          Post a comment to a work item's Discussion
    twk reset            Zero out the configured time field on AzDO

  Read-only:
    twk list             List current sprint items with metadata
    twk show             Show one work item's full metadata + description
    twk users            List sprint or org-wide users
    twk log              Browse history of committed time entries
    twk pull             Refresh cached title/type for all sessions

  Misc
    twk version          Show version (also: twk -v, twk --version)

Arguments:
    [task]               Work item ID, partial title, or omit for interactive picker
                         (start, pause, end, done, undo, cancel, show)

Options:
    --global             (init only) Write to the global config rather than project-local
    --state <state>      (start, pause, end, done, undo, cancel) Set AzDO work item state
    --with-existing      (status only) Show post-commit projection (existing AzDO + tracked)
    -i, --interactive    (list only) Open in fzf with preview pane; prints selected ID
    --sort=<col>         (list only) Sort by column (id, title, state, pri, est, done,
                         assigned). Prefix with '-' for descending: --sort=-done.
    --me                 (assign only) Assign yourself based on the PAT's identity
    --all                (assign, users) Use org-wide user list (Graph API; needs PAT scope)
                         (log) Show all committed history rather than just the last N days
    --discussion         (show only) Append the AzDO Discussion thread (comments)
    --dry-run            (commit only) Preview what would be pushed without writing
    -y, --yes            (reset only) Skip the destructive-action confirmation prompt
    --days=<n>           (log only) Limit history to the last N days (default 7)
    --by-id              (log only) Group history by work item ID instead of date

Note: --state X on any time-tracking command also fires an immediate PATCH to AzDO.

Pass --help (or -h) to any subcommand for full per-command help.

Environment:
    TWK_NO_PAGER         Disable the auto-pager for list / show / status.
    PAGER                Pager to use for long output (default: less -FRX,
                         or cat if less is missing). Empty disables paging.
USAGE
}

main() {
    local command="${1:-}"
    shift || true

    if contains_help_flag "$@"; then
        show_subcommand_help "${command}"
        return
    fi

    case "${command}" in
        init)    cmd_init "$@" ;;
        start)   cmd_start "$@" ;;
        pause)   cmd_pause "$@" ;;
        end)     cmd_end "$@" ;;
        done)    cmd_done "$@" ;;
        assign)  cmd_assign "$@" ;;
        comment) cmd_comment "$@" ;;
        reset)   cmd_reset "$@" ;;
        undo)    cmd_undo "$@" ;;
        cancel)  cmd_cancel "$@" ;;
        adjust)  cmd_adjust "$@" ;;
        list)    cmd_list "$@" ;;
        show)    cmd_show "$@" ;;
        users)   cmd_users "$@" ;;
        log)     cmd_log "$@" ;;
        pull)    cmd_pull "$@" ;;
        status)  cmd_status "$@" ;;
        commit)  cmd_commit "$@" ;;
        version|-v|--version) echo "twk ${TWK_VERSION}" ;;
        help|-h|--help) print_usage ;;
        "")      print_usage; exit 1 ;;
        *)       echo "Error: unknown command '${command}'" >&2; print_usage >&2; exit 1 ;;
    esac
}
