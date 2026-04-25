#!/usr/bin/env bash

retry_until() {
    local description="$1"
    local attempts="$2"
    local delay_seconds="$3"
    shift 3

    local attempt
    for ((attempt = 1; attempt <= attempts; attempt++)); do
        if "$@"; then
            log_pass "$description"
            return 0
        fi

        if (( attempt < attempts )); then
            log_info "$description not ready yet (${attempt}/${attempts}); retrying in ${delay_seconds}s"
            sleep "$delay_seconds"
        fi
    done

    fail "$description did not become true after ${attempts} attempts"
}
