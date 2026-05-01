<p align="center">
  <img src="images/twk_banner.png" alt="TWAK Banner" width="100%" />
</p>

<h1 align="center">TWAK - Time Worked and Committed</h1>

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

### `twk init`

Configures your Azure DevOps connection. You will be prompted for:

- **Organisation** - your Azure DevOps org name (e.g. `myorg`)
- **Project** - the project containing your boards (e.g. `MyProject`)
- **Team** - your team name, or leave blank for the default team
- **Personal Access Token** - a PAT with **Work Items (Read & Write)** scope

Configuration is stored at `~/.config/twk/config` with restrictive file permissions (`600`).

```
$ twk init
twk - Azure DevOps Configuration
=================================

Organisation (e.g. myorg): contoso
Project (e.g. MyProject): Platform
Team (e.g. MyTeam, or leave blank for default): Backend
Personal Access Token: ****

Configuration saved to /home/user/.config/twk/config
Testing connection...
Connected successfully.
```

---

### `twk start [task]`

Starts a timing session on a work item. Supports three resolution modes:

| Usage                         | Behaviour                                                        |
|-------------------------------|------------------------------------------------------------------|
| `twk start 12345`            | Direct work item ID - no API lookup required                     |
| `twk start "login bug"`      | Case-insensitive title search against the current sprint         |
| `twk start`                  | Interactive picker (`fzf` if available, numbered list otherwise) |

If a title search returns multiple matches, you will be prompted to choose.

If the work item is currently paused, `twk start` resumes it automatically.

```
$ twk start "auth refactor"
Started tracking #48210

$ twk start 48210
Error: work item #48210 is already running.
```

---

### `twk pause [task]`

Pauses an active timing session. The elapsed time so far is preserved - you can resume with `twk start` at any point.

The same task resolution modes apply (ID, title match, or interactive).

```
$ twk pause 48210
Paused #48210 (01:34:12 tracked)
```

---

### `twk end [task]`

Ends a timing session on a work item. The session is finalised and ready to commit.

You can end a work item that is either running or paused.

```
$ twk end 48210
Ended #48210 (03:22:45 total)
```

---

### `twk status`

Displays all uncommitted time entries with their current state and accumulated duration.

```
$ twk status
Uncommitted time entries:
─────────────────────────────────────────────────
  ID       State      Time         Hours
─────────────────────────────────────────────────
  #48210   ended      03:22:45     3.38h
  #48215   running    00:45:30     .75h
  #48220   paused     01:10:00     1.16h
─────────────────────────────────────────────────
  Total               05:18:15     5.30h
```

---

### `twk commit`

Pushes all uncommitted time entries to Azure DevOps by updating the **Completed Work** field on each work item.

- Time is **additive** - `twk` reads the existing Completed Work value and adds your tracked hours to it
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
twk - Time Worked and Committed

Usage:
    twk init                    Configure Azure DevOps connection
    twk start [task]            Start timing a work item
    twk pause [task]            Pause timing a work item
    twk end [task]              Stop timing a work item
    twk status                  View uncommitted time entries
    twk commit                  Push time entries to Azure DevOps
    twk version                 Show version

Arguments:
    [task]  Work item ID, partial title, or omit for interactive picker
```

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
twk/
├── bin/
│   └── twk              # Entry point and command router
├── lib/
│   ├── config.sh        # Configuration management and init command
│   ├── azdo.sh          # Azure DevOps REST API integration
│   ├── resolve.sh       # Work item resolution (ID, title, interactive)
│   ├── session.sh       # Local session tracking and start/pause/end commands
│   └── display.sh       # Formatting, status output, and commit command
├── install.sh           # Symlink installer
└── README.md
```

---

## Data Storage

| Path                                         | Purpose                          | Permissions |
|----------------------------------------------|----------------------------------|-------------|
| `~/.config/twk/config`                       | Azure DevOps connection settings | `600`       |
| `~/.config/twk/` (directory)                 | Configuration directory          | `700`       |
| `~/.local/share/twk/sessions/<id>.session`   | Active time tracking sessions    | Default     |
| `~/.local/share/twk/sessions/committed/`     | Archived committed sessions      | Default     |

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

- Your Personal Access Token is stored locally in `~/.config/twk/config` with `600` permissions (owner read/write only)
- The config directory is set to `700` (owner access only)
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
| `Microsoft.VSTS.Scheduling.CompletedWork`      | Read on commit, updated with tracked hours |
| `Microsoft.VSTS.Scheduling.RemainingWork`      | Fetched for reference              |
| `Microsoft.VSTS.Scheduling.StartDate`          | Fetched for reference              |
| `Microsoft.VSTS.Scheduling.TargetDate`         | Fetched for reference              |

---

## Troubleshooting

**"twk not initialised. Run 'twk init' first."**
Run `twk init` to set up your Azure DevOps connection.

**"connection test failed"**
Check that your organisation, project, and PAT are correct. Ensure the PAT has not expired and has the required Work Items scope.

**"no current iteration found"**
Your team must have an active sprint/iteration configured in Azure DevOps with the current date falling within its date range.

**"no work items in current sprint"**
The current sprint has no work items assigned. Check your board in Azure DevOps.

**Work item still running on commit**
`twk commit` skips sessions that are still active. Run `twk pause` or `twk end` on the work item first, then commit.
