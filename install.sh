#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly INSTALL_DIR="${HOME}/.local/bin"

main() {
    mkdir -p "${INSTALL_DIR}"

    local link_path="${INSTALL_DIR}/twk"

    if [[ -L "${link_path}" ]]; then
        rm "${link_path}"
    elif [[ -f "${link_path}" ]]; then
        echo "Error: a regular file already exists at ${link_path}." >&2
        echo "Remove it manually before installing." >&2
        exit 1
    fi

    ln -s "${SCRIPT_DIR}/bin/twk" "${link_path}"
    echo "Installed twk to ${link_path}"

    if [[ ":${PATH}:" != *":${INSTALL_DIR}:"* ]]; then
        echo ""
        echo "Note: ${INSTALL_DIR} is not in your PATH."
        echo "Add this to your shell profile:"
        echo "  export PATH=\"\${HOME}/.local/bin:\${PATH}\""
    fi

    echo ""
    echo "Run 'twk init' to configure your Azure DevOps connection."
}

main "$@"
