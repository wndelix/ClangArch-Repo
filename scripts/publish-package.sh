#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SEED_CONFIG="${ROOT_DIR}/config/seed.env"

repository=
package=
package_sources_commit=
package_sources_root=
binary_repository_root=
engine=
staging_root=
staged_repository_root=
staged_architecture_directory=
declare -a package_files=()
declare -a container_package_files=()
declare -a staged_container_package_files=()

usage() {
    printf 'Usage: %s <repository> <package> <package-sources-commit>\n' \
        "${0##*/}" \
        >&2
}

die() {
    local message="$1"
    local exit_status="${2:-1}"

    printf 'ERROR: %s\n' "${message}" >&2
    exit "${exit_status}"
}

cleanup() {
    if [[ -n "${staging_root}" && -d "${staging_root}" ]]; then
        rm -rf -- "${staging_root}"
    fi
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

find_binary_repository_root() {
    local candidate

    candidate="${BINARY_REPOSITORY_ROOT_OVERRIDE:-${ROOT_DIR}}"

    [[ "${candidate}" == /* ]] \
        || die 'binary repository root must be absolute' 64

    [[ -d "${candidate}" ]] \
        || die "binary repository root not found: ${candidate}" 66

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

require_commands() {
    local command

    for command in git rsync mktemp find; do
        command -v "${command}" >/dev/null 2>&1 \
            || die "required command was not found: ${command}" 69
    done
}

validate_inputs() {
    [[ "$#" -eq 3 ]] || {
        usage
        exit 64
    }

    repository="$1"
    package="$2"
    package_sources_commit="$3"

    validate_identifier repository "${repository}"
    validate_identifier package "${package}"

    [[ "${package_sources_commit}" =~ ^[0-9a-f]{40}$ ]] \
        || die \
            'package-sources commit must be a complete lowercase 40-character commit' \
            64
}

verify_package_source_provenance() {
    local source_head

    [[ -f "${package_sources_root}/${package}/PKGBUILD" ]] \
        || die \
            "PKGBUILD not found: ${package_sources_root}/${package}/PKGBUILD" \
            66

    source_head="$(
        git -C "${package_sources_root}" \
            rev-parse --verify 'HEAD^{commit}'
    )"

    [[ "${source_head}" == "${package_sources_commit}" ]] \
        || die \
            "package-source HEAD does not match ${package_sources_commit}" \
            65
}

verify_binary_repository() {
    local git_root
    local target_status

    git_root="$(
        git -C "${binary_repository_root}" \
            rev-parse --show-toplevel
    )"

    git_root="$(
        cd "${git_root}"
        pwd -P
    )"

    [[ "${git_root}" == "${binary_repository_root}" ]] \
        || die \
            "binary repository root is not a Git worktree root: ${binary_repository_root}" \
            65

    target_status="$(
        git -C "${binary_repository_root}" \
            status \
            --porcelain \
            -- "${repository}/${TARGET_ARCH}"
    )"

    [[ -z "${target_status}" ]] \
        || die \
            "target repository has uncommitted changes: ${repository}/${TARGET_ARCH}" \
            73
}

build_package() {
    printf '==> Building package from source commit %s\n' \
        "${package_sources_commit}"

    PACKAGE_SOURCES_ROOT="${package_sources_root}" \
    CONTAINER_ENGINE="${engine}" \
        "${ROOT_DIR}/scripts/build-package.sh" \
        "${repository}" \
        "${package}"
}

collect_package_files() {
    local output_directory
    local package_file

    output_directory="${ROOT_DIR}/out/packages/${repository}/${package}"

    while IFS= read -r -d '' package_file; do
        package_files+=("${package_file}")
    done < <(
        find "${output_directory}" \
            -maxdepth 1 \
            -type f \
            -name '*.pkg.tar.zst' \
            -print0
    )

    (( "${#package_files[@]}" > 0 )) \
        || die \
            "no built package was produced for ${repository}/${package}" \
            66
}

prepare_staging() {
    local staging_parent
    local real_architecture_directory

    staging_parent="${binary_repository_root}/out/staging"
    real_architecture_directory="${binary_repository_root}/${repository}/${TARGET_ARCH}"

    mkdir -p "${staging_parent}"

    staging_root="$(
        mktemp -d \
            "${staging_parent}/${repository}.XXXXXXXX"
    )"

    staged_repository_root="${staging_root}/repository"
    staged_architecture_directory="${staged_repository_root}/${repository}/${TARGET_ARCH}"

    mkdir -p "${staged_architecture_directory}"

    if [[ -d "${real_architecture_directory}" ]]; then
        rsync \
            --archive \
            "${real_architecture_directory}/" \
            "${staged_architecture_directory}/"
    fi
}

prepare_container_paths() {
    local package_file
    local relative_path

    for package_file in "${package_files[@]}"; do
        [[ "${package_file}" == "${ROOT_DIR}/"* ]] \
            || die \
                "built package is outside the infrastructure root: ${package_file}"

        relative_path="${package_file#"${ROOT_DIR}/"}"

        container_package_files+=("/work/${relative_path}")
        staged_container_package_files+=(
            "/repository/${repository}/${TARGET_ARCH}/$(basename "${package_file}")"
        )
    done
}

update_staged_repository() {
    printf '==> Updating staged repository database\n'

    "${engine}" run \
        --rm \
        --user "$(id -u):$(id -g)" \
        --volume "${ROOT_DIR}:/work:ro" \
        --volume "${staged_repository_root}:/repository" \
        --workdir /work \
        "${ARCH_IMAGE}" \
        /bin/bash \
        /work/scripts/update-repository-in-seed.sh \
        "${repository}" \
        "${TARGET_ARCH}" \
        "/repository/${repository}/${TARGET_ARCH}" \
        "${container_package_files[@]}"
}

validate_staged_repository() {
    printf '==> Validating staged repository in a fresh container\n'

    "${engine}" run \
        --rm \
        --volume "${ROOT_DIR}:/work:ro" \
        --volume "${staged_repository_root}:/repository:ro" \
        --workdir /work \
        "${ARCH_IMAGE}" \
        /bin/bash \
        /work/scripts/validate-repository-in-seed.sh \
        "${repository}" \
        "${TARGET_ARCH}" \
        /repository \
        "${staged_container_package_files[@]}"
}

publish_staged_repository() {
    local real_architecture_directory

    real_architecture_directory="${binary_repository_root}/${repository}/${TARGET_ARCH}"

    printf '==> Publishing validated repository state\n'

    mkdir -p "${real_architecture_directory}"

    rsync \
        --archive \
        --delete \
        "${staged_architecture_directory}/" \
        "${real_architecture_directory}/"
}

main() {
    trap cleanup EXIT

    validate_inputs "$@"
    load_seed_config
    require_commands

    package_sources_root="$(find_package_sources)"
    binary_repository_root="$(find_binary_repository_root)"
    engine="$(find_engine)"

    verify_package_source_provenance
    verify_binary_repository
    build_package
    collect_package_files
    prepare_staging
    prepare_container_paths
    update_staged_repository
    validate_staged_repository
    publish_staged_repository

    printf '==> Package publication completed: %s/%s\n' \
        "${repository}" \
        "${package}"
}

main "$@"
