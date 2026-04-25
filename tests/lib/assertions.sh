#!/usr/bin/env bash

fail() {
    log_error "$1"
    exit 1
}

assert_eq() {
    local description="$1"
    local expected="$2"
    local actual="$3"

    if [ "$expected" != "$actual" ]; then
        fail "$description: expected '$expected', got '$actual'"
    fi

    log_pass "$description"
}

assert_contains() {
    local description="$1"
    local haystack="$2"
    local needle="$3"

    if [[ "$haystack" != *"$needle"* ]]; then
        fail "$description: expected output to contain '$needle'"
    fi

    log_pass "$description"
}

assert_not_contains() {
    local description="$1"
    local haystack="$2"
    local needle="$3"

    if [[ "$haystack" == *"$needle"* ]]; then
        fail "$description: output unexpectedly contained '$needle'"
    fi

    log_pass "$description"
}

assert_command() {
    local description="$1"
    shift

    if ! "$@"; then
        fail "$description"
    fi

    log_pass "$description"
}
