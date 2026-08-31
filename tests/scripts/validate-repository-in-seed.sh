#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly SUBJECT="${ROOT_DIR}/scripts/validate-repository-in-seed.sh"

# shellcheck source=../lib/assertions.sh
source "${ROOT_DIR}/tests/lib/assertions.sh"

fixture_root=
stub_directory=
repository_root=
package_file=
installed_path=
missing_path=
command_log=
pacman_config_log=

cleanup() {
    if [[ -n "${fixture_root}" ]]; then
        rm -rf -- "${fixture_root}"
    fi
}

create_pacman_stub() {
    mkdir -p "${stub_directory}"

    cat > "${stub_directory}/pacman" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

original_arguments="$*"
printf '%s\n' "${original_arguments}" >> "${COMMAND_LOG}"

if [[ "${1:-}" == --config ]]; then
    [[ "$#" -ge 3 ]]
    cp -- "$2" "${PACMAN_CONFIG_LOG}"
    shift 2
fi

case "${1:-}" in
    -Qp)
        printf 'sample-package 1.0-1\n'
        ;;

    -Sy)
        ;;

    -Si)
        printf '%s\n' \
            "Repository      : ${PACMAN_REPORTED_REPOSITORY:-sample-repository}" \
            'Name            : sample-package' \
            'Version         : 1.0-1'
        ;;

    -S)
        ;;

    -Q)
        if [[ "${PACMAN_MODE:-success}" == version-mismatch ]]; then
            printf 'sample-package 9.9-9\n'
        else
            printf 'sample-package 1.0-1\n'
        fi
        ;;

    -Qlq)
        printf '/\n'

        if [[ "${PACMAN_MODE:-success}" == missing-path ]]; then
            printf '%s\n' "${MISSING_PATH}"
        else
            printf '%s\n' "${INSTALLED_PATH}"
        fi
        ;;

    *)
        printf 'unexpected pacman invocation: %s\n' \
            "${original_arguments}" \
            >&2
        exit 2
        ;;
esac
STUB

    chmod 0755 "${stub_directory}/pacman"
}

create_fixture() {
    fixture_root="$(mktemp -d)"
    stub_directory="${fixture_root}/bin"
    repository_root="${fixture_root}/repository-root"
    package_file="${fixture_root}/sample-package-1.0-1-x86_64.pkg.tar.zst"
    installed_path="${fixture_root}/installed-file"
    missing_path="${fixture_root}/missing-installed-file"
    command_log="${fixture_root}/commands.log"
    pacman_config_log="${fixture_root}/pacman.conf"

    mkdir -p \
        "${repository_root}/sample-repository/x86_64"

    : > "${package_file}"
    : > "${installed_path}"
    : > "${command_log}"
    : > "${pacman_config_log}"

    create_pacman_stub
}

reset_logs() {
    : > "${command_log}"
    : > "${pacman_config_log}"
}

run_subject() {
    run_command env \
        PATH="${stub_directory}:${PATH}" \
        COMMAND_LOG="${command_log}" \
        PACMAN_CONFIG_LOG="${pacman_config_log}" \
        PACMAN_MODE="${PACMAN_MODE:-success}" \
        PACMAN_REPORTED_REPOSITORY="${PACMAN_REPORTED_REPOSITORY:-sample-repository}" \
        INSTALLED_PATH="${installed_path}" \
        MISSING_PATH="${missing_path}" \
        bash "${SUBJECT}" \
        "$@"
}

test_requires_all_arguments() {
    run_subject

    assert_status 64
    assert_contains 'Usage:'
}

test_rejects_invalid_repository() {
    run_subject \
        ../sample-repository \
        x86_64 \
        "${repository_root}" \
        "${package_file}"

    assert_status 64
    assert_contains 'invalid repository name'
}

test_rejects_invalid_architecture() {
    run_subject \
        sample-repository \
        ../x86_64 \
        "${repository_root}" \
        "${package_file}"

    assert_status 64
    assert_contains 'invalid architecture name'
}

test_requires_absolute_repository_root() {
    run_subject \
        sample-repository \
        x86_64 \
        relative-repository-root \
        "${package_file}"

    assert_status 64
    assert_contains 'repository root must be absolute'
}

test_rejects_missing_package_file() {
    run_subject \
        sample-repository \
        x86_64 \
        "${repository_root}" \
        "${fixture_root}/missing.pkg.tar.zst"

    assert_status 66
    assert_contains 'package file not found'
}

test_rejects_unexpected_repository() {
    reset_logs

    PACMAN_REPORTED_REPOSITORY=other-repository run_subject \
        sample-repository \
        x86_64 \
        "${repository_root}" \
        "${package_file}"

    assert_status 1
    assert_contains 'unexpected repository'
}

test_rejects_version_mismatch() {
    reset_logs

    PACMAN_MODE=version-mismatch run_subject \
        sample-repository \
        x86_64 \
        "${repository_root}" \
        "${package_file}"

    assert_status 1
    assert_contains 'installed package identity mismatch'
}

test_rejects_missing_installed_path() {
    reset_logs

    PACMAN_MODE=missing-path run_subject \
        sample-repository \
        x86_64 \
        "${repository_root}" \
        "${package_file}"

    assert_status 1
    assert_contains 'installed package path is missing'
}

test_validates_through_repository() {
    reset_logs

    run_subject \
        sample-repository \
        x86_64 \
        "${repository_root}" \
        "${package_file}"

    assert_status 0
    assert_contains 'Pacman repository validation passed'

    grep -Fq \
        'Architecture = x86_64' \
        "${pacman_config_log}" \
        || fail 'target architecture is missing from pacman configuration'

    grep -Fq \
        'SigLevel = Optional TrustAll' \
        "${pacman_config_log}" \
        || fail 'temporary bootstrap signature policy is missing'

    grep -Fq \
        '[sample-repository]' \
        "${pacman_config_log}" \
        || fail 'repository section is missing'

    grep -Fq \
        "Server = file://${repository_root}/\$repo/\$arch" \
        "${pacman_config_log}" \
        || fail 'local file repository URL is missing'

    grep -Fq -- \
        '-Sy --noconfirm' \
        "${command_log}" \
        || fail 'repository databases were not synchronized with pacman -Sy'

    grep -Fq -- \
        '-Si sample-repository/sample-package' \
        "${command_log}" \
        || fail 'package was not discovered through the repository'

    grep -Fq -- \
        '-S --noconfirm --needed sample-repository/sample-package' \
        "${command_log}" \
        || fail 'package was not installed through the repository'

    grep -Fq -- \
        '-Q sample-package' \
        "${command_log}" \
        || fail 'installed package identity was not checked'

    if grep -Eq '(^|[[:space:]])-U([[:space:]]|$)' "${command_log}"; then
        fail 'loose package installation with pacman -U was used'
    fi
}

main() {
    trap cleanup EXIT

    create_fixture

    test_requires_all_arguments
    test_rejects_invalid_repository
    test_rejects_invalid_architecture
    test_requires_absolute_repository_root
    test_rejects_missing_package_file
    test_rejects_unexpected_repository
    test_rejects_version_mismatch
    test_rejects_missing_installed_path
    test_validates_through_repository

    printf 'PASS: pacman repository validation\n'
}

main "$@"
