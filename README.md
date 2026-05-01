<p align="center">
  <img src="images/twk_banner.png" alt="TWAK Banner" width="100%" />
</p>

<h1 align="center">TWAK - Timed Worked and Committed</h1>

<p align="center">
  A lightweight CLI for tracking time against Azure DevOps work items, directly from the terminal.
  <br />
  Start, pause, and end timing sessions locally, then commit hours back to your board in one push.
</p>

---

## Installation

### Prerequisites

| Dependency | Purpose                    | Required |
|------------|----------------------------|----------|
| `curl`     | Azure DevOps API requests  | ✅        |
| `jq`       | JSON parsing               | ✅        |
| `bc`       | Decimal hour calculations  | ✅        |
| `fzf`      | Interactive work item picker | ❌ Optional |

All required dependencies are standard on most Linux distributions. If `fzf` is not installed, `twk` falls back to a numbered list for interactive selection.

### Quick Install (one-liner)

```bash
curl -fsSL https://raw.githubusercontent.com/Code-of-The-Forbidden-One/TWAK/main/install-remote.sh | bash
```

This clones the repo to `~/.local/share/twk` and symlinks the binary to `~/.local/bin/twk`. Run the same command again to update.

### Manual Install

```bash
git clone git@github.com:Code-of-The-Forbidden-One/TWAK.git
cd TWAK
./install.sh
```

If `~/.local/bin` is not in your `PATH`, add it to your shell profile:

```bash
export PATH="${HOME}/.local/bin:${PATH}"
```

---

## Quick Start

```bash
# Configure your Azure DevOps connection
twk init

# Start tracking a work item by ID
twk start 12345

# Or by partial title match
twk start "auth refactor"

# Pause when you step away
twk pause 12345

# Resume when you're back
twk start 12345

# End when the work is done
twk end 12345

# Review what you've tracked
twk status

# Push it all to Azure DevOps
twk commit
```

---

## Commands

### `twk init [--global]`

Configures your Azure DevOps connection.

By default, `twk init` writes a **project-local** config to `.twk/config` in the current directory. Pass `--global` to write the global config at `~/.config/twk/config` instead.

When `twk` runs, it walks up from the current working directory looking for `.twk/config` and uses the first one it finds. If none is found, it falls back to the global config. This lets you keep different Azure DevOps connections per project (e.g. different orgs, different time fields) and a default for everything else.

If the local config is created inside a git repository, `twk` appends `.twk/` to `.gitignore` (creating the file if needed) so your Personal Access Token doesn't get committed. A reminder is printed either way - review the change before pushing.

You will be prompted for:

- **Organisation** - your Azure DevOps org name (e.g. `myorg`)
- **Project** - the project containing your boards (e.g. `MyProject`)
- **Team** - your team name, or leave blank for the default team
- **Personal Access Token** - a PAT with **Work Items (Read & Write)** scope
- **Time field for Tasks** - the AzDO field name to write time to for tasks (e.g. `Custom.TimeSpent`, `Microsoft.VSTS.Scheduling.CompletedWork`)
- **Time field for Features** - the AzDO field name for features, or leave blank if the same as tasks
- **State for start** - the AzDO state name to use with `--state` on start (default: `Active`)
- **State for pause** - the AzDO state name to use with `--state` on pause (default: `Paused`)
- **State for end --done** - the AzDO state name to use with `--done` (default: `Done`)

Configuration is stored at `.twk/config` (local) or `~/.config/twk/config` (global) with restrictive file permissions (`600`) and directory permissions (`700`).

**Project-local init (default):**

```
$ cd ~/Projects/Platform
$ twk init
  _________      __   _____   ____  __.
 /\__  ___/\    /  \ /  _  \ |    |/ _|
 \/_/  \   \/\/  /  /  /_\  \|      <
    |   |  \    /  /    |    \    |  \
    |___|   \/\/   \____|__  /____|__ \
                           \/        \/
     Time Worked and Committed

  Azure DevOps Configuration (local: /home/user/Projects/Platform)

Organisation (e.g. myorg): contoso
Project (e.g. MyProject): Platform
Team (e.g. MyTeam, or leave blank for default): Backend
Personal Access Token: ****

Time tracking fields
These are the Azure DevOps field names that twk writes time to.
Common values: Microsoft.VSTS.Scheduling.CompletedWork, Custom.TimeSpent

Time field for Tasks (e.g. Custom.TimeSpent): Custom.TimeSpent
Time field for Features (leave blank if same as Tasks):

Work item states
These map twk actions to your board's column/state names.
Leave blank to skip state updates for that action.

State for start (default: Active): Doing
State for pause (default: Paused):
State for end --done (default: Done):

Configuration saved to /home/user/Projects/Platform/.twk/config

Added '.twk/' to /home/user/Projects/Platform/.gitignore to keep your PAT out of git.
Reminder: review and commit the .gitignore change before pushing.

Testing connection...
Connected successfully.
```

**Global init (`--global`):**

```
$ twk init --global
  ...banner...

  Azure DevOps Configuration (global)

  ...prompts...

Configuration saved to /home/user/.config/twk/config
Testing connection...
Connected successfully.
```

---

### `twk start [task] [--state <state>]`

Starts a timing session on a work item. Supports three resolution modes:

| Usage                         | Behaviour                                                        |
|-------------------------------|------------------------------------------------------------------|
| `twk start 12345`            | Direct work item ID - no API lookup required                     |
| `twk start "login bug"`      | Case-insensitive title search against the current sprint         |
| `twk start`                  | Interactive picker (`fzf` if available, numbered list otherwise) |

If a title search returns multiple matches, you will be prompted to choose.

If the work item is currently paused, `twk start` resumes it automatically.

Use `--state` to update the work item state in Azure DevOps (e.g. `--state Doing`).

```
$ twk start "auth refactor" --state Doing
Started tracking #48210
  State set to Doing

$ twk start 48210
Error: work item #48210 is already running.
```

---

### `twk pause [task] [--state <state>]`

Pauses an active timing session. The elapsed time so far is preserved - you can resume with `twk start` at any point.

Use `--state` to update the work item state in Azure DevOps (e.g. `--state Paused`).

The same task resolution modes apply (ID, title match, or interactive). When you omit the task, the interactive picker only lists currently **running** sessions rather than the full sprint - so you don't have to guess which work item still has a live timer. If only one session is running, it's selected automatically.

```
$ twk pause 48210 --state Paused
Paused #48210 (01:34:12 tracked)
  State set to Paused
```

---

### `twk end [task] [--state <state>]`

Ends a timing session on a work item. The session is finalised and ready to commit.

You can end a work item that is either running or paused. By default, ending a session does not change the work item state. Use `--state` to set the state explicitly.

When the task is omitted, the interactive picker only lists **running or paused** sessions. Already-ended sessions and the rest of the sprint are excluded. A single match auto-selects.

```
$ twk end 48210
Ended #48210 (03:22:45 total)

$ twk end 48215 --state Done
Ended #48215 (01:15:30 total)
  State set to Done

$ twk end 48220 --state "Code Review"
Ended #48220 (00:45:00 total)
  State set to Code Review
```

---

### `twk done [task] [--state <state>]`

Sets the work item state in Azure DevOps without affecting any active timer session. Uses the configured "done" state by default, or a specific state via `--state`.

```
$ twk done 48210
  State set to Done

$ twk done 48215 --state "Code Review"
  State set to Code Review
```

---

### `twk undo [task] [--state <state>]`

Removes the most recent event (`start`, `resume`, `pause`, or `end`) from a session file. Use this when you make a typo - for example, ending a session when you meant to pause it.

If undoing the last remaining event leaves the session empty, the session file is removed.

The same task resolution modes apply (ID, title match, or interactive). When the task is omitted, the interactive picker only lists existing sessions (any state) rather than the full sprint. A single match auto-selects. Use `--state` to also update the work item state in Azure DevOps.

```
$ twk end 48210
Ended #48210 (03:22:45 total)

$ twk undo 48210
Undid 'end' on #48210 (now running)

$ twk pause 48210
Paused #48210 (03:25:10 tracked)

$ twk undo 48210 --state Doing
Undid 'pause' on #48210 (now running)
  State set to Doing
```

---

### `twk cancel [task] [--state <state>]`

Discards an uncommitted local session. Use this when you started tracking the wrong work item, or left a timer running by mistake.

The session file is archived to `~/.local/share/twk/sessions/cancelled/` for audit - it is not silently deleted. Nothing is pushed to Azure DevOps.

When the task is omitted, the interactive picker only lists existing sessions (any state) rather than the full sprint. A single match auto-selects.

Use `--state` to also revert the work item state (e.g. back to `To Do`).

```
$ twk cancel 48210
Cancelled #48210 (02:15:00 discarded)

$ twk cancel 48215 --state "To Do"
Cancelled #48215 (00:45:30 discarded)
  State set to To Do
```

---

### `twk status`

Shows which config is active (and its scope) followed by all uncommitted time entries with their work item title, current state, and accumulated duration.

Titles are cached to a sidecar `.meta` file the first time you `twk start <id>`, so `status` itself stays offline. Titles are truncated to 40 characters with `...` if longer. Sessions started before this caching landed (or while you were offline) will show `(no title cached)`; resume them once with `twk start <id>` while online to backfill the title.

```
$ twk status
Config: /home/user/Projects/Platform/.twk/config (local scope)

Uncommitted time entries:
─────────────────────────────────────────────────────────────────────────────────
  ID       Title                                    State      Time         Hours
─────────────────────────────────────────────────────────────────────────────────
  #48210   Implement login button                   ended      03:22:45     3.38h
  #48215   Refactor authentication middleware to... running    00:45:30     .75h
  #48220   Fix flaky integration test on CI         paused     01:10:00     1.16h
─────────────────────────────────────────────────────────────────────────────────
  Total                                             05:18:15     5.30h
```

---

### `twk commit`

Pushes all uncommitted time entries to Azure DevOps by updating the configured time field on each work item.

- Time is **additive** - `twk` reads the existing value and adds your tracked hours to it
- The target field is determined by work item type (Task vs Feature) based on your `twk init` configuration
- Work items that are still running are **skipped** - end or pause them first
- Committed sessions are archived to `~/.local/share/twk/sessions/committed/` for audit

```
$ twk commit
Committing time entries to Azure DevOps...

  #48210: committed 3.38h (total: 7.38h)
  #48215: skipped (still running - end or pause first)
  #48220: committed 1.16h (total: 1.16h)

Done: 2 committed, 1 failed/skipped.
```

---

### `twk version`

Displays the current version.

```
$ twk version
twk 0.1.0
```

---

### `twk help`

Displays usage information.

```
$ twk help
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
    --state   (start, pause, end, done, undo, cancel) Set the AzDO work item state
```

Pass `--help` (or `-h`) to any subcommand for detailed help on that command (e.g. `twk start --help`).

---

## Windows (WSL)

`twk` runs natively on Windows through the Windows Subsystem for Linux. If you don't have WSL set up yet, open PowerShell as Administrator and run:

```powershell
wsl --install
```

Restart your machine when prompted, then launch Ubuntu from the Start menu. Once inside WSL, install the dependencies and `twk` as normal:

```bash
sudo apt update && sudo apt install -y curl jq bc
curl -fsSL https://raw.githubusercontent.com/Code-of-The-Forbidden-One/TWAK/main/install-remote.sh | bash
source ~/.bashrc
twk init
```

After setup, you can use `twk` from any WSL terminal. If you use Windows Terminal, pin your WSL profile for quick access.

### Tips for WSL users

- **VS Code integration** - Run `code .` from WSL and VS Code connects automatically via the Remote-WSL extension. You can use the integrated terminal to run `twk` alongside your development workflow.
- **Accessing from PowerShell** - You can call `twk` from PowerShell without opening a WSL window:
  ```powershell
  wsl twk status
  wsl twk start 12345
  ```
- **Optional: fzf for interactive picking** - `sudo apt install -y fzf` enables the fuzzy finder for `twk start` without arguments.

---

## Parallel Tracking

`twk` supports tracking multiple work items simultaneously. You can have several sessions active at once and switch between them freely.

```bash
twk start 48210       # Start on the API task
twk start 48215       # Also start on the frontend task
twk pause 48210       # Step away from the API work
twk end 48215         # Finish the frontend task
twk start 48210       # Resume the API work
twk status            # See everything at a glance
```

---

## Project Structure

```
TWAK/
├── bin/
│   └── twk              # Entry point and command router
├── lib/
│   ├── config.sh        # Local/global config resolution and init command
│   ├── azdo.sh          # Azure DevOps REST API integration
│   ├── resolve.sh       # Work item resolution (ID, title, interactive)
│   ├── session.sh       # Session events, start/pause/end/undo/cancel commands
│   ├── display.sh       # Formatting, status output, and commit command
│   ├── help.sh          # Per-subcommand --help text
│   └── banner.sh        # ASCII banner
├── man/
│   └── twk.1            # Man page
├── images/              # README assets
├── install.sh           # Local installer (symlinks bin/twk to ~/.local/bin)
├── install-remote.sh    # Curl-pipe-bash installer used by the one-liner
├── LICENSE
└── README.md
```

---

## Data Storage

| Path                                         | Purpose                                              | Permissions |
|----------------------------------------------|------------------------------------------------------|-------------|
| `<project>/.twk/config`                      | Project-local AzDO connection settings (preferred)   | `600`       |
| `<project>/.twk/` (directory)                | Project-local config directory                       | `700`       |
| `~/.config/twk/config`                       | Global AzDO connection settings (fallback)           | `600`       |
| `~/.config/twk/` (directory)                 | Global config directory                              | `700`       |
| `~/.local/share/twk/sessions/<id>.session`   | Active time tracking sessions                        | Default     |
| `~/.local/share/twk/sessions/<id>.meta`      | Cached work item title and type (JSON)               | Default     |
| `~/.local/share/twk/sessions/committed/`     | Archived committed sessions (with their `.meta`)     | Default     |
| `~/.local/share/twk/sessions/cancelled/`     | Archived cancelled sessions (with their `.meta`)     | Default     |

Local configs are discovered by walking up from the current working directory. The first `.twk/config` found is used; otherwise twk falls back to the global config.

### Session File Format

Sessions are stored as append-only flat files with one event per line:

```
start|1714560000
pause|1714563600
resume|1714567200
end|1714574400
```

Each line is an `event|unix_timestamp` pair. This format is human-readable, easy to debug, and easy to parse.

---

## Security

- Your Personal Access Token is stored locally in either the project-local `.twk/config` or the global `~/.config/twk/config`, both with `600` permissions (owner read/write only)
- Both config directories are set to `700` (owner access only)
- When you run `twk init` (project-local) inside a git repository, `twk` automatically appends `.twk/` to `.gitignore` to prevent the PAT from being committed - review the change before pushing
- The PAT is transmitted over HTTPS via Basic authentication to the Azure DevOps REST API
- No credentials are logged, cached, or transmitted to any third-party service

---

## Azure DevOps PAT Permissions

When creating your Personal Access Token, the minimum required scope is:

| Scope                    | Access     | Purpose                                    |
|--------------------------|------------|--------------------------------------------|
| **Work Items**           | Read & Write | Fetch sprint items, update Completed Work |

Generate a PAT at: `https://dev.azure.com/{your-org}/_usersettings/tokens`

---

## Azure DevOps Fields

`twk` reads and writes the following work item fields:

| Field                                          | Usage                              |
|------------------------------------------------|------------------------------------|
| `System.Id`                                    | Work item identification           |
| `System.Title`                                 | Title matching and display         |
| `System.WorkItemType`                          | Display in interactive picker      |
| `System.State`                                 | Display in interactive picker      |
| `System.State`                                 | Updated on start (Active), pause (Paused), end --done (Done) |
| Configured time field (e.g. `Custom.TimeSpent`) | Read on commit, updated with tracked hours |
| `Microsoft.VSTS.Scheduling.RemainingWork`      | Fetched for reference              |
| `Microsoft.VSTS.Scheduling.StartDate`          | Fetched for reference              |
| `Microsoft.VSTS.Scheduling.TargetDate`         | Fetched for reference              |

---

## Troubleshooting

**"twk not initialised. Run 'twk init' first."**
No `.twk/config` was found in the current directory or any parent, and no global config exists at `~/.config/twk/config`. Run `twk init` to create a project-local config, or `twk init --global` to create a global one.

**"connection test failed"**
Check that your organisation, project, and PAT are correct. Ensure the PAT has not expired and has the required Work Items scope.

**"no current iteration found"**
Your team must have an active sprint/iteration configured in Azure DevOps with the current date falling within its date range.

**"no work items in current sprint"**
The current sprint has no work items assigned. Check your board in Azure DevOps.

**Work item still running on commit**
`twk commit` skips sessions that are still active. Run `twk pause` or `twk end` on the work item first, then commit.
