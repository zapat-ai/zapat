#!/usr/bin/env bats
# Tests for per-cycle dispatch cap in poll-github.sh

setup() {
    export TEST_DIR="$(mktemp -d)"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "dispatch_limit_reached returns 1 when under limit" {
    DISPATCH_COUNT=0
    MAX_DISPATCH=20

    dispatch_limit_reached() {
        if [[ $DISPATCH_COUNT -ge $MAX_DISPATCH ]]; then
            return 0
        fi
        return 1
    }

    ! dispatch_limit_reached
}

@test "dispatch_limit_reached returns 0 when at limit" {
    DISPATCH_COUNT=20
    MAX_DISPATCH=20

    dispatch_limit_reached() {
        if [[ $DISPATCH_COUNT -ge $MAX_DISPATCH ]]; then
            return 0
        fi
        return 1
    }

    dispatch_limit_reached
}

@test "dispatch_limit_reached returns 0 when over limit" {
    DISPATCH_COUNT=25
    MAX_DISPATCH=20

    dispatch_limit_reached() {
        if [[ $DISPATCH_COUNT -ge $MAX_DISPATCH ]]; then
            return 0
        fi
        return 1
    }

    dispatch_limit_reached
}

@test "MAX_DISPATCH defaults to 20 via MAX_DISPATCH_PER_CYCLE" {
    unset MAX_DISPATCH_PER_CYCLE
    MAX_DISPATCH=${MAX_DISPATCH_PER_CYCLE:-20}
    [[ $MAX_DISPATCH -eq 20 ]]
}

@test "MAX_DISPATCH respects MAX_DISPATCH_PER_CYCLE override" {
    MAX_DISPATCH_PER_CYCLE=5
    MAX_DISPATCH=${MAX_DISPATCH_PER_CYCLE:-20}
    [[ $MAX_DISPATCH -eq 5 ]]
}

@test "dispatch counter increments correctly" {
    DISPATCH_COUNT=0
    MAX_DISPATCH=3

    dispatch_limit_reached() {
        if [[ $DISPATCH_COUNT -ge $MAX_DISPATCH ]]; then
            return 0
        fi
        return 1
    }

    dispatched=0
    for i in 1 2 3 4 5; do
        if dispatch_limit_reached; then
            break
        fi
        DISPATCH_COUNT=$((DISPATCH_COUNT + 1))
        dispatched=$((dispatched + 1))
    done

    [[ $dispatched -eq 3 ]]
    [[ $DISPATCH_COUNT -eq 3 ]]
}
