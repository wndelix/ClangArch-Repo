#!/usr/bin/env bash
set -euo pipefail

repository=
architecture=
repository_root=
temporary_directory=
pacman_config=
declare -a package_files=()
declare -a package_names=()
declare -a package_versions=()

usage() {
    printf '%s\n' \
        "Usage: ${0##*/} <repository> <architecture>" \
        '       <repository-root> <package-file>...' \
        >&2
}

die() {
    local message="$1"
    local exit_status="${2:-1}"

    printf 'ERROR: %s\n' "${message}" >&2
    exit "${exit_status}"
}

cleanup() {
    if [[ -n "${temporary_directory}" ]]; then
        rm -rf -- "${temporary_directory}"
    fi
}

validate_identifier() {
    local kind="$1"
    local value="$2"

    [[ "${value}" =~ ^[a-z0-9][a-z0-9@._+-]*$ ]] \
        || die "invalid ${kind} name: ${value}" 64
}

require_commands() {
    local command

    for command in pacman awk mktemp; do
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
    repository_root="$3"
    shift 3
    package_files=("$@")

    validate_identifier repository "${repository}"
    validate_identifier architecture "${architecture}"

    [[ "${repository_root}" == /* ]] \
        || die 'repository root must be absolute' 64

    [[ -d "${repository_root}" ]] \
        || die "repository root not found: ${repository_root}" 66

    for package_file in "${package_files[@]}"; do
        [[ -f "${package_file}" ]] \
            || die "package file not found: ${package_file}" 66

        [[ "${package_file}" == *.pkg.tar.zst ]] \
            || die "unexpected package filename: ${package_file}" 65
    done
}

collect_package_identities() {
    local package_file
    local package_name
    local package_version

    for package_file in "${package_files[@]}"; do
        read -r package_name package_version \
            < <(pacman -Qp "${package_file}")

        [[ -n "${package_name}" && -n "${package_version}" ]] \
            || die "could not read package identity: ${package_file}"

        package_names+=("${package_name}")
        package_versions+=("${package_version}")
    done
}

create_pacman_configuration() {
    temporary_directory="$(mktemp -d)"
    pacman_config="${temporary_directory}/pacman.conf"

    {
        printf '%s\n' \
            '[options]' \
            "Architecture = ${architecture}" \
            'SigLevel = Optional TrustAll' \
            'LocalFileSigLevel = Optional' \
            'Color' \
            'CheckSpace' \
            '' \
            "[${repository}]" \
            'SigLevel = Optional TrustAll'

        printf 'Server = file://%s/$repo/$arch\n' \
            "${repository_root}"
    } > "${pacman_config}"
}

synchronize_repository() {
    printf '==> Synchronizing %s/%s repository database\n' \
        "${repository}" \
        "${architecture}"

    pacman \
        --config "${pacman_config}" \
        -Sy \
        --noconfirm
}

read_reported_repository() {
    awk -F: '
        $1 ~ /^[[:space:]]*Repository[[:space:]]*$/ {
            value = $2
            sub(/^[[:space:]]*/, "", value)
            sub(/[[:space:]]*$/, "", value)
            print value
            exit
        }
    '
}

verify_repository_entries() {
    local index
    local package_name
    local package_information
    local reported_repository

    for index in "${!package_names[@]}"; do
        package_name="${package_names[index]}"

        package_information="$(
            LC_ALL=C pacman \
                --config "${pacman_config}" \
                -Si "${repository}/${package_name}"
        )"

        reported_repository="$(
            read_reported_repository <<< "${package_information}"
        )"

        [[ "${reported_repository}" == "${repository}" ]] \
            || die \
                "unexpected repository for ${package_name}: ${reported_repository:-unknown}"
    done
}

install_repository_packages() {
    local package_name
    local -a repository_targets=()

    for package_name in "${package_names[@]}"; do
        repository_targets+=("${repository}/${package_name}")
    done

    printf '==> Installing packages through %s repository\n' \
        "${repository}"

    pacman \
        --config "${pacman_config}" \
        -S \
        --noconfirm \
        --needed \
        "${repository_targets[@]}"
}

verify_installed_packages() {
    local index
    local package_name
    local package_version
    local installed_identity
    local installed_name
    local installed_version
    local installed_paths
    local installed_path

    for index in "${!package_names[@]}"; do
        package_name="${package_names[index]}"
        package_version="${package_versions[index]}"

        installed_identity="$(pacman -Q "${package_name}")"
        read -r installed_name installed_version \
            <<< "${installed_identity}"

        [[ "${installed_name}" == "${package_name}" \
            && "${installed_version}" == "${package_version}" ]] \
            || die \
                "installed package identity mismatch: expected ${package_name} ${package_version}, got ${installed_identity}"

        installed_paths="$(pacman -Qlq "${package_name}")"

        while IFS= read -r installed_path; do
            [[ -n "${installed_path}" ]] || continue
            [[ "${installed_path}" != / ]] || continue

            [[ -e "${installed_path}" || -L "${installed_path}" ]] \
                || die \
                    "installed package path is missing: ${installed_path}"
        done <<< "${installed_paths}"
    done
}

main() {
    trap cleanup EXIT

    validate_inputs "$@"
    require_commands
    collect_package_identities
    create_pacman_configuration
    synchronize_repository
    verify_repository_entries
    install_repository_packages
    verify_installed_packages

    printf '==> Pacman repository validation passed: %s/%s\n' \
        "${repository}" \
        "${architecture}"
}

main "$@"
