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
    twk init [--global]         Configure Azure DevOps connection
    twk start [task]            Start timing a work item
    twk pause [task]            Pause timing a work item
    twk end [task]              Stop timing a work item
    twk done [task]             Mark a work item as done
    twk undo [task]             Undo the last event on a session
    twk cancel [task]           Discard an uncommitted session
    twk status                  View uncommitted time entries
    twk commit                  Push time entries to Azure DevOps
    twk version                 Show version

Arguments:
    [task]    Work item ID, partial title, or omit for interactive picker

Options:
    --global  (init only) Write to the global config rather than a project-local one
    --state   Set the AzDO work item state. Applies to start, pause, end, undo, and
              cancel (which all touch sessions). On 'done' (state-only, no session),
              this overrides the configured done-state.
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
        undo)    cmd_undo "$@" ;;
        cancel)  cmd_cancel "$@" ;;
        status)  cmd_status "$@" ;;
        commit)  cmd_commit "$@" ;;
        version) echo "twk ${TWK_VERSION}" ;;
        help|-h|--help) print_usage ;;
        "")      print_usage; exit 1 ;;
        *)       echo "Error: unknown command '${command}'" >&2; print_usage >&2; exit 1 ;;
    esac
}
