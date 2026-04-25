#!/usr/bin/env bash

REMOTE_TARGET=""
SSH_CONTROL_PATH=""
declare -a SSH_BASE_OPTS=()
declare -a SSH_CONTROL_OPTS=()
declare -a SCP_CONTROL_OPTS=()

shell_quote() {
    printf '%q' "$1"
}

remote_init() {
    local local_tmp="$1"

    VM_PORT="${VM_PORT:-22}"
    REMOTE_TARGET="${VM_USER}@${VM_HOST}"
    SSH_CONTROL_PATH="${local_tmp}/ssh-control-%h-%p-%r"

    SSH_BASE_OPTS=(
        -p "$VM_PORT"
        -o BatchMode=yes
        -o ConnectTimeout="${SSH_CONNECT_TIMEOUT:-15}"
        -o ServerAliveInterval="${SSH_SERVER_ALIVE_INTERVAL:-10}"
        -o ServerAliveCountMax="${SSH_SERVER_ALIVE_COUNT_MAX:-3}"
        -o StrictHostKeyChecking="${SSH_STRICT_HOST_KEY_CHECKING:-accept-new}"
    )

    if [ -n "${SSH_KEY:-}" ]; then
        SSH_BASE_OPTS+=(-i "$SSH_KEY")
    fi

    SSH_CONTROL_OPTS=(
        "${SSH_BASE_OPTS[@]}"
        -o ControlMaster=no
        -o ControlPath="$SSH_CONTROL_PATH"
    )

    SCP_CONTROL_OPTS=(
        -P "$VM_PORT"
        -o BatchMode=yes
        -o ConnectTimeout="${SSH_CONNECT_TIMEOUT:-15}"
        -o ControlMaster=no
        -o ControlPath="$SSH_CONTROL_PATH"
        -o StrictHostKeyChecking="${SSH_STRICT_HOST_KEY_CHECKING:-accept-new}"
    )

    if [ -n "${SSH_KEY:-}" ]; then
        SCP_CONTROL_OPTS+=(-i "$SSH_KEY")
    fi
}

remote_start_master() {
    ssh "${SSH_BASE_OPTS[@]}" \
        -o ControlMaster=yes \
        -o ControlPath="$SSH_CONTROL_PATH" \
        -o ControlPersist=yes \
        -N -f "$REMOTE_TARGET"
}

remote_stop_master() {
    if [ -n "$REMOTE_TARGET" ] && [ -n "$SSH_CONTROL_PATH" ]; then
        ssh "${SSH_BASE_OPTS[@]}" -o ControlPath="$SSH_CONTROL_PATH" -O exit "$REMOTE_TARGET" >/dev/null 2>&1 || true
    fi
}

remote_run() {
    local command="$1"

    ssh "${SSH_CONTROL_OPTS[@]}" "$REMOTE_TARGET" "bash -s --" <<< "$command"
}

remote_capture() {
    local command="$1"

    remote_run "$command"
}

remote_scp_to() {
    local source_path="$1"
    local remote_dir="$2"

    scp "${SCP_CONTROL_OPTS[@]}" "$source_path" "${REMOTE_TARGET}:${remote_dir}/"
}
