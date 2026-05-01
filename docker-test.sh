#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

PROJECT="twk-test-$(id -u)"
CONFIG_VOLUME="${PROJECT}-config"
DATA_VOLUME="${PROJECT}-data"

docker run --rm -it \
    -v "$PWD:/twk:ro" \
    -v "${CONFIG_VOLUME}:/root/.config/twk" \
    -v "${DATA_VOLUME}:/root/.local/share/twk" \
    -w /twk \
    debian:bookworm-slim \
    bash -c "apt-get update -qq \
        && apt-get install -y -qq curl jq bc fzf >/dev/null \
        && ln -sf /twk/bin/twk /usr/local/bin/twk \
        && echo \"[docker-test] Config and session data persist in named volumes (${CONFIG_VOLUME}, ${DATA_VOLUME}).\" \
        && echo \"[docker-test] Run 'docker volume rm ${CONFIG_VOLUME} ${DATA_VOLUME}' on the host to reset state.\" \
        && exec bash"
