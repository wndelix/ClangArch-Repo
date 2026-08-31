#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly SUBJECT="${ROOT_DIR}/scripts/build-package-in-seed.sh"

# shellcheck source=../lib/assertions.sh
source "${ROOT_DIR}/tests/lib/assertions.sh"

fixture_root=
fixture_workspace=
fixture_sources=
output_selection_harness=
installation_validation_harness=
pacman_stub_directory=
seed_pacman_configuration=
validated_pacman_configuration=
installation_package_file=
installed_package_path=
expected_main_package=
expected_debug_package=

cleanup() {
    if [[ -n "${fixture_root}" ]]; then
        rm -rf -- "${fixture_root}"
    fi
}

create_output_selection_harness() {
    head -n -1 "${SUBJECT}" > "${output_selection_harness}"

    cat >> "${output_selection_harness}" <<'HARNESS'

expected_package_files=(
    "${EXPECTED_MAIN_PACKAGE}"
    "${EXPECTED_DEBUG_PACKAGE}"
)
produced_package_files=()

collect_produced_packages \
    expected_package_files \
    produced_package_files

printf '%s\n' "${produced_package_files[@]}"
HARNESS

    chmod 0755 "${output_selection_harness}"
}

create_installation_validation_harness() {
    head -n -1 "${SUBJECT}" > "${installation_validation_harness}"

    cat >> "${installation_validation_harness}" <<'HARNESS'

validate_installed_packages "${INSTALLATION_PACKAGE_FILE}"
HARNESS

    chmod 0755 "${installation_validation_harness}"
}

create_pacman_stub() {
    mkdir -p "${pacman_stub_directory}"

    cat > "${pacman_stub_directory}/pacman" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

pacman_configuration=

if [[ "${1:-}" == --config ]]; then
    pacman_configuration="$2"
    cp -- "${pacman_configuration}" "${VALIDATED_PACMAN_CONFIGURATION}"
    shift 2
fi

case "${1:-}" in
    -U)
        if [[ -n "${pacman_configuration}" ]] \
            && ! grep -Eq \
                '^[[:space:]]*NoExtract[[:space:]]*=' \
                "${pacman_configuration}"
        then
            : > "${INSTALLED_PACKAGE_PATH}"
        fi
        ;;

    -Qp)
        printf 'sample-package 1.0-1\n'
        ;;

    -Q)
        printf 'sample-package 1.0-1\n'
        ;;

    -Qlq)
        printf '/\n%s\n' "${INSTALLED_PACKAGE_PATH}"
        ;;

    *)
        printf 'unexpected pacman invocation: %s\n' "$*" >&2
        exit 2
        ;;
esac
STUB

    chmod 0755 "${pacman_stub_directory}/pacman"
}

create_fixture() {
    fixture_root="$(mktemp -d)"
    fixture_workspace="${fixture_root}/workspace"
    fixture_sources="${fixture_root}/package sources"
    output_selection_harness="${fixture_root}/output-selection-harness.sh"
    installation_validation_harness="${fixture_root}/installation-validation-harness.sh"
    pacman_stub_directory="${fixture_root}/pacman-bin"
    seed_pacman_configuration="${fixture_root}/seed-pacman.conf"
    validated_pacman_configuration="${fixture_root}/validated-pacman.conf"
    installation_package_file="${fixture_root}/sample-package-1.0-1-x86_64.pkg.tar.zst"
    installed_package_path="${fixture_root}/installed-package-path"

    mkdir -p \
        "${fixture_workspace}" \
        "${fixture_sources}/sample-package"

    : > "${fixture_sources}/sample-package/PKGBUILD"
    : > "${installation_package_file}"

    cat > "${seed_pacman_configuration}" <<'PACMAN_CONFIG'
[options]
Architecture = x86_64
NoExtract = usr/share/man/* usr/share/info/*
#NoExtract = commented-directive-must-remain
PACMAN_CONFIG

    local package_output

    package_output="${fixture_workspace}/out/packages"
    package_output+="/sample-repository/sample-package"

    mkdir -p "${package_output}"

    expected_main_package="${package_output}/sample-package-1.0-1-x86_64.pkg.tar.zst"
    expected_debug_package="${package_output}/sample-package-debug-1.0-1-x86_64.pkg.tar.zst"

    create_output_selection_harness
    create_installation_validation_harness
    create_pacman_stub
}

run_subject() {
    run_command env \
        ARCH_SNAPSHOT=2026/08/23 \
        TARGET_ARCH=x86_64 \
        BUILD_REPOSITORY=sample-repository \
        BUILD_PACKAGE=sample-package \
        HOST_UID="$(id -u)" \
        HOST_GID="$(id -g)" \
        WORKSPACE_OVERRIDE="${fixture_workspace}" \
        PACKAGE_SOURCES_OVERRIDE="${fixture_sources}" \
        bash "${SUBJECT}"
}

run_installation_validation_harness() {
    run_command env \
        PATH="${pacman_stub_directory}:${PATH}" \
        PACMAN_CONFIGURATION_OVERRIDE="${seed_pacman_configuration}" \
        VALIDATED_PACMAN_CONFIGURATION="${validated_pacman_configuration}" \
        INSTALLATION_PACKAGE_FILE="${installation_package_file}" \
        INSTALLED_PACKAGE_PATH="${installed_package_path}" \
        bash "${installation_validation_harness}"
}

test_requires_snapshot() {
    run_command env \
        -u ARCH_SNAPSHOT \
        TARGET_ARCH=x86_64 \
        BUILD_REPOSITORY=sample-repository \
        BUILD_PACKAGE=sample-package \
        HOST_UID="$(id -u)" \
        HOST_GID="$(id -g)" \
        WORKSPACE_OVERRIDE="${fixture_workspace}" \
        PACKAGE_SOURCES_OVERRIDE="${fixture_sources}" \
        bash "${SUBJECT}"

    assert_status 64
    assert_contains 'ARCH_SNAPSHOT is required'
}

test_requires_target_architecture() {
    run_command env \
        -u TARGET_ARCH \
        ARCH_SNAPSHOT=2026/08/23 \
        BUILD_REPOSITORY=sample-repository \
        BUILD_PACKAGE=sample-package \
        HOST_UID="$(id -u)" \
        HOST_GID="$(id -g)" \
        WORKSPACE_OVERRIDE="${fixture_workspace}" \
        PACKAGE_SOURCES_OVERRIDE="${fixture_sources}" \
        bash "${SUBJECT}"

    assert_status 64
    assert_contains 'TARGET_ARCH is required'
}

test_rejects_invalid_repository() {
    run_command env \
        ARCH_SNAPSHOT=2026/08/23 \
        TARGET_ARCH=x86_64 \
        BUILD_REPOSITORY=../sample-repository \
        BUILD_PACKAGE=sample-package \
        HOST_UID="$(id -u)" \
        HOST_GID="$(id -g)" \
        WORKSPACE_OVERRIDE="${fixture_workspace}" \
        PACKAGE_SOURCES_OVERRIDE="${fixture_sources}" \
        bash "${SUBJECT}"

    assert_status 64
    assert_contains 'invalid repository name'
}

test_rejects_invalid_package() {
    run_command env \
        ARCH_SNAPSHOT=2026/08/23 \
        TARGET_ARCH=x86_64 \
        BUILD_REPOSITORY=sample-repository \
        BUILD_PACKAGE=../sample-package \
        HOST_UID="$(id -u)" \
        HOST_GID="$(id -g)" \
        WORKSPACE_OVERRIDE="${fixture_workspace}" \
        PACKAGE_SOURCES_OVERRIDE="${fixture_sources}" \
        bash "${SUBJECT}"

    assert_status 64
    assert_contains 'invalid package name'
}

test_rejects_non_numeric_uid() {
    run_command env \
        ARCH_SNAPSHOT=2026/08/23 \
        TARGET_ARCH=x86_64 \
        BUILD_REPOSITORY=sample-repository \
        BUILD_PACKAGE=sample-package \
        HOST_UID=invalid \
        HOST_GID="$(id -g)" \
        WORKSPACE_OVERRIDE="${fixture_workspace}" \
        PACKAGE_SOURCES_OVERRIDE="${fixture_sources}" \
        bash "${SUBJECT}"

    assert_status 64
    assert_contains 'HOST_UID must be numeric'
}

test_rejects_non_numeric_gid() {
    run_command env \
        ARCH_SNAPSHOT=2026/08/23 \
        TARGET_ARCH=x86_64 \
        BUILD_REPOSITORY=sample-repository \
        BUILD_PACKAGE=sample-package \
        HOST_UID="$(id -u)" \
        HOST_GID=invalid \
        WORKSPACE_OVERRIDE="${fixture_workspace}" \
        PACKAGE_SOURCES_OVERRIDE="${fixture_sources}" \
        bash "${SUBJECT}"

    assert_status 64
    assert_contains 'HOST_GID must be numeric'
}

test_rejects_missing_pkgbuild() {
    run_command env \
        ARCH_SNAPSHOT=2026/08/23 \
        TARGET_ARCH=x86_64 \
        BUILD_REPOSITORY=sample-repository \
        BUILD_PACKAGE=missing-package \
        HOST_UID="$(id -u)" \
        HOST_GID="$(id -g)" \
        WORKSPACE_OVERRIDE="${fixture_workspace}" \
        PACKAGE_SOURCES_OVERRIDE="${fixture_sources}" \
        bash "${SUBJECT}"

    assert_status 66
    assert_contains 'PKGBUILD not found'
}

test_rejects_non_empty_output() {
    local output_directory

    output_directory="${fixture_workspace}/out/packages"
    output_directory+="/sample-repository/sample-package"

    mkdir -p "${output_directory}"
    : > "${output_directory}/stale-package.pkg.tar.zst"

    run_subject

    assert_status 73
    assert_contains 'package output is not empty'

    rm -f -- "${output_directory}/stale-package.pkg.tar.zst"
}

test_accepts_absent_optional_predicted_output() {
    : > "${expected_main_package}"

    run_command env \
        BUILD_REPOSITORY=sample-repository \
        BUILD_PACKAGE=sample-package \
        WORKSPACE_OVERRIDE="${fixture_workspace}" \
        PACKAGE_SOURCES_OVERRIDE="${fixture_sources}" \
        EXPECTED_MAIN_PACKAGE="${expected_main_package}" \
        EXPECTED_DEBUG_PACKAGE="${expected_debug_package}" \
        bash "${output_selection_harness}"

    assert_status 0
    assert_contains "${expected_main_package}"
    assert_not_contains "${expected_debug_package}"

    rm -f -- "${expected_main_package}"
}

test_installs_paths_excluded_by_seed_noextract() {
    rm -f -- \
        "${installed_package_path}" \
        "${validated_pacman_configuration}"

    run_installation_validation_harness

    assert_status 0

    [[ -e "${installed_package_path}" ]] \
        || fail 'package path excluded by the seed NoExtract was not installed'

    grep -Fq \
        'Architecture = x86_64' \
        "${validated_pacman_configuration}" \
        || fail 'validation pacman configuration lost seed settings'

    if grep -Eq \
        '^[[:space:]]*NoExtract[[:space:]]*=' \
        "${validated_pacman_configuration}"
    then
        fail 'validation pacman configuration retained an active NoExtract'
    fi
}

test_requires_root_after_input_validation() {
    if (( EUID == 0 )); then
        return
    fi

    run_subject

    assert_status 77
    assert_contains 'must run as root'
}

main() {
    trap cleanup EXIT
    create_fixture

    test_requires_snapshot
    test_requires_target_architecture
    test_rejects_invalid_repository
    test_rejects_invalid_package
    test_rejects_non_numeric_uid
    test_rejects_non_numeric_gid
    test_rejects_missing_pkgbuild
    test_rejects_non_empty_output
    test_accepts_absent_optional_predicted_output
    test_installs_paths_excluded_by_seed_noextract
    test_requires_root_after_input_validation

    printf 'PASS: build-package-in-seed input validation\n'
}

main "$@"
