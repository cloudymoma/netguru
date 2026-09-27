#!/usr/bin/env bash
# Ensure shared infrastructure: network, firewall, static IP, VM, SSH (spec §4.3, §4.7, §4.9).
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

validate_config
ensure_network
ensure_base_firewall
ensure_static_ip
ensure_vm
wait_for_ssh
log "infra ready: ${VM_NAME} @ $(get_static_ip)"
