#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly SUBJECT="${ROOT_DIR}/scripts/update-repository-in-seed.sh"

# shellcheck source=../lib/assertions.sh
source "${ROOT_DIR}/tests/lib/assertions.sh"

fixture_root=
stub_directory=
staged_directory=
package_file=
command_log=

cleanup() {
    if [[ -n "${fixture_root}" ]]; then
        rm -rf -- "${fixture_root}"
    fi
}

create_stub_commands() {
    mkdir -p "${stub_directory}"

    cat > "${stub_directory}/pacman" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -eq 2 && "$1" == -Qp ]]; then
    printf 'sample-package 1.0-1\n'
    exit
fi

printf 'unexpected pacman invocation: %s\n' "$*" >&2
exit 2
STUB

    cat > "${stub_directory}/repo-add" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${COMMAND_LOG}"

case "${REPO_ADD_MODE:-success}" in
    fail)
        exit 42
        ;;
    missing-output)
        exit
        ;;
esac

[[ "$1" == --remove ]]
database="$2"
files_database="${database%.db.tar.gz}.files.tar.gz"

printf 'database\n' > "${database}"
printf 'files database\n' > "${files_database}"

ln -s "$(basename "${database}")" "${database%.tar.gz}"
ln -s \
    "$(basename "${files_database}")" \
    "${files_database%.tar.gz}"

: > "${database}.old"
: > "${files_database}.old"
STUB

    cat > "${stub_directory}/bsdtar" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

destination=

while (( "$#" > 0 )); do
    case "$1" in
        -C)
            destination="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

[[ -n "${destination}" ]]

package_name="${DATABASE_PACKAGE_NAME:-sample-package}"
mkdir -p "${destination}/${package_name}-1.0-1"

printf '%s\n' \
    '%NAME%' \
    "${package_name}" \
    '' \
    '%VERSION%' \
    '1.0-1' \
    > "${destination}/${package_name}-1.0-1/desc"
STUB

    chmod 0755 \
        "${stub_directory}/pacman" \
        "${stub_directory}/repo-add" \
        "${stub_directory}/bsdtar"
}

reset_staging() {
    rm -rf -- "${staged_directory}"
    mkdir -p "${staged_directory}"
    : > "${command_log}"
}

create_fixture() {
    fixture_root="$(mktemp -d)"
    stub_directory="${fixture_root}/bin"
    staged_directory="${fixture_root}/staged repository"
    package_file="${fixture_root}/sample-package-1.0-1-x86_64.pkg.tar.zst"
    command_log="${fixture_root}/commands.log"

    mkdir -p "${staged_directory}"
    : > "${package_file}"
    : > "${command_log}"

    create_stub_commands
}

run_subject() {
    run_command env \
        PATH="${stub_directory}:${PATH}" \
        COMMAND_LOG="${command_log}" \
        REPO_ADD_MODE="${REPO_ADD_MODE:-success}" \
        DATABASE_PACKAGE_NAME="${DATABASE_PACKAGE_NAME:-sample-package}" \
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
        "${staged_directory}" \
        "${package_file}"

    assert_status 64
    assert_contains 'invalid repository name'
}

test_rejects_invalid_architecture() {
    run_subject \
        sample-repository \
        ../x86_64 \
        "${staged_directory}" \
        "${package_file}"

    assert_status 64
    assert_contains 'invalid architecture name'
}

test_requires_absolute_staging_directory() {
    run_subject \
        sample-repository \
        x86_64 \
        relative-directory \
        "${package_file}"

    assert_status 64
    assert_contains 'staged directory must be absolute'
}

test_rejects_missing_package_file() {
    run_subject \
        sample-repository \
        x86_64 \
        "${staged_directory}" \
        "${fixture_root}/missing.pkg.tar.zst"

    assert_status 66
    assert_contains 'package file not found'
}

test_propagates_repo_add_failure() {
    reset_staging

    REPO_ADD_MODE=fail run_subject \
        sample-repository \
        x86_64 \
        "${staged_directory}" \
        "${package_file}"

    assert_status 42
}

test_rejects_missing_database_output() {
    reset_staging

    REPO_ADD_MODE=missing-output run_subject \
        sample-repository \
        x86_64 \
        "${staged_directory}" \
        "${package_file}"

    assert_status 1
    assert_contains 'repository database is missing or empty'
}

test_rejects_missing_package_membership() {
    reset_staging

    DATABASE_PACKAGE_NAME=other-package run_subject \
        sample-repository \
        x86_64 \
        "${staged_directory}" \
        "${package_file}"

    assert_status 1
    assert_contains 'package is missing from repository database'
}

test_updates_repository_database() {
    local database
    local files_database

    reset_staging

    run_subject \
        sample-repository \
        x86_64 \
        "${staged_directory}" \
        "${package_file}"

    assert_status 0
    assert_contains 'Repository database updated'

    database="${staged_directory}/sample-repository.db.tar.gz"
    files_database="${staged_directory}/sample-repository.files.tar.gz"

    [[ -s "${database}" ]] \
        || fail 'compressed repository database is missing'

    [[ -s "${files_database}" ]] \
        || fail 'compressed files database is missing'

    [[ -f "${staged_directory}/sample-repository.db" ]] \
        || fail 'repository database alias is missing'

    [[ ! -L "${staged_directory}/sample-repository.db" ]] \
        || fail 'repository database alias is still a symlink'

    [[ -f "${staged_directory}/sample-repository.files" ]] \
        || fail 'files database alias is missing'

    [[ ! -L "${staged_directory}/sample-repository.files" ]] \
        || fail 'files database alias is still a symlink'

    if find "${staged_directory}" \
        -maxdepth 1 \
        \( -name '*.old' -o -name '*.old.sig' \) \
        -print -quit \
        | grep -q .
    then
        fail 'old repository database files were not removed'
    fi

    grep -Fq -- \
        "--remove ${database}" \
        "${command_log}" \
        || fail 'repo-add was not invoked with --remove'

    [[ -f \
        "${staged_directory}/$(basename "${package_file}")" ]] \
        || fail 'package was not copied into the staged repository'
}

main() {
    trap cleanup EXIT
    create_fixture

    test_requires_all_arguments
    test_rejects_invalid_repository
    test_rejects_invalid_architecture
    test_requires_absolute_staging_directory
    test_rejects_missing_package_file
    test_propagates_repo_add_failure
    test_rejects_missing_database_output
    test_rejects_missing_package_membership
    test_updates_repository_database

    printf 'PASS: repository database update\n'
}

main "$@"
