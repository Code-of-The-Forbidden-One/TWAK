#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

usage() {
    cat <<EOF
Usage: ${0##*/} [shell|tests|--help]

  shell      Drop into a bash prompt with twk installed (default).
  tests      Run the bats test suite and exit with its status.
  --help|-h  Show this message.
EOF
}

mode="${1:-shell}"
case "${mode}" in
    shell|tests) ;;
    --help|-h|help)
        usage
        exit 0
        ;;
    *)
        echo "Error: unknown mode '${mode}'." >&2
        usage >&2
        exit 1
        ;;
esac

PROJECT="twk-test-$(id -u)"
CONFIG_VOLUME="${PROJECT}-config"
DATA_VOLUME="${PROJECT}-data"

if [[ "${mode}" == "tests" ]]; then
    container_command='./tests/run.sh'
else
    container_command='exec bash'
fi

# bats: run the test suite. python3: stub fallback for jq/bc when those aren't
# present. Real jq/bc are installed too and win over the stubs.
docker run --rm -it \
    -v "$PWD:/twk:ro" \
    -v "${CONFIG_VOLUME}:/root/.config/twk" \
    -v "${DATA_VOLUME}:/root/.local/share/twk" \
    -w /twk \
    debian:bookworm-slim \
    bash -c "apt-get update -qq \
        && apt-get install -y -qq curl jq bc fzf bats python3 >/dev/null \
        && ln -sf /twk/bin/twk /usr/local/bin/twk \
        && echo \"[docker-test] Config and session data persist in named volumes (${CONFIG_VOLUME}, ${DATA_VOLUME}).\" \
        && echo \"[docker-test] Run 'docker volume rm ${CONFIG_VOLUME} ${DATA_VOLUME}' on the host to reset state.\" \
        && echo \"[docker-test] Run './tests/run.sh' (or 'bats tests/') to execute the test suite.\" \
        && ${container_command}"
