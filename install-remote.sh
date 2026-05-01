#!/usr/bin/env bash
set -euo pipefail

readonly REPO_URL="https://github.com/Code-of-The-Forbidden-One/TWAK.git"
readonly INSTALL_LOCATION="${HOME}/.local/share/twk"

main() {
    for dep in git curl jq bc; do
        if ! command -v "${dep}" &> /dev/null; then
            echo "Error: '${dep}' is required but not found." >&2
            exit 1
        fi
    done

    if [[ -d "${INSTALL_LOCATION}" ]]; then
        echo "Updating twk..."
        git -C "${INSTALL_LOCATION}" pull --ff-only
    else
        echo "Installing twk..."
        git clone "${REPO_URL}" "${INSTALL_LOCATION}"
    fi

    chmod +x "${INSTALL_LOCATION}/bin/twk"
    chmod +x "${INSTALL_LOCATION}/install.sh"

    "${INSTALL_LOCATION}/install.sh"
}

main "$@"
