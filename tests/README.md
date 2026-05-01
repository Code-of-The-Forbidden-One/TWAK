# TWAK test suite

[bats-core](https://github.com/bats-core/bats-core) test suite for the bash
codebase under `bin/twk` and `lib/`.

## Running

```sh
tests/run.sh                       # run everything
tests/run.sh tests/session.bats    # run a single file
tests/run.sh --tap                 # forward bats flags
```

Or, equivalently:

```sh
bats tests/
```

### In Docker (no host install)

If you don't want to install bats / jq / bc on the host, the project's
`docker-test.sh` can run the suite inside a throwaway Debian container:

```sh
./docker-test.sh tests             # runs tests/run.sh, exits with its status
./docker-test.sh                   # drops you into a bash prompt with bats
                                   # available; run './tests/run.sh' there
```

The container bind-mounts the source read-only, so test runs leave nothing
behind on the host except the named volumes that hold any `twk init` config
you create during a shell session (which the test suite itself doesn't
touch).

## Prerequisites

Required:

- **bats-core 1.7+** — `pacman -S bash-bats` on Arch, `apt-get install bats`
  on Debian, `brew install bats-core` on macOS. If neither is on PATH,
  `tests/run.sh` will fall back to `/tmp/bats-core/bin/bats` if you've cloned
  the repo there for one-off use.
- **bash 5.0+** — the suite uses `local -n` and other 5.x niceties
  indirectly through bats.
- **git** — the `lib/config.sh` tests do real `git init` to exercise the
  worktree / submodule / subdirectory cases. A handful of tests
  `skip` themselves if `git` isn't on PATH (the suite tells you which).

Optional but recommended (the codebase needs them at runtime; tests fall
back to python-backed shims if missing):

- **jq** — used by `lib/azdo.sh` and others. Tests that need a real jq
  filter pull in `tests/helpers/stubs/jq` (a python3 script that handles
  exactly the filters the codebase invokes). Install real jq if you can:
  `pacman -S jq`. The real binary wins over the stub when both are on
  PATH (`tests/run.sh` and `setup.bash` both append the stubs dir).
- **bc** — used by `lib/display.sh`. The python-backed `tests/helpers/stubs/bc`
  covers the two patterns the codebase uses (`scale=2; <a> / <b>` and
  `scale=2; <a> + <b>`). Real bc wins when present (same PATH ordering).
- **python3** — required only if jq or bc are missing on PATH; the
  fallback stubs are written in Python.

The `curl` and `fzf` paths are not exercised by the suite (every AzDO call
is mocked, every fzf branch is sidestepped via the no-fzf code path).

## Layout

```
tests/
  helpers/
    setup.bash         per-test env (TWK_DATA_DIR, TWK_CONFIG_DIR), assertion helpers
    mock_azdo.bash     overrides for every azdo_* function, fixture-driven, with call recording
    stubs/
      jq               python3 fallback for jq, scoped to filters the codebase uses
      bc               python3 fallback for bc, scoped to scale=2 add/divide
  config.bats          lib/config.sh
  session.bats         lib/session.sh
  azdo.bats            lib/azdo.sh
  resolve.bats         lib/resolve.sh
  display.bats         lib/display.sh
  help.bats            lib/help.sh
  twk_dispatch.bats    bin/twk dispatcher routing + --help-anywhere behaviour
  integration.bats     start → pause → resume → end → commit, archive layout, PATCH issued
  run.sh               wrapper script
```

One `*.bats` per `lib/*.sh` plus `integration.bats` and `twk_dispatch.bats`.

## Mocking strategy

### AzDO

`tests/helpers/mock_azdo.bash` overrides every public function in
`lib/azdo.sh` with a stub that:

1. Logs the call (function name + args, tab-separated) to
   `${MOCK_AZDO_CALL_LOG}` (default: `${BATS_TEST_TMPDIR}/azdo_calls.log`).
2. Returns a value defined by either:
   - **A fixture file** in `${MOCK_AZDO_FIXTURES_DIR}` (e.g.
     `work_item_42.json`, `work_item_42.meta.json`, `current_iteration.json`,
     `iteration_<id>_items.json`, `batch_response.json`).
   - **An env-var rc override** (e.g. `MOCK_AZDO_UPDATE_STATE_RC=1` to
     simulate a failed PATCH). All default to 0.

Use `mock_azdo_was_called <fn>`, `mock_azdo_call_count <fn>`, and
`mock_azdo_call_args <fn>` to assert from your tests.

### Time

Where determinism matters (the integration test), a fake `date` shim is
prepended to PATH that honours `date +%s` by reading a per-call counter
file and returning `${DATE_BASE} + counter * 60`. Every other date
invocation falls through to real `date` on `/usr/bin`.

### git

Not mocked — `lib/config.sh` interrogates git for worktree/submodule
detection, and the right way to test that is with real `git init`,
`git worktree add`, etc. in tmpdirs.

### fzf

Not mocked — `lib/resolve.sh` falls back to the numbered-list path when
`fzf` is absent (`command -v fzf` returns non-zero), and the numbered-list
path is what the tests drive (with `echo <selection> |`).

## Coverage notes

- `lib/config.sh` — every gitignore branch (no .gitignore, no trailing
  newline, already-`.twk/`, already-`.twk`, symlink, no-git, not-a-repo,
  worktree, subdirectory of a repo) plus walk-up cases (root, no slashes,
  deep nesting, nearer-wins).
- `lib/session.sh` — `validate_work_item_id` positive + negative,
  `session_read_state` for every event sequence, `session_pop_last_event`
  rc=0/2/3 + the round-1 trailing-newline regression, `session_cache_meta`
  three branches, `parse_state_flag` / `parse_query_arg` ordering matrix.
- `lib/display.sh` — `format_duration` boundary, `seconds_to_hours`,
  `truncate_title` under/exact/over, `cmd_status` config line / table /
  totals / "(no title cached)" placeholder.
- `lib/azdo.sh` — `url_encode` special chars including unicode,
  `azdo_resolve_time_field` Task vs Feature, base/team URL builders,
  PATCH body shape for state and time updates.
- `lib/resolve.sh` — numeric short-circuit, dispatch, state filtering,
  auto-select-on-single-match, hidden-running count, paused suffix,
  truncation in interactive picker.
- `lib/help.sh` — `contains_help_flag` any-position + empty argv;
  `show_subcommand_help` for every known subcommand.
- `bin/twk` — every subcommand routes correctly; `--help` works in any
  position (the round-1 review's issue #3).
- `integration.bats` — start → pause → resume → end → commit; cancel
  variant; undo variant; commit-skips-running variant; status between
  events.

## Adding tests

Use `tests/session.bats` as the template. The standard preamble:

```bash
load 'helpers/setup.bash'
load 'helpers/mock_azdo.bash'

setup() {
    twk_setup_env
    twk_source_libs
    twk_load_stub_path        # adds python jq/bc fallbacks behind real ones
    mock_azdo_install         # overrides every azdo_* function
}
```

Assertion helpers available out of the box:

- `assert_status <expected>` — `$status` after `run`
- `assert_output_contains <substring>`
- `assert_output_not_contains <substring>`
- `assert_session_state <id> <expected>` — running / paused / ended / none
- `assert_session_event_count <id> <expected>`
- `assert_file_exists <path>` / `assert_file_not_exists <path>`
- `require_binary <name>` — `skip` the test if a binary isn't on PATH

If your test needs a fixture, drop a JSON file under
`${BATS_TEST_TMPDIR}/fixtures/` and `export MOCK_AZDO_FIXTURES_DIR=` to it
in `setup()` (or per-test).
