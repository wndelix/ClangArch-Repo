#!/usr/bin/env bash
set -euo pipefail

readonly WORKSPACE="${WORKSPACE_OVERRIDE:-/work}"
readonly PACKAGE_SOURCES="${PACKAGE_SOURCES_OVERRIDE:-/package-sources}"
readonly PACMAN_CONFIGURATION="${PACMAN_CONFIGURATION_OVERRIDE:-/etc/pacman.conf}"

builder_uid=
builder_gid=
builder_user=
builder_group=
builder_home=

die() {
    local message="$1"
    local exit_status="${2:-1}"

    printf 'ERROR: %s\n' "${message}" >&2
    exit "${exit_status}"
}

require_variable() {
    local name="$1"

    [[ -n "${!name:-}" ]] || die "${name} is required" 64
}

validate_identifier() {
    local kind="$1"
    local value="$2"

    [[ "${value}" =~ ^[a-z0-9][a-z0-9@._+-]*$ ]] \
        || die "invalid ${kind} name: ${value}" 64
}

package_directory() {
    printf '%s/%s\n' "${PACKAGE_SOURCES}" "${BUILD_PACKAGE}"
}

build_directory() {
    printf '%s/out/build/%s/%s\n' \
        "${WORKSPACE}" \
        "${BUILD_REPOSITORY}" \
        "${BUILD_PACKAGE}"
}

package_output_directory() {
    printf '%s/out/packages/%s/%s\n' \
        "${WORKSPACE}" \
        "${BUILD_REPOSITORY}" \
        "${BUILD_PACKAGE}"
}

source_cache_directory() {
    printf '%s/out/sources\n' "${WORKSPACE}"
}

validate_inputs() {
    local name
    local package_dir
    local package_output

    for name in \
        ARCH_SNAPSHOT \
        TARGET_ARCH \
        BUILD_REPOSITORY \
        BUILD_PACKAGE \
        HOST_UID \
        HOST_GID
    do
        require_variable "${name}"
    done

    validate_identifier repository "${BUILD_REPOSITORY}"
    validate_identifier package "${BUILD_PACKAGE}"

    [[ "${ARCH_SNAPSHOT}" =~ ^[0-9]{4}/[0-9]{2}/[0-9]{2}$ ]] \
        || die "invalid ARCH_SNAPSHOT: ${ARCH_SNAPSHOT}" 64

    [[ "${TARGET_ARCH}" == x86_64 ]] \
        || die "unsupported TARGET_ARCH: ${TARGET_ARCH}" 65

    [[ "${HOST_UID}" =~ ^[0-9]+$ ]] \
        || die 'HOST_UID must be numeric' 64

    [[ "${HOST_GID}" =~ ^[0-9]+$ ]] \
        || die 'HOST_GID must be numeric' 64

    [[ "${WORKSPACE}" == /* ]] \
        || die 'WORKSPACE must be absolute' 64

    [[ "${PACKAGE_SOURCES}" == /* ]] \
        || die 'PACKAGE_SOURCES must be absolute' 64

    package_dir="$(package_directory)"

    [[ -f "${package_dir}/PKGBUILD" ]] \
        || die "PKGBUILD not found: ${package_dir}/PKGBUILD" 66

    package_output="$(package_output_directory)"
    mkdir -p "${package_output}"

    if find "${package_output}" -mindepth 1 -print -quit | grep -q .; then
        die "package output is not empty: ${package_output}" 73
    fi

    (( EUID == 0 )) \
        || die 'build-package-in-seed.sh must run as root' 77
}

configure_seed() {
    printf '==> Pinning Arch repositories to %s\n' "${ARCH_SNAPSHOT}"

    printf 'Server = https://archive.archlinux.org/repos/%s/$repo/os/$arch\n' \
        "${ARCH_SNAPSHOT}" \
        > /etc/pacman.d/mirrorlist

    printf '==> Updating the pinned seed\n'
    pacman -Syu --noconfirm --needed

    printf '==> Installing generic package build tools\n'
    pacman -S --noconfirm --needed \
        base-devel \
        git \
        sudo

    command -v readelf >/dev/null 2>&1 \
        || die 'readelf is required for generic ELF inspection'
}

select_builder_ids() {
    if [[ "${HOST_UID}" == 0 ]]; then
        builder_uid=1000
        builder_gid=1000
    else
        builder_uid="${HOST_UID}"
        builder_gid="${HOST_GID}"
    fi
}

create_builder() {
    select_builder_ids

    if getent group "${builder_gid}" >/dev/null 2>&1; then
        builder_group="$(getent group "${builder_gid}" | cut -d: -f1)"
    else
        builder_group=package-builder
        groupadd --gid "${builder_gid}" "${builder_group}"
    fi

    if getent passwd "${builder_uid}" >/dev/null 2>&1; then
        builder_user="$(getent passwd "${builder_uid}" | cut -d: -f1)"
    else
        builder_user=package-builder
        useradd \
            --create-home \
            --uid "${builder_uid}" \
            --gid "${builder_group}" \
            --shell /bin/bash \
            "${builder_user}"
    fi

    builder_home="$(getent passwd "${builder_uid}" | cut -d: -f6)"

    [[ -n "${builder_home}" ]] \
        || die "home directory not found for UID ${builder_uid}"

    printf '%s ALL=(root) NOPASSWD: /usr/bin/pacman\n' \
        "${builder_user}" \
        > /etc/sudoers.d/package-builder

    chmod 0440 /etc/sudoers.d/package-builder
}

prepare_output_directories() {
    local build_dir
    local package_output
    local source_cache

    build_dir="$(build_directory)"
    package_output="$(package_output_directory)"
    source_cache="$(source_cache_directory)"

    install -d \
        -o "${builder_uid}" \
        -g "${builder_gid}" \
        "${build_dir}" \
        "${package_output}" \
        "${source_cache}"
}

list_expected_packages() {
    local package_dir
    local build_dir
    local package_output
    local source_cache

    package_dir="$(package_directory)"
    build_dir="$(build_directory)"
    package_output="$(package_output_directory)"
    source_cache="$(source_cache_directory)"

    runuser -u "${builder_user}" -- env \
        HOME="${builder_home}" \
        BUILDDIR="${build_dir}" \
        PKGDEST="${package_output}" \
        SRCDEST="${source_cache}" \
        LC_ALL=C \
        bash --noprofile --norc -c '
            set -euo pipefail
            cd "$1"
            makepkg --packagelist
        ' bash "${package_dir}"
}

package_path_is_expected() {
    local package_file="$1"
    shift

    local expected_package

    for expected_package in "$@"; do
        if [[ "${package_file}" == "${expected_package}" ]]; then
            return
        fi
    done

    return 1
}

collect_produced_packages() {
    local expected_array_name="$1"
    local produced_array_name="$2"
    local -n expected_package_files_ref="${expected_array_name}"
    local -n produced_package_files_ref="${produced_array_name}"
    local package_output
    local package_file

    package_output="$(package_output_directory)"
    produced_package_files_ref=()

    while IFS= read -r -d '' package_file; do
        package_path_is_expected \
            "${package_file}" \
            "${expected_package_files_ref[@]}" \
            || die \
                "makepkg produced an unreported package: ${package_file}"

        produced_package_files_ref+=("${package_file}")
    done < <(
        find "${package_output}" \
            -maxdepth 1 \
            -type f \
            -name '*.pkg.tar.zst' \
            -print0
    )

    (( "${#produced_package_files_ref[@]}" > 0 )) \
        || die 'makepkg did not produce any package output'
}

build_package() {
    local package_dir
    local build_dir
    local package_output
    local source_cache

    package_dir="$(package_directory)"
    build_dir="$(build_directory)"
    package_output="$(package_output_directory)"
    source_cache="$(source_cache_directory)"

    printf '==> Building %s/%s as %s\n' \
        "${BUILD_REPOSITORY}" \
        "${BUILD_PACKAGE}" \
        "${builder_user}"

    runuser -u "${builder_user}" -- env \
        HOME="${builder_home}" \
        BUILDDIR="${build_dir}" \
        PKGDEST="${package_output}" \
        SRCDEST="${source_cache}" \
        MAKEFLAGS="-j$(nproc)" \
        LC_ALL=C \
        bash --noprofile --norc -c '
            set -euo pipefail
            cd "$1"
            makepkg \
                --cleanbuild \
                --clean \
                --force \
                --noconfirm \
                --rmdeps \
                --syncdeps
        ' bash "${package_dir}"
}

archive_path_is_unsafe() {
    local entry="$1"
    local component
    local -a components=()

    [[ "${entry}" == /* ]] && return 0

    IFS='/' read -r -a components <<< "${entry}"

    for component in "${components[@]}"; do
        [[ "${component}" == .. ]] && return 0
    done

    return 1
}

require_metadata_entry() {
    local package_file="$1"
    local metadata="$2"
    shift 2
    local -a entries=("$@")
    local entry

    for entry in "${entries[@]}"; do
        if [[ "${entry}" == "${metadata}" ]]; then
            return
        fi
    done

    die "missing ${metadata} in package: ${package_file}"
}

inspect_elf_files() {
    local package_file="$1"
    local inspection_root
    local file
    local relative_path

    inspection_root="$(mktemp -d)"

    bsdtar \
        --no-same-owner \
        -xf "${package_file}" \
        -C "${inspection_root}"

    while IFS= read -r -d '' file; do
        if ! readelf -h "${file}" >/dev/null 2>&1; then
            continue
        fi

        relative_path="${file#"${inspection_root}/"}"
        printf '==> ELF: %s\n' "${relative_path}"

        readelf -lW "${file}" 2>/dev/null \
            | grep -E 'INTERP|Requesting program interpreter' \
            || true

        readelf -dW "${file}" 2>/dev/null \
            | grep -E '\((NEEDED|RPATH|RUNPATH)\)' \
            || true
    done < <(find "${inspection_root}" -type f -print0)

    rm -rf -- "${inspection_root}"
}

validate_package_archive() {
    local package_file="$1"
    local package_identity
    local package_architecture
    local entry
    local payload_found=false
    local -a entries=()

    [[ -f "${package_file}" ]] \
        || die "makepkg did not produce: ${package_file}"

    package_identity="$(pacman -Qp "${package_file}")"
    printf '==> Produced package: %s\n' "${package_file}"
    printf '%s\n' "${package_identity}"

    mapfile -t entries < <(bsdtar -tf "${package_file}")

    require_metadata_entry \
        "${package_file}" \
        .PKGINFO \
        "${entries[@]}"

    require_metadata_entry \
        "${package_file}" \
        .BUILDINFO \
        "${entries[@]}"

    require_metadata_entry \
        "${package_file}" \
        .MTREE \
        "${entries[@]}"

    for entry in "${entries[@]}"; do
        archive_path_is_unsafe "${entry}" \
            && die "unsafe archive path in ${package_file}: ${entry}"

        case "${entry}" in
            .PKGINFO|.BUILDINFO|.MTREE|*/)
                ;;
            *)
                payload_found=true
                ;;
        esac
    done

    [[ "${payload_found}" == true ]] \
        || die "package payload is empty: ${package_file}"

    package_architecture="$(
        bsdtar -xOf "${package_file}" .PKGINFO \
            | sed -n 's/^arch = //p' \
            | head -n 1
    )"

    case "${package_architecture}" in
        any|"${TARGET_ARCH}")
            ;;
        *)
            die \
                "unexpected package architecture in ${package_file}: ${package_architecture}"
            ;;
    esac

    inspect_elf_files "${package_file}"
}

create_validation_pacman_configuration() {
    local destination="$1"

    [[ -f "${PACMAN_CONFIGURATION}" ]] \
        || die \
            "pacman configuration not found: ${PACMAN_CONFIGURATION}" \
            78

    awk '
        $0 !~ /^[[:space:]]*NoExtract[[:space:]]*=/
    ' "${PACMAN_CONFIGURATION}" > "${destination}"
}

validate_installed_packages() (
    local package_file
    local package_name
    local package_version
    local installed_identity
    local installed_path
    local validation_pacman_configuration

    validation_pacman_configuration="$(mktemp)"
    trap \
        'rm -f -- "${validation_pacman_configuration}"' \
        EXIT

    create_validation_pacman_configuration \
        "${validation_pacman_configuration}"

    printf '%s\n' \
        '==> Installing packages without seed NoExtract filters'

    pacman \
        --config "${validation_pacman_configuration}" \
        -U \
        --noconfirm \
        "$@"

    for package_file in "$@"; do
        read -r package_name package_version \
            < <(pacman -Qp "${package_file}")

        installed_identity="$(pacman -Q "${package_name}")"

        [[ "${installed_identity}" == \
            "${package_name} ${package_version}" ]] \
            || die \
                "installed identity mismatch: expected ${package_name} ${package_version}, got ${installed_identity}"

        while IFS= read -r installed_path; do
            [[ "${installed_path}" == / ]] && continue

            [[ -e "${installed_path}" || -L "${installed_path}" ]] \
                || die \
                    "installed package path is missing: ${installed_path}"
        done < <(pacman -Qlq "${package_name}")
    done
)

validate_packages() {
    local package_output
    local package_file
    local -a package_files=("$@")

    package_output="$(package_output_directory)"

    (( "${#package_files[@]}" > 0 )) \
        || die 'makepkg did not produce any package output'

    for package_file in "${package_files[@]}"; do
        [[ "${package_file}" == "${package_output}/"* ]] \
            || die "unexpected package output path: ${package_file}"

        validate_package_archive "${package_file}"
    done

    validate_installed_packages "${package_files[@]}"

    chown \
        "${HOST_UID}:${HOST_GID}" \
        "${package_files[@]}"
}

main() {
    local -a expected_package_files=()
    local -a package_files=()

    validate_inputs
    configure_seed
    create_builder
    prepare_output_directories

    mapfile -t expected_package_files < <(list_expected_packages)

    (( "${#expected_package_files[@]}" > 0 )) \
        || die 'makepkg did not report any package output'

    build_package

    collect_produced_packages \
        expected_package_files \
        package_files

    validate_packages "${package_files[@]}"

    printf '==> Package build completed\n'
    df -h /
}

main "$@"
