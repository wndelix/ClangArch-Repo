#!/usr/bin/env bash
set -euo pipefail

repository=
architecture=
staged_directory=
declare -a package_files=()
declare -a staged_packages=()

usage() {
    printf '%s\n' \
        "Usage: ${0##*/} <repository> <architecture>" \
        '       <staged-architecture-directory> <package-file>...' \
        >&2
}

die() {
    local message="$1"
    local exit_status="${2:-1}"

    printf 'ERROR: %s\n' "${message}" >&2
    exit "${exit_status}"
}

validate_identifier() {
    local kind="$1"
    local value="$2"

    [[ "${value}" =~ ^[a-z0-9][a-z0-9@._+-]*$ ]] \
        || die "invalid ${kind} name: ${value}" 64
}

require_commands() {
    local command

    for command in pacman repo-add bsdtar readlink; do
        command -v "${command}" >/dev/null 2>&1 \
            || die "required command was not found: ${command}" 69
    done
}

validate_inputs() {
    local package_file

    (( "$#" >= 4 )) || {
        usage
        exit 64
    }

    repository="$1"
    architecture="$2"
    staged_directory="$3"
    shift 3
    package_files=("$@")

    validate_identifier repository "${repository}"
    validate_identifier architecture "${architecture}"

    [[ "${staged_directory}" == /* ]] \
        || die 'staged directory must be absolute' 64

    [[ -d "${staged_directory}" ]] \
        || die "staged directory not found: ${staged_directory}" 66

    [[ -w "${staged_directory}" ]] \
        || die "staged directory is not writable: ${staged_directory}" 73

    for package_file in "${package_files[@]}"; do
        [[ -f "${package_file}" ]] \
            || die "package file not found: ${package_file}" 66

        [[ "${package_file}" == *.pkg.tar.zst ]] \
            || die "unexpected package filename: ${package_file}" 65
    done
}

stage_package_files() {
    local package_file
    local destination

    for package_file in "${package_files[@]}"; do
        pacman -Qp "${package_file}" >/dev/null

        destination="${staged_directory}/$(basename "${package_file}")"

        if [[ "${package_file}" != "${destination}" ]]; then
            cp -- "${package_file}" "${destination}"
        fi

        staged_packages+=("${destination}")
    done
}

update_database() {
    local database

    database="${staged_directory}/${repository}.db.tar.gz"

    printf '==> Updating %s/%s repository database\n' \
        "${repository}" \
        "${architecture}"

    repo-add \
        --remove \
        "${database}" \
        "${staged_packages[@]}"

    find "${staged_directory}" \
        -maxdepth 1 \
        \( -name '*.old' -o -name '*.old.sig' \) \
        -delete
}

replace_database_alias() {
    local alias="$1"
    local compressed_database="$2"
    local link_target

    [[ -s "${compressed_database}" ]] \
        || die \
            "repository database is missing or empty: ${compressed_database}"

    [[ -e "${alias}" || -L "${alias}" ]] \
        || die "repository database alias is missing: ${alias}"

    if [[ -L "${alias}" ]]; then
        link_target="$(readlink "${alias}")"

        [[ "${link_target}" == "$(basename "${compressed_database}")" ]] \
            || die \
                "unexpected repository database link target: ${link_target}"
    elif [[ ! -f "${alias}" ]]; then
        die "repository database alias is not a regular file: ${alias}"
    fi

    rm -f -- "${alias}"
    cp -- "${compressed_database}" "${alias}"

    [[ -f "${alias}" && ! -L "${alias}" && -s "${alias}" ]] \
        || die "failed to create regular database alias: ${alias}"
}

replace_database_aliases() {
    replace_database_alias \
        "${staged_directory}/${repository}.db" \
        "${staged_directory}/${repository}.db.tar.gz"

    replace_database_alias \
        "${staged_directory}/${repository}.files" \
        "${staged_directory}/${repository}.files.tar.gz"
}

read_desc_field() {
    local description_file="$1"
    local field="$2"

    awk -v marker="%${field}%" '
        previous == marker {
            print
            exit
        }

        {
            previous = $0
        }
    ' "${description_file}"
}

database_contains_identity() {
    local extraction_root="$1"
    local expected_name="$2"
    local expected_version="$3"
    local description_file
    local database_name
    local database_version

    while IFS= read -r -d '' description_file; do
        database_name="$(read_desc_field "${description_file}" NAME)"
        database_version="$(read_desc_field "${description_file}" VERSION)"

        if [[ "${database_name}" == "${expected_name}" \
            && "${database_version}" == "${expected_version}" ]]
        then
            return
        fi
    done < <(
        find "${extraction_root}" \
            -mindepth 2 \
            -maxdepth 2 \
            -type f \
            -name desc \
            -print0
    )

    return 1
}

verify_database_membership() {
    local extraction_root
    local package_file
    local package_name
    local package_version

    extraction_root="$(mktemp -d)"
    trap 'rm -rf -- "${extraction_root}"' RETURN

    bsdtar \
        -xf "${staged_directory}/${repository}.db.tar.gz" \
        -C "${extraction_root}"

    for package_file in "${staged_packages[@]}"; do
        read -r package_name package_version \
            < <(pacman -Qp "${package_file}")

        database_contains_identity \
            "${extraction_root}" \
            "${package_name}" \
            "${package_version}" \
            || die \
                "package is missing from repository database: ${package_name} ${package_version}"
    done

    rm -rf -- "${extraction_root}"
    trap - RETURN
}

main() {
    validate_inputs "$@"
    require_commands
    stage_package_files
    update_database
    replace_database_aliases
    verify_database_membership

    printf '==> Repository database updated: %s/%s\n' \
        "${repository}" \
        "${architecture}"
}

main "$@"
