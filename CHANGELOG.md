# Changelog

## 0.2.0

A security and correctness release. Upgrade before sharing twk with anyone.

### Upgrading

- **Trust your local configs once.** twk now uses a project-local `.twk/config` only if `twk init` wrote it or you have approved it. In each project with an existing `.twk/config`, review the file and run `twk trust`. Global configs need nothing.
- **Sessions move per organisation and project.** The first command you run moves your uncommitted sessions and history from `~/.local/share/twk/sessions/` into `~/.local/share/twk/scopes/<organisation>/<project>/` for the config in use, and says so. If you track time in more than one organisation, check `twk status` afterwards and `twk cancel` anything that belongs elsewhere.
- **`bc` is no longer needed.**
- **Board states are opt-in.** To have `twk start` and `twk pause` move work items on your board, re-run `twk init` (or add `TWK_STATE_ON_START=<state>` and `TWK_STATE_ON_PAUSE=<state>` to your config).

### Security

- A config file is read as data and never executed. Before, it was `source`d, so a `.twk/config` in any parent directory, such as one committed to a cloned repository, ran as you.
- twk refuses a config file you do not own or that other users can write to, and uses a project-local config only once it is trusted (`twk init` or `twk trust`), and only while its contents are unchanged.
- The PAT is handed to `curl` on standard input, so other users on the machine can no longer read it from the process list.
- New: sign in with the Azure CLI (`TWK_AUTH=azcli`) instead of a PAT. Nothing secret is stored, and your organisation's sign-in policy applies. `twk init` offers it by default when `az` is installed.
- Control characters are stripped from everything Azure DevOps returns, so text written by others cannot drive your terminal.
- Every request body is built by `jq`; a `--state` value containing quotes can no longer break or alter the request.

### Correctness

- `twk commit` only pushes the sessions of the organisation and project in use. Before, time tracked in one organisation could be written to the work item with the same ID in another.
- `twk commit` writes nothing for a work item whose current hours it could not read. Before, a failed read counted as zero and the commit overwrote the hours already there.
- `twk commit` and `twk reset` send the revision they read, so a change someone else makes in between is refused instead of overwritten.
- If a commit's outcome is unknown (network failure or server error), the next `twk commit` checks whether it landed before adding anything, so hours are not counted twice.
- Hours are rounded to the nearest 0.01h instead of truncated, and always written with a leading zero (`0.50`, not `.50`, which is not valid JSON).
- Sprints with more than 200 work items no longer fail: batch requests are split.
- Throttling (429) is retried for every request, and server errors and network failures for reads.
- Failed requests show the HTTP status and Azure DevOps's own message instead of a bare "failed".
- Commands that change sessions take a lock, so two terminals cannot corrupt a session file.
- Removed GNU-only commands (`base64 -w`, `grep -P`, `date -d`, `readlink -f`), a step towards macOS support.

### New

- **Move work items on the board as you work.** `twk init` asks, optionally, for a state to move a work item to when you start it and when you pause it (`TWK_STATE_ON_START`, `TWK_STATE_ON_PAUSE`). `--state <state>` overrides it once and `--no-state` skips it. Configs from 0.1.x are unaffected: their `TWK_STATE_ACTIVE`/`TWK_STATE_PAUSED` values were never used and still aren't; re-run `twk init` to choose states.
- `twk end --done` ends the session and marks the work item done in one step.
- `twk add [task] <duration>` adds time you forgot to track.
- `twk doctor` shows the config in use, whether it is trusted, its settings, where sessions are kept, and whether Azure DevOps can be reached.
- `twk trust` approves a project-local config after you have reviewed it.

### Fixed

- The one-line installer pointed at a `main` branch that does not exist; it now uses `master`.
- The PowerShell wrapper in the README did not work: `wsl twk` could not find `twk` (its shell never reads `~/.bashrc`) and split quoted arguments. It now calls twk by its full path with `wsl.exe --exec`, so `twk start "auth refactor"` arrives as one argument.
