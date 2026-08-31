#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly SUBJECT="${ROOT_DIR}/scripts/build-package.sh"

# shellcheck source=../lib/assertions.sh
source "${ROOT_DIR}/tests/lib/assertions.sh"

fixture_root=
fixture_sources=

cleanup() {
    if [[ -n "${fixture_root}" ]]; then
        rm -rf -- "${fixture_root}"
    fi
}

create_fixture() {
    fixture_root="$(mktemp -d)"
    fixture_sources="${fixture_root}/package sources"

    mkdir -p "${fixture_sources}/sample-package"
    : > "${fixture_sources}/sample-package/PKGBUILD"
}

run_subject() {
    run_command env \
        PACKAGE_SOURCES_ROOT="${fixture_sources}" \
        CONTAINER_ENGINE=/bin/echo \
        bash "${SUBJECT}" \
        "$@"
}

test_requires_repository_and_package() {
    run_subject

    assert_status 64
    assert_contains 'Usage:'
}

test_rejects_path_traversal() {
    run_subject sample-repository ../sample-package

    assert_status 64
    assert_contains 'invalid package name'
}

test_rejects_missing_package() {
    run_subject sample-repository missing-package

    assert_status 66
    assert_contains 'PKGBUILD not found'
}

test_rejects_unavailable_explicit_engine() {
    run_command env \
        PACKAGE_SOURCES_ROOT="${fixture_sources}" \
        CONTAINER_ENGINE=/definitely/missing-container-engine \
        bash "${SUBJECT}" \
        sample-repository \
        sample-package

    assert_status 69
    assert_contains 'CONTAINER_ENGINE='
    assert_contains 'was not found'
}

test_runs_pinned_seed_with_read_only_sources() {
    run_subject sample-repository sample-package

    assert_status 0
    assert_contains '==> Package: sample-repository/sample-package'
    assert_contains \
        "==> Package sources: ${fixture_sources} (read-only)"
    assert_contains 'pull archlinux:base-20260823.0.578598'
    assert_contains 'run --rm'
    assert_contains '--env ARCH_SNAPSHOT=2026/08/23'
    assert_contains '--env TARGET_ARCH=x86_64'
    assert_contains '--env BUILD_REPOSITORY=sample-repository'
    assert_contains '--env BUILD_PACKAGE=sample-package'
    assert_contains \
        "--volume ${fixture_sources}:/package-sources:ro"
    assert_contains \
        '--workdir /work archlinux:base-20260823.0.578598'
    assert_contains \
        '/bin/bash /work/scripts/build-package-in-seed.sh'

    [[ -d \
        "${ROOT_DIR}/out/build/sample-repository/sample-package" ]] \
        || fail 'missing isolated build directory'

    [[ -d \
        "${ROOT_DIR}/out/packages/sample-repository/sample-package" ]] \
        || fail 'missing isolated package output directory'

    [[ -d "${ROOT_DIR}/out/sources" ]] \
        || fail 'missing shared source cache'
}

main() {
    trap cleanup EXIT
    create_fixture

    test_requires_repository_and_package
    test_rejects_path_traversal
    test_rejects_missing_package
    test_rejects_unavailable_explicit_engine
    test_runs_pinned_seed_with_read_only_sources

    printf 'PASS: build-package interface\n'
}

main "$@"
