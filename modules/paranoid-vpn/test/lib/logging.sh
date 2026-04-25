#!/usr/bin/env bash

log_section() {
    printf '\n==> %s\n' "$1"
}

log_info() {
    printf '    %s\n' "$1"
}

log_pass() {
    printf ' ok %s\n' "$1"
}

log_warn() {
    printf 'WARN %s\n' "$1" >&2
}

log_error() {
    printf 'FAIL %s\n' "$1" >&2
}
