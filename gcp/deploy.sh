#!/usr/bin/env bash
# Deploy one service module onto the VM: deploy.sh <service> (spec §4.4).
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

svc=${1:-}
[[ -n "$svc" ]] || die "usage: deploy.sh <service>"
if ! service_enabled "$svc"; then
  if [[ -f "${GCP_DIR}/services/${svc}/service.env" ]]; then
    die "service '${svc}' is turned off: set $(service_switch "$svc")=true in gcp/config.env"
  fi
  die "unknown service '${svc}' (known: $(known_services | tr '\n' ' ' | sed 's/ $//'))"
fi
UPGRADE=${UPGRADE:-no}
[[ "$UPGRADE" == yes || "$UPGRADE" == no ]] || die "UPGRADE must be yes or no (got '${UPGRADE}')"
validate_config
load_service "$svc"
service_validate

STATIC_IP=$(get_static_ip)
require_ipv4 STATIC_IP "${STATIC_IP}"
ensure_firewall_rule "$(fw_rule_name "$svc")" 0.0.0.0/0 "${FW_RULES}"
if declare -F service_prepare >/dev/null; then service_prepare; fi

log "running ${svc} remote-install on ${VM_NAME} (upgrade=${UPGRADE})"
# shellcheck disable=SC2086 # REMOTE_VARS is a space-separated list of variable names
run_remote "${SERVICE_DIR}/remote-install.sh" STATIC_IP UPGRADE ${REMOTE_VARS}
log "${svc} done (upgrade=${UPGRADE})"
