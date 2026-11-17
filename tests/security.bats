#!/usr/bin/env bats
# shellcheck disable=SC2329,SC2034
#   SC2329: stub function definitions are invoked indirectly by SUT
#   SC2034: TWK_* variables are read by the sourced libs
#
# Tests for the audit's security fixes:
#   - a config file is parsed as data and never executed;
#   - config files must be owned by the user and not writable by others;
#   - a project-local config must be trusted before it is used;
#   - sessions are kept per organisation and project;
#   - the credential never appears on curl's command line;
#   - requests retry, report Azure DevOps's reason, and strip control
#     characters from responses;
#   - request bodies are always built as valid JSON.

load 'helpers/setup.bash'

setup() {
    twk_setup_env
    twk_source_libs
    twk_load_stub_path
    require_binary jq
    export TWK_RETRY_BASE_DELAY=0
}

# Writes a valid config file at <path> with any extra lines appended.
_write_config() {
    local path="$1"
    shift
    mkdir -p "$(dirname "${path}")"
    chmod 700 "$(dirname "${path}")"
    {
        echo "TWK_ORGANIZATION=acme"
        echo "TWK_PROJECT=Platform"
        echo "TWK_TEAM="
        echo "TWK_PAT=secretpat"
        echo "TWK_TIME_FIELD_TASK=Custom.TimeSpent"
        printf '%s\n' "$@"
    } > "${path}"
    chmod 600 "${path}"
}

# A curl stand-in that records each call's arguments and stdin, and
# answers with the next status from ${FAKE_CURL_DIR}/statuses ("fail"
# simulates a network error) and the body in ${FAKE_CURL_DIR}/body.
_install_fake_curl() {
    export FAKE_CURL_DIR="${BATS_TEST_TMPDIR}/fake_curl"
    mkdir -p "${FAKE_CURL_DIR}/bin"
    cat > "${FAKE_CURL_DIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "${FAKE_CURL_DIR}/count" 2>/dev/null || echo 0) + 1 ))
echo "${n}" > "${FAKE_CURL_DIR}/count"
printf '%s\n' "$@" > "${FAKE_CURL_DIR}/args.${n}"
cat > "${FAKE_CURL_DIR}/stdin.${n}"
status="$(sed -n "${n}p" "${FAKE_CURL_DIR}/statuses")"
[[ -z "${status}" ]] && status="$(tail -n 1 "${FAKE_CURL_DIR}/statuses")"
if [[ "${status}" == "fail" ]]; then
    echo "curl: (28) Operation timed out" >&2
    exit 28
fi
cat "${FAKE_CURL_DIR}/body" 2>/dev/null
printf '\n%s' "${status}"
EOF
    chmod +x "${FAKE_CURL_DIR}/bin/curl"
    export PATH="${FAKE_CURL_DIR}/bin:${PATH}"
    echo "200" > "${FAKE_CURL_DIR}/statuses"
}

_curl_calls() {
    cat "${FAKE_CURL_DIR}/count" 2>/dev/null || echo 0
}

# -----------------------------------------------------------------------------
# Parsing: data, never code.
# -----------------------------------------------------------------------------

@test "config_parse_file: command substitution in a value is not run" {
    local sentinel="${BATS_TEST_TMPDIR}/pwned"
    _write_config "${TWK_CONFIG_DIR}/config" \
        "TWK_TEAM=\$(touch ${sentinel})" \
        "TWK_STATE_DONE=\`touch ${sentinel}\`"

    config_parse_file "${TWK_CONFIG_DIR}/config"

    [[ ! -e "${sentinel}" ]] || { echo "config ran code"; return 1; }
    [[ "${TWK_TEAM}" == "\$(touch ${sentinel})" ]] || { echo "team: ${TWK_TEAM}"; return 1; }
}

@test "config_parse_file: a bare command line is rejected, not run" {
    local sentinel="${BATS_TEST_TMPDIR}/pwned"
    _write_config "${TWK_CONFIG_DIR}/config" "touch ${sentinel}"

    run config_parse_file "${TWK_CONFIG_DIR}/config"
    assert_status 1
    assert_output_contains "expected KEY=value"
    [[ ! -e "${sentinel}" ]]
}

@test "config_parse_file: unknown keys are ignored with a warning" {
    _write_config "${TWK_CONFIG_DIR}/config" "PATH=/evil" "TWK_UNKNOWN=x"
    local path_before="${PATH}"

    run config_parse_file "${TWK_CONFIG_DIR}/config"
    assert_status 0
    assert_output_contains "ignoring unknown key PATH"
    [[ "${PATH}" == "${path_before}" ]]
}

@test "config_parse_file: comments and blank lines are allowed" {
    _write_config "${TWK_CONFIG_DIR}/config" "" "# a comment" "   "
    config_parse_file "${TWK_CONFIG_DIR}/config"
    [[ "${TWK_ORGANIZATION}" == "acme" ]]
}

@test "config_parse_file: round-trips values written by config_write" {
    local file="${TWK_CONFIG_DIR}/config"
    config_write "${file}" "my org" "Project 'X' \"Y\"" "Team & Co" "p@t\$1" \
        "Custom.TimeSpent" "Custom.FeatureTime" "In Progress" "" "Done; rm -rf" "azcli"

    config_parse_file "${file}"

    [[ "${TWK_ORGANIZATION}" == "my org" ]] || { echo "org: ${TWK_ORGANIZATION}"; return 1; }
    [[ "${TWK_PROJECT}" == "Project 'X' \"Y\"" ]] || { echo "project: ${TWK_PROJECT}"; return 1; }
    [[ "${TWK_TEAM}" == "Team & Co" ]] || { echo "team: ${TWK_TEAM}"; return 1; }
    [[ "${TWK_PAT}" == "p@t\$1" ]] || { echo "pat: ${TWK_PAT}"; return 1; }
    [[ "${TWK_STATE_ON_START}" == "In Progress" ]]
    [[ "${TWK_STATE_ON_PAUSE}" == "" ]]
    [[ "${TWK_STATE_DONE}" == "Done; rm -rf" ]]
    [[ "${TWK_AUTH}" == "azcli" ]]
}

@test "config_parse_file: a config without TWK_AUTH defaults to pat" {
    _write_config "${TWK_CONFIG_DIR}/config"
    config_parse_file "${TWK_CONFIG_DIR}/config"
    [[ "${TWK_AUTH}" == "pat" ]]
    [[ "${TWK_TIME_FIELD_FEATURE}" == "Custom.TimeSpent" ]]
}

@test "config_validate: rejects a time field that is not a reference name" {
    _write_config "${TWK_CONFIG_DIR}/config"
    config_parse_file "${TWK_CONFIG_DIR}/config"
    TWK_TIME_FIELD_TASK="Custom.Time/../System.State"

    run config_validate "${TWK_CONFIG_DIR}/config"
    assert_status 1
    assert_output_contains "TWK_TIME_FIELD_TASK must be a field reference name"
}

@test "config_validate: rejects an unknown auth mode and a missing PAT" {
    _write_config "${TWK_CONFIG_DIR}/config"
    config_parse_file "${TWK_CONFIG_DIR}/config"

    TWK_AUTH="magic"
    run config_validate "${TWK_CONFIG_DIR}/config"
    assert_status 1
    assert_output_contains "TWK_AUTH must be 'pat' or 'azcli'"

    TWK_AUTH="pat"
    TWK_PAT=""
    run config_validate "${TWK_CONFIG_DIR}/config"
    assert_status 1
    assert_output_contains "TWK_PAT is required"
}

# -----------------------------------------------------------------------------
# Ownership, permissions, and trust.
# -----------------------------------------------------------------------------

@test "config_load: refuses a config other users can write to" {
    cd "${BATS_TEST_TMPDIR}"
    _write_config "${TWK_CONFIG_DIR}/config"
    chmod 666 "${TWK_CONFIG_DIR}/config"

    run config_load
    assert_status 1
    assert_output_contains "can be written by other users"
}

@test "config_load: refuses a config in a directory other users can write to" {
    cd "${BATS_TEST_TMPDIR}"
    _write_config "${TWK_CONFIG_DIR}/config"
    chmod 777 "${TWK_CONFIG_DIR}"

    run config_load
    assert_status 1
    assert_output_contains "can be written by other users"
}

@test "config_load: an untrusted local config is refused" {
    local project="${BATS_TEST_TMPDIR}/project"
    _write_config "${project}/.twk/config"
    mkdir -p "${project}/src"
    cd "${project}/src"

    run config_load
    assert_status 1
    assert_output_contains "is not trusted"
    assert_output_contains "twk trust"
}

@test "config_load: a trusted local config is used" {
    local project="${BATS_TEST_TMPDIR}/project"
    _write_config "${project}/.twk/config"
    cd "${project}"
    config_trust "${project}/.twk/config"

    config_load
    [[ "${TWK_ORGANIZATION}" == "acme" ]]
}

@test "config_load: a trusted local config that changes must be trusted again" {
    local project="${BATS_TEST_TMPDIR}/project"
    _write_config "${project}/.twk/config"
    cd "${project}"
    config_trust "${project}/.twk/config"
    echo "TWK_TEAM=Other" >> "${project}/.twk/config"

    run config_load
    assert_status 1
    assert_output_contains "is not trusted"
}

@test "config_trust: replaces the earlier record for the same file" {
    local project="${BATS_TEST_TMPDIR}/project"
    _write_config "${project}/.twk/config"
    config_trust "${project}/.twk/config"
    echo "TWK_TEAM=Other" >> "${project}/.twk/config"
    config_trust "${project}/.twk/config"

    [[ "$(grep -c . "$(config_trust_file)")" -eq 1 ]]
    config_is_trusted "${project}/.twk/config"
}

@test "cmd_trust: shows the config with the PAT masked, then trusts it" {
    local project="${BATS_TEST_TMPDIR}/project"
    _write_config "${project}/.twk/config"
    cd "${project}"

    run cmd_trust --yes
    assert_status 0
    assert_output_contains "TWK_PAT=********"
    assert_output_not_contains "secretpat"
    assert_output_contains "Trusted ${project}/.twk/config"
    config_is_trusted "${project}/.twk/config"
}

@test "cmd_trust: answering no leaves the config untrusted" {
    local project="${BATS_TEST_TMPDIR}/project"
    _write_config "${project}/.twk/config"
    cd "${project}"

    run cmd_trust <<< "n"
    assert_status 1
    run config_is_trusted "${project}/.twk/config"
    assert_status 1
}

@test "bin/twk: a planted .twk/config in a parent directory runs nothing" {
    local sentinel="${BATS_TEST_TMPDIR}/pwned"
    local evil="${BATS_TEST_TMPDIR}/evil"
    mkdir -p "${evil}/.twk" "${evil}/sub"
    printf 'touch %s\nTWK_ORGANIZATION=$(touch %s)\n' "${sentinel}" "${sentinel}" \
        > "${evil}/.twk/config"
    chmod 600 "${evil}/.twk/config"
    cd "${evil}/sub"

    run "${TWK_REPO}/bin/twk" status
    assert_status 1
    [[ ! -e "${sentinel}" ]] || { echo "the planted config ran"; return 1; }
    assert_output_contains "is not trusted"
}

# -----------------------------------------------------------------------------
# Sessions per organisation and project.
# -----------------------------------------------------------------------------

@test "config_scope_data_dir: different organisations get different stores" {
    export TWK_DATA_ROOT="${BATS_TEST_TMPDIR}/root"
    TWK_ORGANIZATION="Acme" TWK_PROJECT="Platform"
    config_scope_data_dir
    local first="${TWK_DATA_DIR}"

    TWK_ORGANIZATION="Other" TWK_PROJECT="Platform"
    config_scope_data_dir

    [[ "${first}" != "${TWK_DATA_DIR}" ]]
    [[ "${first}" == "${TWK_DATA_ROOT}/scopes/acme/platform" ]] || { echo "${first}"; return 1; }
}

@test "config_scope_data_dir: names are encoded, so they cannot escape the store" {
    export TWK_DATA_ROOT="${BATS_TEST_TMPDIR}/root"
    TWK_ORGANIZATION="../../etc" TWK_PROJECT="a/b"
    config_scope_data_dir
    [[ "${TWK_DATA_DIR}" == "${TWK_DATA_ROOT}/scopes/..%2F..%2Fetc/a%2Fb" ]] \
        || { echo "${TWK_DATA_DIR}"; return 1; }
}

@test "session_migrate_legacy: moves the old shared store into the current scope" {
    export TWK_DATA_ROOT="${BATS_TEST_TMPDIR}/root"
    local legacy="${TWK_DATA_ROOT}/sessions"
    mkdir -p "${legacy}/committed"
    echo "start|1" > "${legacy}/42.session"
    echo '{"title":"t"}' > "${legacy}/42.meta"
    echo "start|1" > "${legacy}/committed/7_100.session"

    TWK_ORGANIZATION="acme" TWK_PROJECT="platform"
    run config_scope_data_dir
    assert_status 0
    assert_output_contains "moved 1 uncommitted session(s)"

    local scope="${TWK_DATA_ROOT}/scopes/acme/platform"
    assert_file_exists "${scope}/42.session"
    assert_file_exists "${scope}/42.meta"
    assert_file_exists "${scope}/committed/7_100.session"
    assert_file_not_exists "${legacy}"
}

# -----------------------------------------------------------------------------
# The request layer.
# -----------------------------------------------------------------------------

@test "azdo_api_request: the PAT is passed on stdin, never on curl's command line" {
    _install_fake_curl
    TWK_AUTH=pat TWK_PAT="supersecretpat"

    azdo_api_request GET "https://dev.azure.com/acme/_apis/projects" > /dev/null

    local encoded
    encoded="$(printf '%s' ":supersecretpat" | base64 | tr -d '\n')"
    ! grep -q "supersecretpat\|${encoded}" "${FAKE_CURL_DIR}/args.1" \
        || { echo "credential on the command line"; return 1; }
    grep -qF "header = \"Authorization: Basic ${encoded}\"" "${FAKE_CURL_DIR}/stdin.1"
    grep -qx -- "--config" "${FAKE_CURL_DIR}/args.1"
}

@test "azdo_api_request: TWK_AUTH=azcli sends a Bearer token and asks az once" {
    _install_fake_curl
    cat > "${FAKE_CURL_DIR}/bin/az" <<EOF
#!/usr/bin/env bash
echo x >> "${FAKE_CURL_DIR}/az_calls"
echo "entra-token"
EOF
    chmod +x "${FAKE_CURL_DIR}/bin/az"
    TWK_AUTH=azcli TWK_PAT=""
    export TWK_TOKEN_CACHE="${BATS_TEST_TMPDIR}/token"

    azdo_api_request GET "https://dev.azure.com/acme/_apis/a" > /dev/null
    azdo_api_request GET "https://dev.azure.com/acme/_apis/b" > /dev/null

    grep -qF 'header = "Authorization: Bearer entra-token"' "${FAKE_CURL_DIR}/stdin.2"
    [[ "$(grep -c . "${FAKE_CURL_DIR}/az_calls")" -eq 1 ]]
}

@test "azdo_api_request: TWK_AUTH=azcli explains when az is not signed in" {
    _install_fake_curl
    printf '#!/bin/sh\nexit 1\n' > "${FAKE_CURL_DIR}/bin/az"
    chmod +x "${FAKE_CURL_DIR}/bin/az"
    TWK_AUTH=azcli

    run azdo_api_request GET "https://dev.azure.com/acme/_apis/a"
    assert_status 1
    assert_output_contains "az login"
    [[ "$(_curl_calls)" -eq 0 ]]
}

@test "azdo_api_request: retries 429 and succeeds" {
    _install_fake_curl
    printf '429\n429\n200\n' > "${FAKE_CURL_DIR}/statuses"
    echo '{"ok":true}' > "${FAKE_CURL_DIR}/body"
    TWK_AUTH=pat TWK_PAT=p

    run azdo_api_request PATCH "https://dev.azure.com/acme/p/_apis/wit/workitems/1" '[]'
    assert_status 0
    assert_output_contains '"ok":true'
    [[ "$(_curl_calls)" -eq 3 ]]
}

@test "azdo_api_request: retries a read after a network failure" {
    _install_fake_curl
    printf 'fail\n200\n' > "${FAKE_CURL_DIR}/statuses"
    TWK_AUTH=pat TWK_PAT=p

    run azdo_api_request GET "https://dev.azure.com/acme/_apis/projects"
    assert_status 0
    [[ "$(_curl_calls)" -eq 2 ]]
}

@test "azdo_api_request: never repeats a write after a 500 (outcome unknown, rc=2)" {
    _install_fake_curl
    echo "500" > "${FAKE_CURL_DIR}/statuses"
    TWK_AUTH=pat TWK_PAT=p

    run azdo_api_request POST "https://dev.azure.com/acme/p/_apis/wit/workitems/1/comments" '{}'
    assert_status 2
    [[ "$(_curl_calls)" -eq 1 ]]
}

@test "azdo_api_request: reports the HTTP status and Azure DevOps's message (rc=1)" {
    _install_fake_curl
    echo "400" > "${FAKE_CURL_DIR}/statuses"
    echo '{"message":"TF401289: The test operation failed."}' > "${FAKE_CURL_DIR}/body"
    TWK_AUTH=pat TWK_PAT=p

    run azdo_api_request PATCH "https://dev.azure.com/acme/p/_apis/wit/workitems/1?api-version=7.1" '[]'
    assert_status 1
    assert_output_contains "HTTP 400"
    assert_output_contains "TF401289: The test operation failed."
    assert_output_not_contains "api-version"
}

@test "azdo_api_request: explains a 401" {
    _install_fake_curl
    echo "401" > "${FAKE_CURL_DIR}/statuses"
    TWK_AUTH=pat TWK_PAT=p

    run azdo_api_request GET "https://dev.azure.com/acme/_apis/projects"
    assert_status 1
    assert_output_contains "authentication failed"
}

@test "azdo_api_request: strips terminal control characters from responses" {
    _install_fake_curl
    printf '%s' '{"value":[{"title":"ok\u001b]0;pwned\u0007 title\u009b31m","desc":"line1\nline2\tx"}]}' \
        > "${FAKE_CURL_DIR}/body"
    TWK_AUTH=pat TWK_PAT=p

    local out title desc
    out="$(azdo_api_request GET "https://dev.azure.com/acme/_apis/x")"
    title="$(printf '%s' "${out}" | jq -r '.value[0].title')"
    desc="$(printf '%s' "${out}" | jq -r '.value[0].desc')"

    [[ "${title}" == "ok]0;pwned title31m" ]] || { echo "title: $(printf '%q' "${title}")"; return 1; }
    [[ "${desc}" == $'line1\nline2\tx' ]] || { echo "desc: $(printf '%q' "${desc}")"; return 1; }
}

@test "azdo_fetch_batch: splits more than 200 IDs into requests and merges the pages" {
    TWK_ORGANIZATION=acme TWK_PROJECT=p
    azdo_api_request() {
        local n
        n="$(jq '.ids | length' <<< "$3")"
        echo "${n}" >> "${BATS_TEST_TMPDIR}/sizes"
        jq -c '{value: [.ids[] | {id: .}]}' <<< "$3"
    }

    local ids out
    ids="$(jq -nc '[range(1; 451)]')"
    out="$(azdo_fetch_batch "${ids}" '["System.Id"]')"

    [[ "$(cat "${BATS_TEST_TMPDIR}/sizes" | tr '\n' ' ')" == "200 200 50 " ]] \
        || { echo "sizes: $(cat "${BATS_TEST_TMPDIR}/sizes")"; return 1; }
    [[ "$(jq '.count' <<< "${out}")" -eq 450 ]]
    [[ "$(jq '.value | map(.id) | unique | length' <<< "${out}")" -eq 450 ]]
}

@test "azdo_update_state: a state containing quotes still makes valid JSON" {
    TWK_ORGANIZATION=acme TWK_PROJECT=p
    azdo_api_request() { printf '%s' "$3" > "${BATS_TEST_TMPDIR}/body"; }

    azdo_update_state 7 'Done", "path": "/fields/System.AssignedTo'

    jq -e 'length == 1 and .[0].path == "/fields/System.State"' \
        "${BATS_TEST_TMPDIR}/body" > /dev/null
}

@test "azdo_update_time_spent: tests the revision before replacing" {
    TWK_ORGANIZATION=acme TWK_PROJECT=p
    azdo_api_request() { printf '%s' "$3" > "${BATS_TEST_TMPDIR}/body"; }

    azdo_update_time_spent 7 0.50 Custom.TimeSpent 12

    jq -e '.[0] == {op: "test", path: "/rev", value: 12}
        and .[1] == {op: "replace", path: "/fields/Custom.TimeSpent", value: 0.5}' \
        "${BATS_TEST_TMPDIR}/body" > /dev/null
}

@test "azdo_update_time_spent: refuses an hours value that is not a JSON number" {
    TWK_ORGANIZATION=acme TWK_PROJECT=p
    azdo_api_request() { : > "${BATS_TEST_TMPDIR}/called"; }

    run azdo_update_time_spent 7 .50 Custom.TimeSpent
    assert_status 1
    assert_file_not_exists "${BATS_TEST_TMPDIR}/called"
}
