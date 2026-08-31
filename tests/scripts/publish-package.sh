#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly SUBJECT="${ROOT_DIR}/scripts/publish-package.sh"
readonly TEST_REPOSITORY=sample-repository
readonly TEST_PACKAGE=sample-package

# shellcheck source=../lib/assertions.sh
source "${ROOT_DIR}/tests/lib/assertions.sh"

fixture_root=
stub_directory=
package_sources_root=
binary_repository_root=
package_sources_commit=
package_output_directory=
package_output=
command_log=

cleanup() {
    rm -rf -- \
        "${ROOT_DIR}/out/build/${TEST_REPOSITORY}/${TEST_PACKAGE}" \
        "${ROOT_DIR}/out/packages/${TEST_REPOSITORY}/${TEST_PACKAGE}"

    if [[ -n "${fixture_root}" ]]; then
        rm -rf -- "${fixture_root}"
    fi
}

commit_fixture_repository() {
    local repository_root="$1"
    local message="$2"

    git -C "${repository_root}" \
        -c user.name='Test Builder' \
        -c user.email='test@example.invalid' \
        commit \
        --quiet \
        -m "${message}"
}

create_container_engine_stub() {
    cat > "${stub_directory}/container-engine" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${COMMAND_LOG}"

case "${1:-}" in
    pull)
        exit
        ;;

    run)
        ;;
esac

case "$*" in
    *'/work/scripts/build-package-in-seed.sh'*)
        if [[ "${ENGINE_MODE:-success}" != missing-output ]]; then
            mkdir -p "$(dirname "${FAKE_PACKAGE_OUTPUT}")"
            : > "${FAKE_PACKAGE_OUTPUT}"
        fi
        ;;

    *'/work/scripts/update-repository-in-seed.sh'*)
        if [[ "${ENGINE_MODE:-success}" == update-fail ]]; then
            exit 42
        fi

        host_repository=

        for argument in "$@"; do
            case "${argument}" in
                *:/repository)
                    host_repository="${argument%:/repository}"
                    ;;
            esac
        done

        [[ -n "${host_repository}" ]]

        staged_architecture_directory="${host_repository}/${TEST_REPOSITORY}/x86_64"
        mkdir -p "${staged_architecture_directory}"

        cp -- \
            "${FAKE_PACKAGE_OUTPUT}" \
            "${staged_architecture_directory}/"

        printf 'database\n' \
            > "${staged_architecture_directory}/${TEST_REPOSITORY}.db"

        printf 'database\n' \
            > "${staged_architecture_directory}/${TEST_REPOSITORY}.db.tar.gz"

        printf 'files database\n' \
            > "${staged_architecture_directory}/${TEST_REPOSITORY}.files"

        printf 'files database\n' \
            > "${staged_architecture_directory}/${TEST_REPOSITORY}.files.tar.gz"
        ;;

    *'/work/scripts/validate-repository-in-seed.sh'*)
        if [[ "${ENGINE_MODE:-success}" == validation-fail ]]; then
            exit 43
        fi
        ;;
esac
STUB

    chmod 0755 "${stub_directory}/container-engine"
}

create_rsync_stub() {
    cat > "${stub_directory}/rsync" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

printf 'rsync %s\n' "$*" >> "${COMMAND_LOG}"

delete_destination=false
declare -a paths=()

for argument in "$@"; do
    case "${argument}" in
        --archive)
            ;;
        --delete)
            delete_destination=true
            ;;
        --*)
            ;;
        *)
            paths+=("${argument}")
            ;;
    esac
done

(( "${#paths[@]}" == 2 ))

source_directory="${paths[0]%/}"
destination_directory="${paths[1]%/}"

if [[ "${delete_destination}" == true ]]; then
    rm -rf -- "${destination_directory}"
fi

mkdir -p "${destination_directory}"
cp -a -- "${source_directory}/." "${destination_directory}/"
STUB

    chmod 0755 "${stub_directory}/rsync"
}

create_package_sources_repository() {
    mkdir -p "${package_sources_root}/${TEST_PACKAGE}"

    printf '%s\n' \
        'pkgname=sample-package' \
        'pkgver=1.0' \
        'pkgrel=1' \
        'arch=(x86_64)' \
        > "${package_sources_root}/${TEST_PACKAGE}/PKGBUILD"

    git -C "${package_sources_root}" init --quiet
    git -C "${package_sources_root}" add .
    commit_fixture_repository \
        "${package_sources_root}" \
        'Add synthetic package'

    package_sources_commit="$(
        git -C "${package_sources_root}" rev-parse HEAD
    )"
}

create_binary_repository() {
    local architecture_directory

    architecture_directory="${binary_repository_root}/${TEST_REPOSITORY}/x86_64"

    mkdir -p "${architecture_directory}"
    printf 'original\n' > "${architecture_directory}/original.txt"

    git -C "${binary_repository_root}" init --quiet
    git -C "${binary_repository_root}" add .
    commit_fixture_repository \
        "${binary_repository_root}" \
        'Add initial repository state'
}

create_fixture() {
    fixture_root="$(mktemp -d)"
    stub_directory="${fixture_root}/bin"
    package_sources_root="${fixture_root}/package-sources"
    binary_repository_root="${fixture_root}/binary-repository"
    package_output_directory="${ROOT_DIR}/out/packages/${TEST_REPOSITORY}/${TEST_PACKAGE}"
    package_output="${package_output_directory}/${TEST_PACKAGE}-1.0-1-x86_64.pkg.tar.zst"
    command_log="${fixture_root}/commands.log"

    mkdir -p \
        "${stub_directory}" \
        "${package_sources_root}" \
        "${binary_repository_root}"

    : > "${command_log}"

    create_container_engine_stub
    create_rsync_stub
    create_package_sources_repository
    create_binary_repository
}

reset_test_state() {
    local architecture_directory

    architecture_directory="${binary_repository_root}/${TEST_REPOSITORY}/x86_64"

    rm -rf -- \
        "${architecture_directory}" \
        "${binary_repository_root}/out" \
        "${ROOT_DIR}/out/build/${TEST_REPOSITORY}/${TEST_PACKAGE}" \
        "${ROOT_DIR}/out/packages/${TEST_REPOSITORY}/${TEST_PACKAGE}"

    mkdir -p "${architecture_directory}"
    printf 'original\n' > "${architecture_directory}/original.txt"
    : > "${command_log}"
}

run_subject() {
    run_command env \
        PATH="${stub_directory}:${PATH}" \
        CONTAINER_ENGINE="${stub_directory}/container-engine" \
        PACKAGE_SOURCES_ROOT="${package_sources_root}" \
        BINARY_REPOSITORY_ROOT_OVERRIDE="${binary_repository_root}" \
        ENGINE_MODE="${ENGINE_MODE:-success}" \
        COMMAND_LOG="${command_log}" \
        FAKE_PACKAGE_OUTPUT="${package_output}" \
        TEST_REPOSITORY="${TEST_REPOSITORY}" \
        bash "${SUBJECT}" \
        "$@"
}

assert_real_repository_unchanged() {
    local architecture_directory

    architecture_directory="${binary_repository_root}/${TEST_REPOSITORY}/x86_64"

    [[ "$(cat "${architecture_directory}/original.txt")" == original ]] \
        || fail 'original repository content changed'

    [[ ! -e "${architecture_directory}/$(basename "${package_output}")" ]] \
        || fail 'package reached the real repository before validation'

    [[ ! -e "${architecture_directory}/${TEST_REPOSITORY}.db" ]] \
        || fail 'database reached the real repository before validation'
}

assert_staging_removed() {
    local staging_parent

    staging_parent="${binary_repository_root}/out/staging"

    if [[ -d "${staging_parent}" ]] \
        && find "${staging_parent}" -mindepth 1 -print -quit | grep -q .
    then
        fail 'temporary staging directory was not removed'
    fi
}

test_requires_exact_arguments() {
    run_subject

    assert_status 64
    assert_contains 'Usage:'
}

test_rejects_malformed_identifiers() {
    run_subject \
        ../sample-repository \
        "${TEST_PACKAGE}" \
        "${package_sources_commit}"

    assert_status 64
    assert_contains 'invalid repository name'

    run_subject \
        "${TEST_REPOSITORY}" \
        ../sample-package \
        "${package_sources_commit}"

    assert_status 64
    assert_contains 'invalid package name'
}

test_rejects_noncanonical_commit_references() {
    local reference

    for reference in \
        HEAD \
        "${package_sources_commit:0:12}" \
        'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' \
        'not-a-commit-reference'
    do
        run_subject \
            "${TEST_REPOSITORY}" \
            "${TEST_PACKAGE}" \
            "${reference}"

        assert_status 64
        assert_contains 'complete lowercase 40-character commit'
    done
}

test_rejects_package_source_head_mismatch() {
    run_subject \
        "${TEST_REPOSITORY}" \
        "${TEST_PACKAGE}" \
        '0000000000000000000000000000000000000000'

    assert_status 65
    assert_contains 'package-source HEAD does not match'
}

test_rejects_dirty_target_repository() {
    local dirty_file

    reset_test_state
    dirty_file="${binary_repository_root}/${TEST_REPOSITORY}/x86_64/dirty.txt"
    : > "${dirty_file}"

    run_subject \
        "${TEST_REPOSITORY}" \
        "${TEST_PACKAGE}" \
        "${package_sources_commit}"

    assert_status 73
    assert_contains 'target repository has uncommitted changes'

    rm -f -- "${dirty_file}"
}

test_rejects_missing_build_output() {
    reset_test_state

    ENGINE_MODE=missing-output run_subject \
        "${TEST_REPOSITORY}" \
        "${TEST_PACKAGE}" \
        "${package_sources_commit}"

    assert_status 66
    assert_contains 'no built package was produced'
    assert_real_repository_unchanged
    assert_staging_removed
}

test_update_failure_preserves_repository() {
    reset_test_state

    ENGINE_MODE=update-fail run_subject \
        "${TEST_REPOSITORY}" \
        "${TEST_PACKAGE}" \
        "${package_sources_commit}"

    assert_status 42
    assert_real_repository_unchanged
    assert_staging_removed
}

test_validation_failure_preserves_repository() {
    reset_test_state

    ENGINE_MODE=validation-fail run_subject \
        "${TEST_REPOSITORY}" \
        "${TEST_PACKAGE}" \
        "${package_sources_commit}"

    assert_status 43
    assert_real_repository_unchanged
    assert_staging_removed
}

test_successful_atomic_publication() {
    local architecture_directory
    local published_package

    reset_test_state

    run_subject \
        "${TEST_REPOSITORY}" \
        "${TEST_PACKAGE}" \
        "${package_sources_commit}"

    assert_status 0
    assert_contains 'Package publication completed'

    architecture_directory="${binary_repository_root}/${TEST_REPOSITORY}/x86_64"
    published_package="${architecture_directory}/$(basename "${package_output}")"

    [[ -f "${published_package}" ]] \
        || fail 'validated package was not published'

    [[ -s "${architecture_directory}/${TEST_REPOSITORY}.db" ]] \
        || fail 'repository database was not published'

    [[ -s "${architecture_directory}/${TEST_REPOSITORY}.files" ]] \
        || fail 'files database was not published'

    [[ -f "${architecture_directory}/original.txt" ]] \
        || fail 'existing repository pool was not preserved'

    grep -F \
        '/work/scripts/update-repository-in-seed.sh' \
        "${command_log}" \
        | grep -Fq 'archlinux:base-20260823.0.578598' \
        || fail 'update container did not use the pinned image'

    grep -F \
        '/work/scripts/validate-repository-in-seed.sh' \
        "${command_log}" \
        | grep -Fq 'archlinux:base-20260823.0.578598' \
        || fail 'validation container did not use the pinned image'

    grep -Fq \
        'rsync --archive --delete' \
        "${command_log}" \
        || fail 'validated staging was not synchronized atomically'

    assert_staging_removed
}

main() {
    trap cleanup EXIT

    create_fixture

    test_requires_exact_arguments
    test_rejects_malformed_identifiers
    test_rejects_noncanonical_commit_references
    test_rejects_package_source_head_mismatch
    test_rejects_dirty_target_repository
    test_rejects_missing_build_output
    test_update_failure_preserves_repository
    test_validation_failure_preserves_repository
    test_successful_atomic_publication

    printf 'PASS: atomic package publication\n'
}

main "$@"
