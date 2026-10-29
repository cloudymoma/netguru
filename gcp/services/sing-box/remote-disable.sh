#!/usr/bin/env bash
# VM-side (root): stop sing-box while SINGBOX_ENABLED=false (run by make infra). /etc/sing-box (credentials,
# certificate, config) is kept, so turning it back on restores the same client configs. Idempotent; without
# sing-box there is nothing to do.
set -euo pipefail

log() { echo "[sing-box] $*" >&2; }

main() {
  if ! systemctl cat sing-box.service >/dev/null 2>&1; then
    log "turned off: not installed, nothing to stop"
    return 0
  fi
  if systemctl is-enabled --quiet sing-box || systemctl is-active --quiet sing-box; then
    log "turned off: stopping sing-box and disabling it at boot (credentials kept in /etc/sing-box)"
    systemctl disable --now sing-box >/dev/null
  else
    log "turned off: sing-box already stopped"
  fi
}

[[ -n "${NETGURU_SOURCE_ONLY:-}" ]] || main
