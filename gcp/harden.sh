#!/usr/bin/env bash
# One-time adoption/hardening of an existing VM (spec §4.7). Idempotent; requires CONFIRM=1.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

if [[ "${CONFIRM:-}" != 1 ]]; then
  cat >&2 <<PLAN
make harden will, on ${VM_NAME} in ${GCP_PROJECT}:
  1. back up and remove the startup-script metadata
  2. enable IAP, add ${FW_SSH_IAP}, verify SSH over IAP, move service rules to priority ${FW_ALLOW_PRIORITY}, add ${FW_DENY_ALL}
  3. delete ${FW_LEGACY_OUTLINE_API}
  4. STOP the VM (~1-2 min Outline downtime), remove its service account, enable Secure Boot, START it
  5. check that Outline's access-key count is unchanged (the adopt check also removes the watchtower auto-updater),
     then enable deletion protection
Re-run with CONFIRM=1 to proceed.
PLAN
  exit 1
fi

validate_config
STATIC_IP=$(get_static_ip)
require_ipv4 STATIC_IP "${STATIC_IP}"

# Runs Outline's idempotent adopt path and returns the key count it reports.
outline_key_count() {
  local out n
  # shellcheck disable=SC2086 # REMOTE_VARS is a space-separated list of variable names
  out=$(load_service outline && run_remote "${SERVICE_DIR}/remote-install.sh" STATIC_IP ${REMOTE_VARS} 2>&1) ||
    { echo "$out" >&2; die "Outline remote-install failed"; }
  n=$(sed -n 's/.*healthy: \([0-9][0-9]*\) access key.*/\1/p' <<<"$out" | tail -1)
  [[ -n "$n" ]] || { echo "$out" >&2; die "could not read Outline key count"; }
  echo "$n"
}

# 1. startup-script: must go before any reboot
script=$(vm_startup_script "$(vm_json)")
if [[ -n "$script" ]]; then
  mkdir -p "${GCP_DIR}/.backup"
  backup="${GCP_DIR}/.backup/startup-script-$(date +%Y%m%dT%H%M%S).sh"
  printf '%s\n' "$script" >"$backup"
  log "saved startup-script to ${backup}; removing it from ${VM_NAME}"
  run_gcloud compute instances remove-metadata "${VM_NAME}" --zone="${GCP_ZONE}" --keys=startup-script
else
  log "no startup-script on ${VM_NAME}"
fi

# 2-3. firewall (ordered, lock-out safe) and legacy API rule
ensure_base_firewall
delete_firewall_rule_if_exists "${FW_LEGACY_OUTLINE_API}"

# 4. offline hardening with Outline key-count guard
keys_before=""
if service_enabled outline; then
  keys_before=$(outline_key_count)
  log "Outline reports ${keys_before} access key(s) before stop/start"
fi
if [[ "$(vm_offline_hardening_needed "$(vm_json)")" == yes ]]; then
  log "stopping ${VM_NAME} — Outline downtime starts"
  log "rollback if it fails to boot: stop, 'gcloud compute instances update ${VM_NAME} --zone=${GCP_ZONE} --no-shielded-secure-boot', start"
  run_gcloud compute instances stop "${VM_NAME}" --zone="${GCP_ZONE}"
  run_gcloud compute instances set-service-account "${VM_NAME}" --zone="${GCP_ZONE}" --no-service-account --no-scopes
  run_gcloud compute instances update "${VM_NAME}" --zone="${GCP_ZONE}" --shielded-secure-boot
  run_gcloud compute instances start "${VM_NAME}" --zone="${GCP_ZONE}"
  wait_for_ssh
  log "${VM_NAME} is back"
else
  log "service account already removed and Secure Boot already on"
fi

# 5. keys unchanged, then deletion protection
if service_enabled outline; then
  keys_after=$(outline_key_count)
  [[ "$keys_after" == "$keys_before" ]] || die "Outline access-key count changed: ${keys_before} -> ${keys_after}"
  log "Outline access-key count unchanged (${keys_after})"
fi
run_gcloud compute instances update "${VM_NAME}" --zone="${GCP_ZONE}" --deletion-protection

gaps=$(vm_hardening_gaps "$(vm_json)")
[[ -z "$gaps" ]] || die "hardening incomplete: ${gaps}"
log "hardening complete. Next: make sing-box && make verify"
