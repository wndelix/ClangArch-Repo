#!/usr/bin/env bash
set -euo pipefail

TEST_OUTPUT=
TEST_STATUS=0

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

run_command() {
    set +e
    TEST_OUTPUT="$("$@" 2>&1)"
    TEST_STATUS=$?
    set -e
}

assert_status() {
    local expected="$1"

    [[ "${TEST_STATUS}" -eq "${expected}" ]] \
        || fail \
            "expected status ${expected}, got ${TEST_STATUS}: ${TEST_OUTPUT}"
}

assert_contains() {
    local expected="$1"

    [[ "${TEST_OUTPUT}" == *"${expected}"* ]] \
        || fail "expected '${expected}' in output: ${TEST_OUTPUT}"
}

assert_not_contains() {
    local unexpected="$1"

    [[ "${TEST_OUTPUT}" != *"${unexpected}"* ]] \
        || fail "did not expect '${unexpected}' in output: ${TEST_OUTPUT}"
}
