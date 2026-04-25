#!/usr/bin/env bash

declare -a CLEANUP_COMMANDS=()

cleanup_add() {
    CLEANUP_COMMANDS+=("$1")
}

cleanup_run() {
    local index
    local command

    for ((index = ${#CLEANUP_COMMANDS[@]} - 1; index >= 0; index--)); do
        command="${CLEANUP_COMMANDS[$index]}"
        eval "$command" || true
    done
}
