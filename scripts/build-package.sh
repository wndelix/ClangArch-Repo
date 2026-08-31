#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SEED_CONFIG="${ROOT_DIR}/config/seed.env"

usage() {
    printf 'Usage: %s <repository> <package>\n' "${0##*/}" >&2
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

load_seed_config() {
    [[ -f "${SEED_CONFIG}" ]] \
        || die "seed configuration not found: ${SEED_CONFIG}" 78

    # shellcheck source=/dev/null
    source "${SEED_CONFIG}"

    : "${ARCH_IMAGE:?ARCH_IMAGE is required}"
    : "${ARCH_SNAPSHOT:?ARCH_SNAPSHOT is required}"
    : "${TARGET_ARCH:?TARGET_ARCH is required}"

    [[ "${ARCH_SNAPSHOT}" =~ ^[0-9]{4}/[0-9]{2}/[0-9]{2}$ ]] \
        || die "invalid ARCH_SNAPSHOT: ${ARCH_SNAPSHOT}" 78

    [[ "${TARGET_ARCH}" == x86_64 ]] \
        || die "unsupported TARGET_ARCH: ${TARGET_ARCH}" 65
}

find_package_sources() {
    local candidate=

    if [[ -n "${PACKAGE_SOURCES_ROOT:-}" ]]; then
        candidate="${PACKAGE_SOURCES_ROOT}"
    elif [[ -d "${ROOT_DIR}/package-sources" ]]; then
        candidate="${ROOT_DIR}/package-sources"
    elif [[ -d "${ROOT_DIR}/../ClangArch-PKGBUILD" ]]; then
        candidate="${ROOT_DIR}/../ClangArch-PKGBUILD"
    else
        die 'package source repository was not found' 66
    fi

    [[ -d "${candidate}" ]] \
        || die "package source directory not found: ${candidate}" 66

    (
        cd "${candidate}"
        pwd -P
    )
}

find_engine() {
    if [[ -n "${CONTAINER_ENGINE:-}" ]]; then
        command -v "${CONTAINER_ENGINE}" >/dev/null 2>&1 \
            || die \
                "CONTAINER_ENGINE=${CONTAINER_ENGINE} was not found" \
                69
        printf '%s\n' "${CONTAINER_ENGINE}"
        return
    fi

    if command -v docker >/dev/null 2>&1; then
        printf '%s\n' docker
        return
    fi

    if command -v podman >/dev/null 2>&1; then
        printf '%s\n' podman
        return
    fi

    die 'Docker or Podman is required' 69
}

main() {
    [[ "$#" -eq 2 ]] || {
        usage
        exit 64
    }

    local -r repository="$1"
    local -r package="$2"
    local package_sources_root
    local package_directory
    local engine

    validate_identifier repository "${repository}"
    validate_identifier package "${package}"
    load_seed_config

    package_sources_root="$(find_package_sources)"
    package_directory="${package_sources_root}/${package}"

    [[ -f "${package_directory}/PKGBUILD" ]] \
        || die "PKGBUILD not found: ${package_directory}/PKGBUILD" 66

    engine="$(find_engine)"

    mkdir -p \
        "${ROOT_DIR}/out/build/${repository}/${package}" \
        "${ROOT_DIR}/out/packages/${repository}/${package}" \
        "${ROOT_DIR}/out/sources"

    printf '==> Package: %s/%s\n' "${repository}" "${package}"
    printf '==> Package sources: %s (read-only)\n' \
        "${package_sources_root}"
    printf '==> Engine: %s\n' "${engine}"
    printf '==> Seed image: %s\n' "${ARCH_IMAGE}"
    printf '==> Arch snapshot: %s\n' "${ARCH_SNAPSHOT}"
    printf '==> Target architecture: %s\n' "${TARGET_ARCH}"

    "${engine}" pull "${ARCH_IMAGE}"

    "${engine}" run \
        --rm \
        --env "ARCH_SNAPSHOT=${ARCH_SNAPSHOT}" \
        --env "TARGET_ARCH=${TARGET_ARCH}" \
        --env "BUILD_REPOSITORY=${repository}" \
        --env "BUILD_PACKAGE=${package}" \
        --env "HOST_UID=$(id -u)" \
        --env "HOST_GID=$(id -g)" \
        --volume "${ROOT_DIR}:/work" \
        --volume "${package_sources_root}:/package-sources:ro" \
        --workdir /work \
        "${ARCH_IMAGE}" \
        /bin/bash /work/scripts/build-package-in-seed.sh
}

main "$@"
