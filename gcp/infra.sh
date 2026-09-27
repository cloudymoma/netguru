#!/usr/bin/env bash
# Ensure shared infrastructure: static IP, VM invariants, base firewall (spec §4.3, §4.9).
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

validate_config
ensure_static_ip
ensure_vm
ensure_base_firewall
log "infra ready: ${VM_NAME} @ $(get_static_ip)"
