#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
MODULE_SCRIPT="$ROOT_DIR/modules/paranoid-vpn/src/paranoid-vpn.sh"

has_wireguard_config_arg=false
for arg in "$@"; do
    case "$arg" in
        --wg-conf|--wg-conf=*)
            has_wireguard_config_arg=true
            break
            ;;
    esac
done

if [ "$has_wireguard_config_arg" = false ] && [ -f "$ROOT_DIR/wg0.conf" ]; then
    exec "$MODULE_SCRIPT" --wg-conf "$ROOT_DIR/wg0.conf" "$@"
fi

exec "$MODULE_SCRIPT" "$@"
