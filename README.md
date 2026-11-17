<p align="center">
  <img src="images/twk_banner.png" alt="TWAK Banner" width="100%" />
</p>

<h1 align="center">TWAK - Task Worked Azure Committed</h1>

<p align="center">
  A lightweight CLI for tracking time against Azure DevOps work items, directly from the terminal.
  <br />
  Start, pause, and end timing sessions locally, then commit hours back to your board in one push.
</p>

---

## Installation

### Prerequisites

| Dependency | Purpose                                            | Required |
|------------|----------------------------------------------------|----------|
| `curl`     | Azure DevOps API requests                          | ✅        |
| `jq`       | JSON parsing                                       | ✅        |
| `fzf`      | Interactive work item picker                       | ❌ Optional |
| `git`      | Auto-`.gitignore` for project-local config (PAT protection) | ❌ Optional |
| `az`       | Sign in with your Azure CLI login instead of a PAT  | ❌ Optional (recommended) |

All required dependencies are standard on most Linux distributions. twk runs on Linux and on Windows through WSL. It avoids GNU-only options, so it should also run on macOS, but it is not yet tested there. If `fzf` is not installed, `twk` falls back to a numbered list for interactive selection. If `git` isn't on PATH, project-local `twk init` still works — it just can't auto-add `.twk/` to `.gitignore` for you (it'll print a reminder so you can do it manually).

### Quick Install (one-liner)

```bash
curl -fsSL https://raw.githubusercontent.com/Code-of-The-Forbidden-One/TWAK/master/install-remote.sh | bash
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

# Forgot to track something? Add it, then commit
twk add 12345 45m

# Check which config is in use and that you can connect
twk doctor
```

---

## Commands

### Two flows: commit cycle vs immediate

twk has two distinct ways of writing to Azure DevOps. Knowing which is which avoids surprises about when something hits the board.

| Flow | Commands | When does AzDO see it? |
|---|---|---|
| **Commit cycle (deferred)** | `start`, `pause`, `end`, `undo`, `cancel`, `adjust`, `add`, `status`, `commit` | `start`/`pause`/`end`/`undo`/`cancel`/`adjust`/`add` only touch local session files. AzDO is contacted **only** on `twk commit`, which pushes the accumulated hours in one go. |
| **Immediate AzDO actions** | `done`, `assign`, `comment`, `reset` | PATCH/POST to AzDO **as soon as you invoke them**. No staging, no `commit`, no twk-side undo — fix via the AzDO web UI or by re-running with different arguments. `reset` is destructive (wipes the time field) so it confirms by default. |
| **Immediate (alongside session change)** | `--state X` flag on any time-tracking command | Fires an immediate state PATCH on top of the local session change. The session part still goes through the commit cycle; the state change does not. |
| **Read-only / local** | `list`, `show`, `users`, `log`, `pull`, `doctor`, `init` and `trust` (write local config), `version`, `help` | No writes to AzDO state. `list`/`show`/`users` read from AzDO; `doctor` checks the connection. `pull` reads from AzDO and writes only to your local meta cache. `log` reads only the local committed/ archive — no network. `status` is local-only by default; with `--with-existing` it reads from AzDO. |

The commit cycle is the safe, iterable flow — track time offline, review with `status`, fix with `undo`/`cancel`, push when ready. The immediate flow is for things that don't have a meaningful "draft" stage (a state change, an assignment).

---

### `twk init [--global]`

Configures your Azure DevOps connection.

By default, `twk init` writes a **project-local** config to `.twk/config` in the current directory. Pass `--global` to write the global config at `~/.config/twk/config` instead.

When `twk` runs, it walks up from the current working directory looking for `.twk/config` and uses the first one it finds. If none is found, it falls back to the global config. This lets you keep different Azure DevOps connections per project (e.g. different orgs, different time fields) and a default for everything else.

`twk init` trusts the local config it writes. A `.twk/config` that arrived any other way, for example in a repository you cloned, is not used until you review it and run [`twk trust`](#twk-trust--y--yes).

If a local config holding a Personal Access Token is created inside a git repository, `twk` appends `.twk/` to `.gitignore` (creating the file if needed) so the token doesn't get committed. A reminder is printed either way - review the change before pushing.

You will be prompted for:

- **Organisation** - your Azure DevOps org name (e.g. `myorg`)
- **Project** - the project containing your boards (e.g. `MyProject`)
- **Team** - your team name, or leave blank for the default team
- **Authentication** - `azcli` to use your Azure CLI sign-in (run `az login` first; nothing secret is stored, and this is the default when `az` is installed), or `pat` to use a Personal Access Token
- **Personal Access Token** (only for `pat`) - a PAT with **Work Items (Read & Write)** scope
- **Time field for Tasks** - the AzDO field name to write time to for tasks (e.g. `Custom.TimeSpent`, `Microsoft.VSTS.Scheduling.CompletedWork`)
- **Time field for Features** - the AzDO field name for features, or leave blank if the same as tasks
- **State for start** and **State for pause** (defaults `Active` and `Paused`) - saved in the config, but not used yet: `start`, `pause`, and `end` change a work item's state only when you pass `--state <state>`
- **State for `twk done`** - the state `twk done` sets when you don't pass `--state` (default: `Done`)

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
     Task Worked Azure Committed

  Azure DevOps Configuration (local: /home/user/Projects/Platform)

Organisation (e.g. myorg): contoso
Project (e.g. MyProject): Platform
Team (e.g. MyTeam, or leave blank for default): Backend

Authentication
  azcli  Use your Azure CLI sign-in ('az login'); nothing secret is stored
  pat    Use a Personal Access Token, stored in the config file
Authentication method [azcli/pat] (default: azcli): pat
Personal Access Token: ****

Time tracking fields
These are the Azure DevOps field names that twk writes time to.
Common values: Microsoft.VSTS.Scheduling.CompletedWork, Custom.TimeSpent

Time field for Tasks (e.g. Custom.TimeSpent): Custom.TimeSpent
Time field for Features (leave blank if same as Tasks):

Work item states
Your board's state names. 'twk done' sets the done state; start, pause
and end change state only when you pass --state <state>.

State for start (default: Active): Doing
State for pause (default: Paused):
State for 'twk done' (default: Done):

Configuration saved to /home/user/Projects/Platform/.twk/config (local scope)

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

Configuration saved to /home/user/.config/twk/config (global scope)

Testing connection...
Connected successfully.
```

---

### `twk trust [-y|--yes]`

Approves the nearest project-local `.twk/config` after you have reviewed it.

A local config decides which organisation your time, comments, and state changes go to, so `twk` uses one only if `twk init` wrote it or you have trusted it. `twk trust` prints the file, with any token masked, and asks before trusting it. Trust is tied to the file's contents: if the file changes, `twk` stops using it until you trust it again. Records live in `~/.config/twk/trusted`.

```
$ twk status
Error: the local config /home/user/Projects/Platform/.twk/config is not trusted.
       twk uses a local config only if 'twk init' wrote it or you have
       reviewed and approved it. Check its contents, then run 'twk trust'.
$ twk trust
Local config: /home/user/Projects/Platform/.twk/config

    TWK_ORGANIZATION=contoso
    TWK_PROJECT=Platform
    ...

Use this config for twk commands under /home/user/Projects/Platform? [y/N] y
Trusted /home/user/Projects/Platform/.twk/config.
```

`twk` also refuses any config file, local or global, that you do not own or that other users can write to.

---

### `twk doctor`

Shows which config is in use and checks that `twk` can reach Azure DevOps. Use it when something doesn't work, or to see which organisation a directory's commands go to.

```
$ twk doctor
twk 0.2.0 (bash 5.2.15(1)-release)

Dependencies
  ok       curl
  ok       jq
  ok       fzf
  ok       git
  ok       az

Configuration
  file     /home/user/Projects/Platform/.twk/config (local, trusted)
  org      contoso
  project  Platform
  team     Backend
  auth     Azure CLI sign-in
  time     Custom.TimeSpent (tasks), Custom.TimeSpent (features)
  sessions /home/user/.local/share/twk/scopes/contoso/platform (2 uncommitted)

Connection
  ok       connected to contoso as Ada Lovelace

All good.
```

The token itself is never printed. Exits non-zero when something needs fixing.

---

### `twk start [task] [--state <state>]`

Starts a timing session on a work item. Supports three resolution modes:

| Usage                         | Behaviour                                                        |
|-------------------------------|------------------------------------------------------------------|
| `twk start 12345`            | Direct work item ID - no search (the title is fetched once, best-effort, for `twk status`) |
| `twk start "login bug"`      | Case-insensitive title search against the current sprint         |
| `twk start`                  | Interactive picker (`fzf` if available, numbered list otherwise) |

If a title search returns multiple matches, you will be prompted to choose.

If the work item is currently paused, `twk start` resumes it automatically.

The interactive picker hides items that already have a running session (you can't start them again). Items with a **paused** session show `paused HH:MM:SS` to the right of the title so you can see how much time is already on them before resuming. The AzDO assignee (display name) is shown in a column at the end of each row so you can tell at a glance who currently owns what. Titles are truncated to 40 characters and assignee names to 15 characters, both with `...`. A short note like `(2 running sessions hidden)` is printed before the picker so you know what's been filtered out.

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

### `twk assign [task] [user] [--me] [--all]`

Assigns a work item to a user in Azure DevOps. Does not affect any local session — assignment is purely an AzDO state change (PATCH on `System.AssignedTo`).

Both positional arguments are optional. Omit either or both to drop into an interactive picker:

| Form                                 | Pickers shown                            |
|--------------------------------------|------------------------------------------|
| `twk assign`                         | Task picker, then sprint user picker     |
| `twk assign 12345`                   | Sprint user picker                       |
| `twk assign 12345 --me`              | None — assigns yourself                  |
| `twk assign 12345 --all`             | Org-wide user picker (Graph API)         |
| `twk assign 12345 luke@example.com`  | None — direct PATCH                      |

**Flags:**

- `--me` — assign yourself: the identity you are signed in as (your PAT's owner, or your Azure CLI account), from `/_apis/connectionData`. Cannot be combined with an explicit user or with `--all`.
- `--all` — open the user picker against the org-wide Graph API instead of the sprint. Useful for assigning someone not yet on a sprint item. With a PAT, **it needs the `Graph (Read)` scope** in addition to `Work Items (Read & Write)`: regenerate the PAT with the extra scope and re-run `twk init` if you haven't already. With Azure CLI sign-in, your own account's access applies.

The task argument supports the usual resolution modes (numeric ID, title search). The user argument is whatever Azure DevOps recognises: email, display name, or unique name.

```
$ twk assign 12345 luke@example.com
Assigned #12345 to luke@example.com

$ twk assign "auth refactor" "Sarah Khan"
Assigned #12347 to Sarah Khan

$ twk assign 12345
Users assigned to current sprint:
   1) alice@example.com               Alice Khan
   2) bob@example.com                 Bob Smith
   3) sarah@example.com               Sarah Patel
Select [1-3] (enter to cancel): 2
Assigned #12345 to bob@example.com
```

If the user can't be resolved (typo, not in the org, disabled account), the PATCH fails and the work item is left unchanged:

```
$ twk assign 12345 nobody@nowhere
Error: PATCH https://dev.azure.com/contoso/Platform/_apis/wit/workitems/12345 failed: HTTP 400: <Azure DevOps's reason>
Error: failed to assign #12345 to nobody@nowhere.
       Check that the user (email, display name, or unique name) is
       recognised in this Azure DevOps organisation.
```

---

### `twk reset [task] [-y|--yes]`

Zeros out the configured time field on a work item in Azure DevOps. Useful when you've over-committed time or the existing AzDO value is wrong and you want to start fresh.

**Destructive.** Whatever was logged on AzDO for the time field is gone. By default the command shows the current value and prompts:

```
$ twk reset 12345
Current Custom.TimeSpent on #12345: 4.2h
Reset to 0 on Azure DevOps? [y/N] y
Reset #12345 (was 4.2h, now 0h)
```

`-y` / `--yes` skips the prompt. Pair carefully with explicit IDs — accidental wipes on a `twk reset` invocation in a wrong shell tab are easy regrets. Like `twk commit`, the reset tests the work item revision it read, so if someone changes the item in between, it is refused rather than applied blind.

```
$ twk reset 12345 --yes
Reset #12345 (was 4.2h, now 0h)
```

If the field is already 0, the command no-ops:

```
$ twk reset 12345
#12345: Custom.TimeSpent is already 0; nothing to reset.
```

**Local sessions are NOT touched.** If you have an uncommitted local session for the same work item, it remains. The next `twk commit` will push your local hours onto the now-zeroed AzDO value, so the AzDO total ends up as exactly your tracked time. This is often the goal: reset the slate, then commit clean hours.

The task argument supports the usual resolution modes (numeric ID, title search, or interactive picker when omitted).

---

### `twk comment [task] [text|-]`

Posts a comment to the AzDO Discussion thread on a work item. Read with `twk show --discussion`. Three input modes:

| Form                                          | Source of comment text             |
|-----------------------------------------------|------------------------------------|
| `twk comment 12345 "looking at it now"`       | Inline second positional argument  |
| `cat notes.txt \| twk comment 12345 -`         | Read from stdin (`-` = stdin)      |
| `twk comment 12345`                           | Open `$EDITOR` (or `$VISUAL`, fallback `vi`) |
| `twk comment` (or with title query)           | Pick task interactively, then editor |

Hits AzDO immediately — no commit cycle, no twk-side undo. Once posted, the comment is visible to anyone with read access to the work item. To remove or edit, go to the AzDO web UI.

```
$ twk comment 12345 "Looking at this now — will rebase on 48050"
Posted comment on #12345 at 2026-05-02 14:22:
  Looking at this now — will rebase on 48050
```

Editor mode strips lines starting with `#` (so the buffer's help footer doesn't get sent) and aborts cleanly if you save an empty file. Lines outside that prefix are sent verbatim; AzDO renders them as plain text in the Discussion.

```
$ twk comment 12345
# editor opens with:

# Enter your comment for #12345 above.
# Lines starting with '#' are stripped from the comment.
# Save empty content to abort.

# user types comment, saves and exits...
Posted comment on #12345 at 2026-05-02 14:25:
  Multi-line content from the editor preserved as written.
  Second paragraph here.
```

---

### `twk undo [task] [--state <state>]`

Removes the most recent event (`start`, `resume`, `pause`, `end`, or an `adjust` written by `twk adjust` or `twk add`) from a session file. Use this when you make a typo - for example, ending a session when you meant to pause it.

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

### `twk adjust [task] [amount]`

Manually adjust the recorded elapsed time on a session. Useful for the "I forgot to start the timer" / "I left it running over lunch" / "I want this to be exactly 2h" cases that come up in real use.

Both arguments are optional. Omit either or both to drop into the interactive flow:

| Form | Pickers / prompts shown |
|---|---|
| `twk adjust` | Pick task, then prompt for amount |
| `twk adjust 12345` | No picker, prompt for amount |
| `twk adjust +30m` | Pick task, amount already given |
| `twk adjust 12345 +30m` | Neither — direct adjustment |

Single-arg disambiguation: if the argument starts with `+`, `-`, or `=`, it's an amount and the task picker fires. Otherwise it's a task and the amount prompt fires.

Amount format: `<op><duration>` where `<op>` is one of `+`, `-`, or `=`:

| Form | Meaning |
|---|---|
| `+30m` | Add 30 minutes to the existing elapsed time |
| `-1h` | Subtract 1 hour from the existing elapsed time |
| `=2h` | Set elapsed time to exactly 2 hours |

Duration syntax: `1h`, `30m`, `45s`, combos like `1h30m` or `1h30m45s`, or decimal hours alone like `2.5h`.

```
$ twk adjust 12345 +30m
Adjusted #12345:
  Was:  01:34:12
  Now:  02:04:12
  Diff: +00:30:00

$ twk adjust 12345 -1h
Adjusted #12345:
  Was:  02:04:12
  Now:  01:04:12
  Diff: -01:00:00

$ twk adjust 12345 =2h
Adjusted #12345:
  Was:  01:04:12
  Now:  02:00:00
  Diff: +00:55:48

$ twk adjust
Sessions available to adjust:
   1) #12345   ended      01:00:00     Implement login button
   2) #12350   paused     00:30:00     Refactor middleware
Select [1-2] (enter to cancel): 1
Adjustment for #12345 (e.g. +30m, -1h, =2h): +15m
Adjusted #12345:
  Was:  01:00:00
  Now:  01:15:00
  Diff: +00:15:00
```

Notes:

- **Append-only**. The adjustment is recorded as an `adjust|<seconds>` event in the session file. The audit trail is preserved — anyone reading the file later can see exactly what was added/subtracted.
- **`twk undo` pops adjustments** the same way it pops any other event. Made a mistake? `twk undo` reverses the last adjust.
- **Negative results are rejected**. If subtracting would put the session below zero, the command errors and nothing changes.
- **Picker is session-scoped**. Omitting the task drops into a picker over your existing local sessions (running, paused, or ended) — adjusting only makes sense for sessions you have.

---

### `twk add [task] <duration>`

Adds time you forgot to track. The duration takes the same forms as `twk adjust`: `1h`, `30m`, `45s`, `1h30m`, or decimal hours like `2.5h`.

```
$ twk add 48210 1h30m
Added 01:30:00 to #48210 (01:30:00 uncommitted).
Run 'twk commit' to push it to Azure DevOps.
```

If the work item already has a session, the time is added to it. If not, `twk add` creates one (already ended) holding just that time. Like every time-tracking command, nothing reaches Azure DevOps until `twk commit`. With only a duration (`twk add 2h`), it opens the sprint picker.

---

### `twk cancel [task] [--state <state>]`

Discards an uncommitted local session. Use this when you started tracking the wrong work item, or left a timer running by mistake.

The session file is archived to the project's `cancelled/` folder (see [Data Storage](#data-storage)) for audit - it is not silently deleted. Nothing is pushed to Azure DevOps.

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

### `twk list [-i|--interactive] [--sort=<col>]`

Lists every work item in the current sprint with its full metadata. Useful for sprint overviews — what's there, what's been estimated, what's been done so far, and what each item is about — without leaving the terminal.

Layout mirrors `twk status`: a table of the scannable fields (ID, Title, State, Pri, Est, Done, Assigned) with the work item's description as an indented sub-line under each row.

```
$ twk list
Current sprint: Sprint 23

───────────────────────────────────────────────────────────────────────────────────────────────
  ID       Title                            State      Pri  Est      Done     Assigned
───────────────────────────────────────────────────────────────────────────────────────────────
  #48210   Implement login button           Active     2    8h       2.5h     Luke McCann
           OAuth2 implementation with PKCE flow. Needs to handle redirects from the
           legacy callback URLs and preserve session state across the rewrite.
  #48215   Refactor authentication middl... Doing      1    4h       -        Sarah Khan
           Split into auth-core and auth-azdo packages so the core can be reused by
           the worker tier without dragging the AzDO client.
  #48220   Audit code paths for the auth... New        3    -        -        -
           (no description)
───────────────────────────────────────────────────────────────────────────────────────────────
(3 items in sprint)
```

Notes:

- **Title** is truncated to 32 characters with `...` if longer.
- **Assigned** is the work item's `System.AssignedTo.displayName`. Unassigned items render as `-`. Long names are truncated to 15 characters with `...`.
- **Done** comes from the AzDO time field configured in `twk init` (Task vs Feature is resolved per item).
- **Description** is HTML-stripped, whitespace-collapsed, and truncated to 240 characters with `...`. For the full description, click through to AzDO.
- **Missing values** (no priority, no estimate, no time logged) render as `-`.
- The command hits AzDO directly — no offline mode. If the iteration or batch fetch fails, it prints a clear error and exits non-zero.
- Long output auto-pages through `less -FRX` when stdout is a TTY. Short output (less than one screen) skips the pager because of less's `-F` flag. Set `TWK_NO_PAGER=1` to opt out, or `PAGER=''` to disable globally.

**Sorting (`--sort=<col>`).** Items render in AzDO's batch order by default. Pass `--sort=<col>` to reorder by a specific column. Prefix the column name with `-` for descending.

| Column | Meaning |
|---|---|
| `id` | Numeric work item ID |
| `title` | Case-insensitive title |
| `state` | AzDO state (Active, Doing, …) |
| `pri` | Priority (1 = highest) |
| `est` | Original Estimate (hours) |
| `done` | Time logged on AzDO (hours) |
| `assigned` | Assignee display name |

Examples:

```bash
twk list --sort=pri          # priorities 1, 2, 3, ... at the top
twk list --sort=-done        # most-worked-on items first
twk list --sort=assigned     # group by assignee, alphabetical
twk list --sort=-state       # state in reverse alpha (handy when "Doing" sorts before "New")
```

Missing values for the sort key sort to the end either way (numeric: high sentinel; string: `zzz`). So unassigned items appear at the bottom whether you sort `assigned` ascending or descending — they just stay at the end.

**Interactive mode (`-i`).** With fzf installed, `twk list -i` opens the same data in a fzf-driven view: scroll, fuzzy-search, and see the full description in a preview pane on the right for whichever row is highlighted. On enter, the selected work item ID is printed to stdout — pipeable into other commands:

```bash
twk start "$(twk list -i)"      # pick interactively, then start tracking
twk show "$(twk list -i)"        # pick interactively, then read full details
```

`Esc`/`Ctrl-C` exits without selection. `Ctrl-/` toggles the preview pane.

---

### `twk show [task] [--discussion]`

Prints one work item's full metadata and description in a single labelled block. Use this when `twk list` has truncated a description and you want to read the whole thing without leaving the terminal.

The `task` argument supports the usual resolution modes: numeric ID, partial title (case-insensitive search against the current sprint), or omit for the interactive picker.

Pass `--discussion` to also fetch and render the AzDO Discussion thread (the comment conversation) in chronological order beneath the metadata block. Useful when the context you need lives in the comments rather than the description.

```
$ twk show 48210
──────────────────────────────────────────────────────────────────────────────
#48210 - Implement login button
──────────────────────────────────────────────────────────────────────────────
  Type:       Task
  State:      Active
  Priority:   2
  Assigned:   Luke McCann
  Estimate:   8h
  Done:       2.5h
  Iteration:  Platform\Sprint 23

Description:
OAuth2 implementation with PKCE flow. Needs to handle redirects from the
legacy callback URLs and preserve session state across the rewrite. We need
to ensure backward compatibility with the existing token format while
migrating to the new key set during a single deploy window.
```

Notes:

- **Read-only** — no `--state` flag, no session changes, no PATCHes. Pure fetch.
- **Description** is HTML-stripped, whitespace-collapsed, and **not truncated**. Long descriptions wrap at 78 columns.
- **Missing fields** render as `-`.
- Hits AzDO directly on each invocation — no offline mode.
- Long output auto-pages through `less -FRX`. Same opt-out (`TWK_NO_PAGER=1` or `PAGER=''`) as `twk list`.

Sample output with `--discussion`:

```
$ twk show 48210 --discussion
──────────────────────────────────────────────────────────────────────────────
#48210 - Implement login button
──────────────────────────────────────────────────────────────────────────────
  Type:       Task
  State:      Active
  ...

Description:
  OAuth2 implementation with PKCE flow...

Discussion (3 comments):
──────────────────────────────────────────────────────────────────────────────

[2026-04-15 10:30] Luke McCann:
  Did anyone test this against the legacy callback?

[2026-04-15 11:42] Sarah Khan:
  Yes, ran through it last week. Edge case with the redirect_uri encoding —
  see ticket #48050.

[2026-04-16 09:15] Luke McCann:
  Confirmed, will rebase on 48050 once it lands.

──────────────────────────────────────────────────────────────────────────────
```

---

### `twk users [--all]`

Lists users from the current sprint (default) or the entire Azure DevOps organisation (`--all`). Useful for finding the right identifier to pass to `twk assign <task> <user>` — every column shown here is something AzDO will accept on assignment, but `Email` tends to be the most reliable.

```
$ twk users
Users assigned to current sprint items:

──────────────────────────────────────────────────────────────────────────────────────────────────────
  ID                                   Username                  Email
──────────────────────────────────────────────────────────────────────────────────────────────────────
  3d4f1c70-12ab-4cde-9876-1234567890ab Alice Khan                alice@example.com
  550e8400-e29b-41d4-a716-446655440000 Luke McCann               luke@example.com
  9b8c7d6e-aabb-ccdd-eeff-001122334455 Sarah Patel               sarah@example.com
──────────────────────────────────────────────────────────────────────────────────────────────────────
(3 users)
```

Notes:

- **Sprint-scoped by default**: only shows users actually assigned to a sprint item. Team members who aren't yet assigned anything don't appear.
- **`--all` for the org-wide list**: pulls from the AzDO Graph API instead. Includes everyone in the organisation. Group entries are filtered out — only individual users appear. The ID column shows the user's *descriptor* (a longer opaque string) rather than the UUID. With a PAT, **it needs the `Graph (Read)` scope** in addition to `Work Items (Read & Write)` — regenerate your PAT with both scopes and re-run `twk init` if you haven't yet. With Azure CLI sign-in, your own account's access applies.
- **Sorted** alphabetically by display name (case-insensitive).
- **Deduplicated**: a user assigned to ten items shows up once.
- The sprint list needs no permissions beyond `Work Items (Read)`.
- Long usernames truncate at 25 chars with `...`; emails at 32.
- Output auto-pages through `less -FRX` when long. Same opt-outs (`TWK_NO_PAGER=1`, `PAGER=''`) as `twk list`.

---

### `twk log [--days=N | --all] [--by-id]`

Browses the history of committed time entries for the current organisation and project. Reads the project's `committed/` folder (see [Data Storage](#data-storage)), joins each archived session with its `.meta` sidecar for the title, and renders a chronological view of what you've pushed to AzDO.

**Local-only.** Hits no network. It reads the config only to know which organisation's and project's history to show. Output auto-pages through `less -FRX` when long.

**Defaults to the last 7 days, grouped by date.** Newest day first; within each day, commits sort newest-first by time, with ID as a tiebreaker. Each row leads with the commit time as `HH:MM`.

```
$ twk log
2026-05-02
  14:22  #48210   Implement login button                   3.38h
  10:15  #48215   Refactor auth middleware                 0.75h

2026-05-01
  17:43  #48210   Implement login button                   2.20h

2026-04-30
  09:08  #48205   Audit login bug                          1.10h

Total: 7.43h across 4 sessions.
```

**`--days=N`** widens or narrows the window. `--all` removes the limit entirely.

```
$ twk log --days=30        # last 30 days
$ twk log --days=1         # just today (ish — 24h window from now)
$ twk log --all            # everything ever
```

**`--by-id`** groups by work item ID with per-item subtotals — useful for "how much have I spent on #48210 across the project?". Each entry shows the full datetime inline:

```
$ twk log --by-id --days=14
#48210  Implement login button
  2026-05-02 14:22  3.38h
  2026-05-01 17:43  2.20h
  Subtotal: 5.58h

#48215  Refactor auth middleware
  2026-05-02 10:15  0.75h
  Subtotal: 0.75h

#48205  Audit login bug
  2026-04-30 09:08  1.10h
  Subtotal: 1.10h

Total: 7.43h across 4 sessions.
```

Notes:

- **Time sums match what was committed**, including any `twk adjust` events on the session at the time it was committed (the archived file is a snapshot).
- **Missing titles** render as `(no title cached)` — same fallback as `twk status`.
- The commit timestamp is read from the filename (`<id>_<unix_ts>.session`), not from a header inside the file.
- Empty windows print a clear message: `No commits in the last 7 days.` (or `No commits found.` for `--all`).

---

### `twk pull`

Refreshes the cached title/type metadata for every uncommitted session by re-fetching from Azure DevOps. Useful when:

- You started a session offline and `twk status` shows `(no title cached)`.
- A work item was renamed in AzDO and you want `twk status` to show the new title without restarting the session.
- You want to verify your local cache reflects the current AzDO state without committing or starting anything new.

Best-effort — a single session failing (work item deleted, network glitch) doesn't abort the rest. Each session gets a status line.

```
$ twk pull
Refreshing metadata for 3 sessions...

  #48210: refreshed ("Implement login button")
  #48215: refreshed ("Refactor auth middleware")
  #48220: failed (work item not found or unreachable)

Done: 2 refreshed, 1 failed.
```

This only refreshes data that's cached locally (currently title + type, used by `twk status`). Sprint listings are read live by `twk list`; `twk commit` reads existing AzDO time live; neither uses or affects the meta cache.

---

### `twk status [--with-existing]`

Shows which config is active (and its scope) followed by all uncommitted time entries with their work item title, current state, and accumulated duration.

Titles are cached to a sidecar `.meta` file the first time you `twk start <id>`, so `status` itself stays offline by default. Titles are truncated to 40 characters with `...` if longer. Sessions started before this caching landed (or while you were offline) will show `(no title cached)`; resume them once with `twk start <id>` while online to backfill the title.

```
$ twk status
Config: /home/user/Projects/Platform/.twk/config (local scope)

Uncommitted time entries:
─────────────────────────────────────────────────────────────────────────────────
  ID       Title                                    State      Time         Hours
─────────────────────────────────────────────────────────────────────────────────
  #48210   Implement login button                   ended      03:22:45     3.38h
  #48215   Refactor authentication middleware to... running    00:45:30     0.76h
  #48220   Fix flaky integration test on CI         paused     01:10:00     1.17h
─────────────────────────────────────────────────────────────────────────────────
  Total                                             05:18:15     5.30h
```

Pass `--with-existing` to fold in the current time-field value from AzDO on each work item — useful for previewing what the next `twk commit` will leave on the board. The command issues a single batched call to the AzDO work-items endpoint and adds two columns: `+ AzDO` (current value) and `= Total` (post-commit projection). Cells display `?` if the lookup fails (network down, work item deleted, etc.); the command itself does not fail.

```
$ twk status --with-existing
Config: /home/user/Projects/Platform/.twk/config (local scope)

Uncommitted time entries:
─────────────────────────────────────────────────────────────────────────────────────────────────────
  ID       Title                                    State      Time         Hours    + AzDO    = Total
─────────────────────────────────────────────────────────────────────────────────────────────────────
  #48210   Implement login button                   ended      03:22:45     3.38h    4.20h     7.58h
  #48215   Refactor authentication middleware to... running    00:45:30     0.76h    1.00h    1.76h
  #48220   Fix flaky integration test on CI         paused     01:10:00     1.17h    0.00h    1.17h
─────────────────────────────────────────────────────────────────────────────────────────────────────
  Total                                             05:18:15     5.30h    5.20h    10.51h
```

---

Like `twk list` and `twk show`, the table portion auto-pages through `less -FRX` when output exceeds one screen and stdout is a TTY. The "Config:" line above the table prints unpaged.

---

### `twk commit [--dry-run]`

Pushes all uncommitted time entries to Azure DevOps by updating the configured time field on each work item.

- Time is **additive** - `twk` reads the existing value and adds your tracked hours to it, rounded to the nearest 0.01h
- The target field is determined by work item type (Task vs Feature) based on your `twk init` configuration
- Work items that are still running are **skipped** - end or pause them first
- Only the current organisation's and project's sessions are committed: run it from the project whose config you tracked under
- Committed sessions are archived to the project's `committed/` folder for audit

It never overwrites hours it could not read:

- If the current value can't be read, nothing is written for that item and its session stays uncommitted.
- The write includes the work item revision that was read. If someone changes the item in between, Azure DevOps refuses the write; run `twk commit` again.
- If the outcome of a write is unknown (the network dropped, or Azure DevOps returned a server error), the session stays and the next `twk commit` checks whether the earlier write landed before adding anything.

A failed item says why, and the rest carry on:

```
$ twk commit
Committing time entries to Azure DevOps...

Error: PATCH https://dev.azure.com/contoso/Platform/_apis/wit/workitems/48210 failed: HTTP 400: <Azure DevOps's reason>
  #48210: failed to update Azure DevOps (nothing was written)
  #48220: committed 1.17h (total: 1.17h)

Done: 1 committed, 1 failed/skipped.
```

```
$ twk commit
Committing time entries to Azure DevOps...

  #48210: committed 3.38h (total: 7.38h)
  #48215: skipped (still running - end or pause first)
  #48220: committed 1.17h (total: 1.17h)

Done: 2 committed, 1 failed/skipped.
```

**Dry-run preview.** Pass `--dry-run` to see the per-session projection (existing AzDO value + your tracked hours = post-commit total) without writing anything. Reads against AzDO still happen (to fetch existing time); only the writes are suppressed. Sessions stay uncommitted, ready for a real `twk commit` when you're satisfied.

```
$ twk commit --dry-run
DRY RUN — no changes will be sent to Azure DevOps.

  #48210: would commit 3.38h (existing 4.20h → total 7.58h)
  #48215: skipped (still running - end or pause first)
  #48220: would commit 1.17h (existing 0.00h → total 1.17h)

Would commit 4.55h across 2 sessions, skipping 1.
(no changes were sent to Azure DevOps; sessions remain uncommitted)
```

---

### `twk version` (also `-v` / `--version`)

Displays the current version. All three forms produce identical output:

```
$ twk version
twk 0.2.0

$ twk -v
twk 0.2.0

$ twk --version
twk 0.2.0
```

---

### `twk help`

Displays usage information.

```
$ twk help
Usage:
  Setup
    twk init             Configure Azure DevOps connection
    twk trust            Approve a project-local .twk/config after reviewing it
    twk doctor           Show the active config and check the connection

  Time tracking (commit cycle — local until 'twk commit'):
    twk start            Start timing a work item
    twk pause            Pause timing a work item
    twk end              Stop timing a work item
    twk undo             Undo the last event on a session
    twk cancel           Discard an uncommitted session
    twk adjust           Manually adjust recorded time on a session
    twk add              Add time you forgot to track (e.g. twk add 123 1h30m)
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
    -y, --yes            (reset, trust) Skip the confirmation prompt
    --days=<n>           (log only) Limit history to the last N days (default 7)
    --by-id              (log only) Group history by work item ID instead of date

Note: --state X on any time-tracking command also fires an immediate PATCH to AzDO.

Pass --help (or -h) to any subcommand for full per-command help.

Environment:
    TWK_NO_PAGER         Disable the auto-pager for list / show / status.
    PAGER                Pager to use for long output (default: less -FRX,
                         or cat if less is missing). Empty disables paging.
```

Pass `--help` (or `-h`) to any subcommand for detailed help on that command (e.g. `twk start --help`).

---

## Windows (WSL)

`twk` runs on Windows through the Windows Subsystem for Linux. If you don't have WSL set up yet, open PowerShell as Administrator and run:

```powershell
wsl --install
```

Restart your machine when prompted, then launch Ubuntu from the Start menu. Once inside WSL, install the dependencies and `twk` as normal:

```bash
sudo apt update && sudo apt install -y curl jq
curl -fsSL https://raw.githubusercontent.com/Code-of-The-Forbidden-One/TWAK/master/install-remote.sh | bash
source ~/.bashrc
twk init
```

To sign in with the Azure CLI rather than a PAT, install it inside WSL too (`curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash`) and run `az login` there. The Windows `az` doesn't share its sign-in with WSL.

After setup, you can use `twk` from any WSL terminal. If you use Windows Terminal, pin your WSL profile for quick access.

### Using `twk` from PowerShell

Add this function to your PowerShell profile so `twk` works like a native command. Open the profile with:

```powershell
notepad $PROFILE
```

Append this and save:

```powershell
function twk {
    if (-not $global:TwkPath) {
        $global:TwkPath = (wsl.exe --exec sh -c 'echo $HOME/.local/bin/twk').Trim()
    }
    wsl.exe --exec $global:TwkPath @args
}
```

New PowerShell sessions now treat `twk` as a native command:

```powershell
PS> twk start "auth refactor"
PS> twk status
PS> twk commit
```

How it works, and why it isn't just `wsl twk @args`:

- `wsl twk` runs `twk` through a non-interactive shell that doesn't read `~/.bashrc`, so `~/.local/bin` isn't on its `PATH` and the command isn't found. The function calls twk by its full path instead, which it looks up once per session.
- `wsl twk` also hands the arguments to a Linux shell, which splits them again: `twk start "auth refactor"` would arrive as two words. `wsl.exe --exec` runs twk directly, so each argument arrives exactly as PowerShell passed it.
- twk runs in the PowerShell window's current directory (as `/mnt/c/...`), so a project's `.twk/config` is found as usual.
- Use PowerShell 7.3 or later if your arguments contain double quotes (for example, a `twk comment` text). Windows PowerShell 5.1 strips embedded double quotes when it calls a native program.

### Tips for WSL users

- **VS Code integration** - Run `code .` from WSL and VS Code connects automatically via the Remote-WSL extension. You can use the integrated terminal to run `twk` alongside your development workflow.
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
│   └── twk              # Entry point: bootstraps env, sources libs, calls main
├── lib/
│   ├── config.sh        # Local/global config resolution and init command
│   ├── azdo.sh          # Azure DevOps REST API integration
│   ├── resolve.sh       # Work item resolution (ID, title, interactive pickers)
│   ├── session.sh       # Session events, start/pause/end/undo/cancel commands
│   ├── display.sh       # Formatting, status output, and commit command
│   ├── help.sh          # Per-subcommand --help text + contains_help_flag scanner
│   ├── banner.sh        # ASCII banner
│   └── dispatch.sh      # Top-level main() and print_usage()
├── man/
│   └── twk.1            # Man page
├── tests/
│   ├── *.bats           # bats-core test suite (one file per lib/*.sh, plus
│   │                    #   security.bats and commit_safety.bats)
│   ├── helpers/         # Shared setup, AzDO mocks, jq fallback stub
│   ├── run.sh           # Test runner wrapper
│   └── README.md        # How to run the tests
├── images/              # README assets
├── install.sh           # Local installer (symlinks bin/twk to ~/.local/bin)
├── install-remote.sh    # Curl-pipe-bash installer used by the one-liner
├── docker-test.sh       # Dockerised dev shell / test runner (no host install needed)
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
| `~/.config/twk/trusted`                      | Local configs you have trusted, with their checksums | `600`       |
| `<scope>/<id>.session`                       | Active time tracking sessions                        | Default     |
| `<scope>/<id>.meta`                          | Cached work item title and type (JSON)               | Default     |
| `<scope>/<id>.pending`                       | A commit whose outcome is not yet known              | Default     |
| `<scope>/committed/`                         | Archived committed sessions (with their `.meta`)     | Default     |
| `<scope>/cancelled/`                         | Archived cancelled sessions (with their `.meta`)     | Default     |

`<scope>` is `~/.local/share/twk/scopes/<organisation>/<project>` (lower-cased and URL-encoded). Work item IDs are only unique within an organisation, so each organisation's and project's sessions are kept apart, and `twk commit` only pushes the sessions of the config in use. `twk doctor` shows the folder for the current directory.

Before 0.2.0, all sessions lived in `~/.local/share/twk/sessions/`. The first command you run after upgrading moves them into the scope of the config in use, and says so. If you track time in more than one organisation, check them with `twk status`, and `twk cancel` any that belong elsewhere.

Local configs are discovered by walking up from the current working directory. The first `.twk/config` found is used, if it is trusted; otherwise twk falls back to the global config.

### Session File Format

Sessions are stored as append-only flat files with one event per line:

```
start|1714560000
pause|1714563600
resume|1714567200
adjust|1800
end|1714574400
```

The first column is the event type. For `start`/`pause`/`resume`/`end`, the second column is a unix timestamp. For `adjust` (written by `twk adjust` and `twk add`), the second column is a signed delta in seconds — positive adds to the calculated elapsed time, negative subtracts. `twk add` on a work item with no session writes `start` and `end` at the same moment, then the `adjust`. The format is human-readable, easy to debug, and easy to parse.

---

## Security

- **Sign in without a stored secret.** With `TWK_AUTH=azcli`, `twk` asks the Azure CLI for a short-lived Entra ID token on each run. Nothing secret is written to disk, and your organisation's sign-in policy (MFA, conditional access) applies.
- **A PAT, if you use one, stays private.** It is stored in `.twk/config` or `~/.config/twk/config` with `600` permissions, in a `700` directory. It is handed to `curl` on standard input, never on its command line, so other users on the machine cannot read it with `ps`. It goes only to Azure DevOps, over HTTPS.
- **Config files are data, not code.** `twk` reads `KEY=value` lines and accepts only its own keys; nothing in a config file is ever run.
- **Only your own config is used.** `twk` refuses a config file that you do not own, or that other users can write to.
- **Local configs must be trusted.** A `.twk/config` is used only if `twk init` wrote it or you approved it with `twk trust`, and only while its contents are unchanged. A config committed to a repository you clone cannot redirect your time or comments to someone else's organisation.
- **Text from Azure DevOps cannot control your terminal.** Control characters are stripped from every response, so a work item title, description, or comment written by someone else is printed as plain text.
- **Git protection.** When `twk init` writes a local config holding a PAT inside a git repository, it appends `.twk/` to `.gitignore`. Review the change before pushing.
- No credentials are logged, or sent anywhere but Azure DevOps.

---

## Azure DevOps PAT Permissions

You need a PAT only if you don't sign in with the Azure CLI (`TWK_AUTH=azcli`), which uses your own account's permissions. When creating a Personal Access Token, the minimum required scope is:

| Scope             | Access       | Required | Purpose                                                         |
|-------------------|--------------|----------|-----------------------------------------------------------------|
| **Work Items**    | Read & Write | ✅        | Fetch sprint items, update Completed Work, PATCH state/assignee |
| **Graph**         | Read         | ❌ Optional | Enables `twk users --all` and `twk assign --all` (org-wide user listing) |

Generate a PAT at: `https://dev.azure.com/{your-org}/_usersettings/tokens`. If you've already created one without `Graph (Read)` and want the `--all` flags to work, regenerate it with both scopes and re-run `twk init`.

---

## Azure DevOps Fields

`twk` reads and writes the following work item fields:

| Field                                             | Usage                                                        |
|---------------------------------------------------|--------------------------------------------------------------|
| `System.Id`, `System.Title`                       | Identification, title search, and display                    |
| `System.WorkItemType`                             | Display; chooses the Task or Feature time field              |
| `System.State`                                    | Display; written by `twk done` and by `--state` on any time-tracking command |
| `System.AssignedTo`                               | Display and the sprint user picker; written by `twk assign`  |
| `System.Description`, `System.IterationPath`      | Shown by `twk list` and `twk show`                           |
| `Microsoft.VSTS.Common.Priority`                  | Shown and sortable in `twk list`                             |
| `Microsoft.VSTS.Scheduling.OriginalEstimate`      | Shown and sortable in `twk list`                             |
| Configured time fields (e.g. `Custom.TimeSpent`)  | Read and written by `twk commit` and `twk reset`; shown by `list`, `show`, `status --with-existing` |
| The work item revision (`rev`)                    | Read before `twk commit` and `twk reset` write, and tested by the write so a concurrent change is refused |

---

## Development

### Running the tests

The bats-core test suite lives under `tests/`. To run it:

```bash
./tests/run.sh                       # everything
./tests/run.sh tests/session.bats    # a single file
bats tests/                          # equivalent
```

You'll need `bats-core` on PATH (`pacman -S bash-bats` on Arch, `apt-get install bats` on Debian, `brew install bats-core` on macOS). See `tests/README.md` for the full prerequisites, mock strategy, and layout.

### Running tests in Docker

If you'd rather not install `bats`, `jq`, etc. on the host, `docker-test.sh` spins up a throwaway Debian container with everything wired up:

```bash
./docker-test.sh tests          # run the suite, exit with bats's status
./docker-test.sh                # interactive shell with twk and bats available
./docker-test.sh --help         # usage
```

The source tree is bind-mounted **read-only**, so test runs leave nothing behind on the host except the named volumes that hold any `twk init` config you create during a shell session (the test suite itself never touches them).

---

## Troubleshooting

**"twk not initialised. Run 'twk init' first."**
No `.twk/config` was found in the current directory or any parent, and no global config exists at `~/.config/twk/config`. Run `twk init` to create a project-local config, or `twk init --global` to create a global one.

**"connection test failed"**
Run `twk doctor`: it shows the config in use and the reason the connection failed. Check that your organisation and project are correct. With a PAT, check that it has not expired and has the Work Items scope; with Azure CLI sign-in, run `az login`.

**"the local config … is not trusted"**
The nearest `.twk/config` wasn't written by `twk init`, has changed since you trusted it, or predates 0.2.0. Check its contents, then run `twk trust`.

**"… is not owned by you" or "… can be written by other users"**
twk only uses a config that you own and that nobody else can change. Fix the permissions with `chmod 600 <file>` and `chmod 700 <its directory>`, or run `twk init` to write your own.

**"could not get an Azure DevOps token from the Azure CLI"**
Your config uses `TWK_AUTH=azcli`. Run `az login` (inside WSL, if you use twk there).

**"HTTP 401" or "HTTP 403"**
401: the PAT is wrong or expired, or your Azure CLI sign-in has lapsed. 403: your account or PAT lacks permission, for example the `Graph (Read)` scope for `--all`.

**"another twk command is changing sessions"**
Another twk command holds the session lock. If none is running (say a terminal was killed mid-command), twk normally takes the lock over by itself; if it doesn't, remove the `.lock` directory the message names.

**"outcome unknown; run 'twk commit' again"**
The network dropped or Azure DevOps returned a server error during a write, so twk can't tell whether your hours were saved. Run `twk commit` again: it checks before adding anything.

**"no current iteration found"**
Your team must have an active sprint/iteration configured in Azure DevOps with the current date falling within its date range.

**"no work items in current sprint"**
The current sprint has no work items assigned. Check your board in Azure DevOps.

**Work item still running on commit**
`twk commit` skips sessions that are still active. Run `twk pause` or `twk end` on the work item first, then commit.
