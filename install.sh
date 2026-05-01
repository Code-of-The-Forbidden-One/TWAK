#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly INSTALL_DIR="${HOME}/.local/bin"
readonly MAN_DIR="${HOME}/.local/share/man/man1"
readonly PATH_EXPORT='export PATH="${HOME}/.local/bin:${PATH}"'
readonly MANPATH_EXPORT='export MANPATH="${HOME}/.local/share/man:${MANPATH:-}"'

detect_shell_profile() {
    local current_shell
    current_shell="$(basename "${SHELL:-bash}")"

    case "${current_shell}" in
        zsh)  echo "${HOME}/.zshrc" ;;
        *)    echo "${HOME}/.bashrc" ;;
    esac
}

configure_shell_profile() {
    local needs_path=false
    local needs_manpath=false

    if [[ ":${PATH}:" != *":${INSTALL_DIR}:"* ]]; then
        needs_path=true
    fi

    if ! man -w twk &> /dev/null 2>&1; then
        needs_manpath=true
    fi

    if [[ "${needs_path}" == false ]] && [[ "${needs_manpath}" == false ]]; then
        return
    fi

    local profile_file
    profile_file="$(detect_shell_profile)"

    echo ""

    local lines_to_add=()
    if [[ "${needs_path}" == true ]]; then
        lines_to_add+=("${PATH_EXPORT}")
    fi
    if [[ "${needs_manpath}" == true ]]; then
        lines_to_add+=("${MANPATH_EXPORT}")
    fi

    local answer="Y"
    if [[ "${TWK_AUTO_CONFIGURE:-}" != true ]]; then
        read -rp "Add twk to your shell profile (${profile_file})? [Y/n] " answer
        answer="${answer:-Y}"
    fi

    if [[ "${answer}" =~ ^[Yy]$ ]]; then
        echo "" >> "${profile_file}"
        echo "# twk - Time Worked and Committed" >> "${profile_file}"
        for line in "${lines_to_add[@]}"; do
            echo "${line}" >> "${profile_file}"
        done

        echo "Updated ${profile_file}"
        echo "Run 'source ${profile_file}' or open a new terminal to apply."
    else
        echo "Add the following to your shell profile manually:"
        for line in "${lines_to_add[@]}"; do
            echo "  ${line}"
        done
    fi
}

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

    configure_shell_profile

    echo ""
    echo "Run 'twk init' to configure your Azure DevOps connection."
}

main "$@"
