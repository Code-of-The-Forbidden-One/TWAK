#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly INSTALL_DIR="${HOME}/.local/bin"
readonly MAN_DIR="${HOME}/.local/share/man/man1"

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

    mkdir -p "${MAN_DIR}"
    cp "${SCRIPT_DIR}/man/twk.1" "${MAN_DIR}/twk.1"
    echo "Installed man page to ${MAN_DIR}/twk.1"

    local needs_profile_update=false

    if [[ ":${PATH}:" != *":${INSTALL_DIR}:"* ]]; then
        needs_profile_update=true
    fi

    local current_manpath="${MANPATH:-}"
    if ! man -w twk &> /dev/null 2>&1; then
        needs_profile_update=true
    fi

    if [[ "${needs_profile_update}" == true ]]; then
        echo ""
        echo "Add the following to your shell profile (~/.bashrc or ~/.zshrc):"
        if [[ ":${PATH}:" != *":${INSTALL_DIR}:"* ]]; then
            echo "  export PATH=\"\${HOME}/.local/bin:\${PATH}\""
        fi
        echo "  export MANPATH=\"\${HOME}/.local/share/man:\${MANPATH:-}\""
    fi

    echo ""
    echo "Run 'twk init' to configure your Azure DevOps connection."
}

main "$@"
