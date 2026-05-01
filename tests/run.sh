#!/usr/bin/env bash
# tests/run.sh — wrapper to run the bats suite.
#
# Looks for `bats` on PATH; if missing, falls back to a vendored bats-core
# at /tmp/bats-core/bin/bats (test-only convenience for environments where
# bats isn't installed system-wide).
#
# The suite uses python-backed jq/bc fallbacks under tests/helpers/stubs;
# those are added to PATH automatically so individual tests don't need to.

set -euo pipefail

TESTS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Find a bats binary.
if command -v bats >/dev/null 2>&1; then
    BATS="$(command -v bats)"
elif [[ -x "/tmp/bats-core/bin/bats" ]]; then
    BATS="/tmp/bats-core/bin/bats"
    echo "Using vendored bats from ${BATS} (install bats-core for production use)" >&2
    echo "  Arch:   sudo pacman -S bash-bats" >&2
    echo "  Debian: sudo apt-get install bats" >&2
else
    cat >&2 <<'EOF'
Error: bats not found. Install bats-core to run the suite:
  Arch:   sudo pacman -S bash-bats
  Debian: sudo apt-get install bats
  macOS:  brew install bats-core
  Or:     git clone https://github.com/bats-core/bats-core /tmp/bats-core
EOF
    exit 1
fi

# Append our jq/bc fallbacks so real jq/bc (when present) win. The
# python-backed stubs only fill in when neither is on PATH. setup.bash
# does the same when individual tests call twk_load_stub_path.
export PATH="${PATH}:${TESTS_DIR}/helpers/stubs"

# Allow callers to pass a specific test file or globs:
#   tests/run.sh                       — run everything
#   tests/run.sh tests/session.bats    — run a single file
#   tests/run.sh --tap                 — propagate flags
if [[ $# -gt 0 ]]; then
    exec "${BATS}" "$@"
fi

exec "${BATS}" "${TESTS_DIR}"
