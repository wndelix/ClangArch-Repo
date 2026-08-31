#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly WORKFLOW="${ROOT_DIR}/.github/workflows/publish-package.yml"

# shellcheck source=../lib/assertions.sh
source "${ROOT_DIR}/tests/lib/assertions.sh"

assert_workflow_contains() {
    local expected="$1"

    grep -Fq -- "${expected}" "${WORKFLOW}" \
        || fail "workflow does not contain: ${expected}"
}

test_workflow_exists() {
    [[ -f "${WORKFLOW}" ]] \
        || fail "workflow not found: ${WORKFLOW}"
}

test_manual_trigger_only() {
    assert_workflow_contains '  workflow_dispatch:'

    if grep -Eq \
        '^[[:space:]]{2}(push|pull_request|schedule|workflow_call):' \
        "${WORKFLOW}"
    then
        fail 'workflow contains a non-manual trigger'
    fi
}

test_required_inputs() {
    local required_count

    assert_workflow_contains '      repository:'
    assert_workflow_contains '      package:'
    assert_workflow_contains '      package_sources_commit:'

    required_count="$(
        grep -Ec '^[[:space:]]{8}required: true$' "${WORKFLOW}"
    )"

    [[ "${required_count}" -eq 3 ]] \
        || fail "expected three required inputs, found ${required_count}"
}

test_execution_policy() {
    assert_workflow_contains 'runs-on: ubuntu-24.04'
    assert_workflow_contains 'timeout-minutes: 60'
    assert_workflow_contains 'contents: write'
    assert_workflow_contains 'group: publish-${{ inputs.repository }}'
    assert_workflow_contains 'cancel-in-progress: false'
}

test_pinned_checkouts() {
    local checkout_count
    local checkout_reference

    checkout_reference='actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1'

    checkout_count="$(
        grep -Fc "${checkout_reference}" "${WORKFLOW}"
    )"

    [[ "${checkout_count}" -eq 2 ]] \
        || fail "expected two pinned checkouts, found ${checkout_count}"

    assert_workflow_contains 'repository: wndelix/ClangArch-PKGBUILD'
    assert_workflow_contains 'ref: ${{ inputs.package_sources_commit }}'
    assert_workflow_contains 'path: package-sources'
    assert_workflow_contains 'persist-credentials: false'
}

test_validation_precedes_publication() {
    local test_line
    local publication_line

    test_line="$(
        grep -n -F 'name: Run infrastructure tests' "${WORKFLOW}" \
            | cut -d: -f1
    )"

    publication_line="$(
        grep -n -F 'name: Build, validate, and publish package' "${WORKFLOW}" \
            | cut -d: -f1
    )"

    [[ -n "${test_line}" && -n "${publication_line}" ]] \
        || fail 'test or publication step is missing'

    (( test_line < publication_line )) \
        || fail 'publication runs before infrastructure tests'

    assert_workflow_contains 'for test_script in tests/scripts/*.sh; do'
    assert_workflow_contains 'bash "${test_script}"'
    assert_workflow_contains './scripts/publish-package.sh'
}

test_inputs_use_environment_variables() {
    assert_workflow_contains 'REPOSITORY: ${{ inputs.repository }}'
    assert_workflow_contains 'PACKAGE: ${{ inputs.package }}'
    assert_workflow_contains \
        'PACKAGE_SOURCES_COMMIT: ${{ inputs.package_sources_commit }}'

    if awk '
        /^[[:space:]]{8}run: \|$/ {
            in_run = 1
            next
        }

        in_run && /^[[:space:]]{6}- name:/ {
            in_run = 0
        }

        in_run && /\$\{\{[[:space:]]*inputs\./ {
            found = 1
        }

        END {
            exit found ? 0 : 1
        }
    ' "${WORKFLOW}"
    then
        fail 'workflow input was interpolated directly into shell code'
    fi
}

test_commit_scope_and_metadata() {
    assert_workflow_contains \
        'git add -- "${REPOSITORY}/${TARGET_ARCH}"'

    if grep -Eq \
        'git add[[:space:]]+(-A|--all|\.)' \
        "${WORKFLOW}"
    then
        fail 'workflow stages files outside the selected repository'
    fi

    assert_workflow_contains 'git diff --cached --quiet'
    assert_workflow_contains 'Publish ${REPOSITORY}/${PACKAGE}'
    assert_workflow_contains \
        'PKGBUILD-Commit: %s\nInfrastructure-Commit: %s'
    assert_workflow_contains '"${PACKAGE_SOURCES_COMMIT}"'
    assert_workflow_contains '"${GITHUB_SHA}"'
}

main() {
    test_workflow_exists
    test_manual_trigger_only
    test_required_inputs
    test_execution_policy
    test_pinned_checkouts
    test_validation_precedes_publication
    test_inputs_use_environment_variables
    test_commit_scope_and_metadata

    printf 'PASS: publication workflow\n'
}

main "$@"
