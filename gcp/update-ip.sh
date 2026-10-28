#!/usr/bin/env bash
# Rotate the VM's public static IP, keeping the reservation name (spec §4.8). Resumable; requires CONFIRM=1.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

if [[ "${CONFIRM:-}" != 1 ]]; then
  cat >&2 <<PLAN
make update-ip gives ${VM_NAME} a NEW public IP: every Outline key, vless:// and hysteria2:// config changes.
Clients must be re-configured from the output of 'make show' afterwards.
Re-run with CONFIRM=1 to proceed.
PLAN
  exit 1
fi

validate_config

vm=$(vm_json)
[[ "$(jq -r .status <<<"$vm")" == RUNNING ]] || die "VM ${VM_NAME} is not RUNNING (run 'make infra' first)"
vm_ip=$(jq -r '.networkInterfaces[0].accessConfigs[0].natIP // ""' <<<"$vm")
ac_name=$(jq -r '.networkInterfaces[0].accessConfigs[0].name // "external-nat"' <<<"$vm")
reserved_ip=""
if gcloud_resource_exists compute addresses describe "${STATIC_IP_NAME}" --region="${GCP_REGION}"; then
  reserved_ip=$(get_static_ip)
fi
state=$(ip_rotation_state "$reserved_ip" "$vm_ip")
log "state=${state} reservation=${reserved_ip:-none} vm_ip=${vm_ip:-none}"

if [[ "$state" == attach ]]; then
  log "VM has no external IP (interrupted swap?): attaching a new ephemeral IP"
  run_gcloud compute instances add-access-config "${VM_NAME}" --zone="${GCP_ZONE}" \
    --access-config-name="$ac_name" --network-tier=PREMIUM
  vm_ip=$(run_gcloud compute instances describe "${VM_NAME}" --zone="${GCP_ZONE}" \
    --format='value(networkInterfaces[0].accessConfigs[0].natIP)')
  require_ipv4 NEW_IP "$vm_ip"
  state=$(ip_rotation_state "$reserved_ip" "$vm_ip")
  [[ "$state" != rotate ]] || die "new IP ${vm_ip} equals the reserved IP (unexpected)"
fi

if [[ "$state" == rotate ]]; then
  log "swapping ${vm_ip} for a new ephemeral IP (the old one stays reserved, so the new one must differ)"
  run_gcloud compute instances delete-access-config "${VM_NAME}" --zone="${GCP_ZONE}" --access-config-name="$ac_name"
  run_gcloud compute instances add-access-config "${VM_NAME}" --zone="${GCP_ZONE}" \
    --access-config-name="$ac_name" --network-tier=PREMIUM
  vm_ip=$(run_gcloud compute instances describe "${VM_NAME}" --zone="${GCP_ZONE}" \
    --format='value(networkInterfaces[0].accessConfigs[0].natIP)')
  require_ipv4 NEW_IP "$vm_ip"
  [[ "$vm_ip" != "$reserved_ip" ]] || die "new IP equals the old reserved IP ${reserved_ip}"
  state=release
fi

if [[ "$state" == release ]]; then
  status=$(run_gcloud compute addresses describe "${STATIC_IP_NAME}" --region="${GCP_REGION}" --format='value(status)')
  [[ "$status" == RESERVED ]] || die "${STATIC_IP_NAME} (${reserved_ip}) is ${status}, not RESERVED; refusing to delete it"
  log "releasing old reservation ${STATIC_IP_NAME} (${reserved_ip})"
  run_gcloud compute addresses delete "${STATIC_IP_NAME}" --region="${GCP_REGION}"
  state=promote
fi

if [[ "$state" == promote ]]; then
  log "promoting ${vm_ip} to static IP ${STATIC_IP_NAME}"
  run_gcloud compute addresses create "${STATIC_IP_NAME}" --region="${GCP_REGION}" \
    --addresses="$vm_ip" --network-tier=PREMIUM
fi

[[ "$(get_static_ip)" == "$vm_ip" ]] || die "${STATIC_IP_NAME} does not hold ${vm_ip} after rotation"
log "static IP is now ${vm_ip}; re-syncing services"
for s in ${SERVICES}; do "${GCP_DIR}/deploy.sh" "$s"; done
"${GCP_DIR}/show.sh"
