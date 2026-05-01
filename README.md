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

| Dependency | Purpose                                            | Required |
|------------|----------------------------------------------------|----------|
| `curl`     | Azure DevOps API requests                          | ✅        |
| `jq`       | JSON parsing                                       | ✅        |
| `bc`       | Decimal hour calculations                          | ✅        |
| `fzf`      | Interactive work item picker                       | ❌ Optional |
| `git`      | Auto-`.gitignore` for project-local config (PAT protection) | ❌ Optional |

All required dependencies are standard on most Linux distributions. If `fzf` is not installed, `twk` falls back to a numbered list for interactive selection. If `git` isn't on PATH, project-local `twk init` still works — it just can't auto-add `.twk/` to `.gitignore` for you (it'll print a reminder so you can do it manually).

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

### Two flows: commit cycle vs immediate

twk has two distinct ways of writing to Azure DevOps. Knowing which is which avoids surprises about when something hits the board.

| Flow | Commands | When does AzDO see it? |
|---|---|---|
| **Commit cycle (deferred)** | `start`, `pause`, `end`, `undo`, `cancel`, `status`, `commit` | `start`/`pause`/`end`/`undo`/`cancel` only touch local session files. AzDO is contacted **only** on `twk commit`, which pushes the accumulated hours in one go. |
| **Immediate AzDO actions** | `done`, `assign`, `comment` | PATCH/POST to AzDO **as soon as you invoke them**. No staging, no `commit`, no twk-side undo — fix via the AzDO web UI or by re-running with different arguments. |
| **Immediate (alongside session change)** | `--state X` flag on any time-tracking command | Fires an immediate state PATCH on top of the local session change. The session part still goes through the commit cycle; the state change does not. |
| **Read-only / local** | `list`, `show`, `users`, `pull`, `init` (writes local config), `version`, `help` | No writes to AzDO state. `list`/`show`/`users` read from AzDO. `pull` reads from AzDO and writes only to your local meta cache. `status` is local-only by default; with `--with-existing` it reads from AzDO. |

The commit cycle is the safe, iterable flow — track time offline, review with `status`, fix with `undo`/`cancel`, push when ready. The immediate flow is for things that don't have a meaningful "draft" stage (a state change, an assignment).

---

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
     Timed Worked and Committed

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

- `--me` — assign yourself, derived from the PAT's identity via `/_apis/connectionData`. Cannot be combined with an explicit user or with `--all`.
- `--all` — open the user picker against the org-wide Graph API instead of the sprint. Useful for assigning someone not yet on a sprint item. **Requires `Graph (Read)` scope on your PAT** in addition to `Work Items (Read & Write)`. Regenerate the PAT with the extra scope and re-run `twk init` if you haven't already.

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
Error: failed to assign #12345 to nobody@nowhere.
       Check that the user (email, display name, or unique name) is
       recognised in this Azure DevOps organisation.
```

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
- **`--all` for the org-wide list**: pulls from the AzDO Graph API instead. Includes everyone in the organisation. Group entries are filtered out — only individual users appear. The ID column shows the user's *descriptor* (a longer opaque string) rather than the UUID. **Requires `Graph (Read)` scope** on your PAT in addition to `Work Items (Read & Write)` — regenerate your PAT with both scopes and re-run `twk init` if you haven't yet.
- **Sorted** alphabetically by display name (case-insensitive).
- **Deduplicated**: a user assigned to ten items shows up once.
- Reuses your existing `Work Items (Read & Write)` PAT scope. No extra permissions needed.
- Long usernames truncate at 25 chars with `...`; emails at 32.
- Output auto-pages through `less -FRX` when long. Same opt-outs (`TWK_NO_PAGER=1`, `PAGER=''`) as `twk list`.

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
  #48215   Refactor authentication middleware to... running    00:45:30     .75h
  #48220   Fix flaky integration test on CI         paused     01:10:00     1.16h
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
  #48215   Refactor authentication middleware to... running    00:45:30     .75h     1.00h     1.75h
  #48220   Fix flaky integration test on CI         paused     01:10:00     1.16h    0h        1.16h
─────────────────────────────────────────────────────────────────────────────────────────────────────
  Total                                             05:18:15     5.30h    5.20h    10.49h
```

---

Like `twk list` and `twk show`, the table portion auto-pages through `less -FRX` when output exceeds one screen and stdout is a TTY. The "Config:" line above the table prints unpaged.

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

### `twk version` (also `-v` / `--version`)

Displays the current version. All three forms produce identical output:

```
$ twk version
twk 0.1.0

$ twk -v
twk 0.1.0

$ twk --version
twk 0.1.0
```

---

### `twk help`

Displays usage information.

```
$ twk help
Usage:
  Setup
    twk init             Configure Azure DevOps connection

  Time tracking (commit cycle — local until 'twk commit'):
    twk start            Start timing a work item
    twk pause            Pause timing a work item
    twk end              Stop timing a work item
    twk undo             Undo the last event on a session
    twk cancel           Discard an uncommitted session
    twk status           View uncommitted time entries
    twk commit           Push accumulated hours to Azure DevOps

  Direct AzDO actions (immediate — write to AzDO right away):
    twk done             Mark a work item as done (state-only)
    twk assign           Assign a work item to a user
    twk comment          Post a comment to a work item's Discussion

  Read-only:
    twk list             List current sprint items with metadata
    twk show             Show one work item's full metadata + description
    twk users            List sprint or org-wide users
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
    --sort=<col>         (list only) Sort by id|title|state|pri|est|done|assigned;
                         prefix with '-' for descending: --sort=-done
    --me                 (assign only) Assign yourself based on the PAT's identity
    --all                (assign, users) Use org-wide user list (Graph API; needs PAT scope)
    --discussion         (show only) Append the AzDO Discussion thread (comments)

Note: --state X on any time-tracking command also fires an immediate PATCH to AzDO.

Environment:
    TWK_NO_PAGER         Disable the auto-pager for list / show / status.
    PAGER                Pager to use for long output (default: less -FRX,
                         or cat if less is missing). Empty disables paging.
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
│   ├── *.bats           # bats-core test suite (one file per lib/*.sh)
│   ├── helpers/         # Shared setup, AzDO mocks, jq/bc fallback stubs
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

| Scope             | Access       | Required | Purpose                                                         |
|-------------------|--------------|----------|-----------------------------------------------------------------|
| **Work Items**    | Read & Write | ✅        | Fetch sprint items, update Completed Work, PATCH state/assignee |
| **Graph**         | Read         | ❌ Optional | Enables `twk users --all` and `twk assign --all` (org-wide user listing) |

Generate a PAT at: `https://dev.azure.com/{your-org}/_usersettings/tokens`. If you've already created one without `Graph (Read)` and want the `--all` flags to work, regenerate it with both scopes and re-run `twk init`.

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

If you'd rather not install `bats`, `jq`, `bc`, etc. on the host, `docker-test.sh` spins up a throwaway Debian container with everything wired up:

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
Check that your organisation, project, and PAT are correct. Ensure the PAT has not expired and has the required Work Items scope.

**"no current iteration found"**
Your team must have an active sprint/iteration configured in Azure DevOps with the current date falling within its date range.

**"no work items in current sprint"**
The current sprint has no work items assigned. Check your board in Azure DevOps.

**Work item still running on commit**
`twk commit` skips sessions that are still active. Run `twk pause` or `twk end` on the work item first, then commit.
