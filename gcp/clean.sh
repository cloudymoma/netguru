#!/usr/bin/env bash
# Delete every netguru resource on GCP (make clean): the VM and its disk, the static IP, netguru's firewall rules,
# and its subnet and VPC. Irreversible: the keys and credentials on the VM and the static IP are gone for good, and
# every client config stops working. Without CONFIRM=<GCP_PROJECT> it only prints the plan. Everything is checked
# before anything is deleted; after a failure, run it again to finish.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

for v in GCP_PROJECT GCP_REGION GCP_ZONE VM_NAME NETWORK_NAME NETWORK_TAG STATIC_IP_NAME; do
  require_not_tbd "$v" "${!v}"
done
PROFILE_FILE="${NETGURU_ROOT}/netguru-client.json"

# --- what exists, and is it netguru's? (read-only) ---------------------------------------------------------------
vm="" disk="" ip="" net="" keep="" subnet=no
if gcloud_resource_exists compute instances describe "${VM_NAME}" --zone="${GCP_ZONE}"; then
  vm=$(vm_json)
  why=$(vm_not_netguru "$vm")
  [[ -z "$why" ]] || die "VM ${VM_NAME} does not look like netguru's (${why}); refusing to delete anything"
elif gcloud_resource_exists compute disks describe "${VM_NAME}" --zone="${GCP_ZONE}"; then
  # The boot disk outlived its VM (e.g. an earlier run failed after the VM delete): delete it unless something uses it.
  users=$(resource_other_users "$(run_gcloud compute disks describe "${VM_NAME}" --zone="${GCP_ZONE}" --format=json)")
  if [[ -z "$users" ]]; then disk=${VM_NAME}; else log "leaving disk ${VM_NAME}: attached to ${users}"; fi
fi
if gcloud_resource_exists compute addresses describe "${STATIC_IP_NAME}" --region="${GCP_REGION}"; then
  ip_json=$(run_gcloud compute addresses describe "${STATIC_IP_NAME}" --region="${GCP_REGION}" --format=json)
  ip=$(jq -r '.address' <<<"$ip_json")
  users=$(resource_other_users "$ip_json")
  [[ -z "$users" ]] || die "static IP ${STATIC_IP_NAME} (${ip}) is used by ${users}, not netguru; refusing to delete anything"
fi
rules_json=$(run_gcloud compute firewall-rules list --format=json)
rules=$(netguru_fw_rules "$rules_json")
if gcloud_resource_exists compute networks describe "${NETWORK_NAME}"; then
  net=${NETWORK_NAME}
  keep=$(network_keep_reason "$(run_gcloud compute networks describe "${NETWORK_NAME}" --format=json)" \
    "$rules_json" "$(run_gcloud compute instances list --format=json)")
  if gcloud_resource_exists compute networks subnets describe "${NETWORK_NAME}" --region="${GCP_REGION}"; then
    subnet=yes
  fi
fi

plan() {
  echo "make clean deletes these netguru resources in project ${GCP_PROJECT}, irreversibly:"
  if [[ -n "$vm" ]]; then echo "  - VM ${VM_NAME} (${GCP_ZONE}) and its disk, with every key and credential on it"; fi
  if [[ -n "$disk" ]]; then echo "  - disk ${disk} (${GCP_ZONE}), left over from the VM"; fi
  if [[ -n "$ip" ]]; then echo "  - static IP ${STATIC_IP_NAME} (${ip}): every client config points at it, and once released it is gone"; fi
  if [[ -n "$rules" ]]; then echo "  - firewall rules ${rules}"; fi
  if [[ -n "$net" && -z "$keep" && "$subnet" == yes ]]; then echo "  - subnet ${NETWORK_NAME} (${GCP_REGION}) and VPC ${NETWORK_NAME}"; fi
  if [[ -n "$net" && -z "$keep" && "$subnet" == no ]]; then echo "  - VPC ${NETWORK_NAME}"; fi
  if [[ -n "$keep" ]]; then echo "  (VPC ${NETWORK_NAME} stays: ${keep})"; fi
  echo "It leaves the iap.googleapis.com API enabled (other things in the project may use it), and ${PROFILE_FILE}."
}

if [[ -z "${vm}${disk}${ip}${rules}" && ( -z "$net" || -n "$keep" ) ]]; then
  log "nothing to delete: no netguru resources in project ${GCP_PROJECT}${keep:+ (VPC ${NETWORK_NAME} stays: ${keep})}"
  exit 0
fi
plan >&2
if [[ "${CONFIRM:-}" != "${GCP_PROJECT}" ]]; then
  [[ -z "${CONFIRM:-}" ]] || echo "CONFIRM must be the project ID, ${GCP_PROJECT} (got '${CONFIRM}')." >&2
  echo "To delete them: make clean CONFIRM=${GCP_PROJECT}" >&2
  exit 1
fi

# --- delete, dependents first --------------------------------------------------------------------------------------
if [[ -n "$vm" ]]; then
  if [[ "$(jq -r '.deletionProtection // false' <<<"$vm")" == true ]]; then
    log "turning off deletion protection on ${VM_NAME}"
    run_gcloud compute instances update "${VM_NAME}" --zone="${GCP_ZONE}" --no-deletion-protection
  fi
  log "deleting VM ${VM_NAME} and its disk"
  run_gcloud compute instances delete "${VM_NAME}" --zone="${GCP_ZONE}" --delete-disks=all
fi
if [[ -n "$disk" ]]; then
  log "deleting disk ${disk}"
  run_gcloud compute disks delete "$disk" --zone="${GCP_ZONE}"
fi
if [[ -n "$ip" ]]; then
  log "releasing static IP ${STATIC_IP_NAME} (${ip})"
  run_gcloud compute addresses delete "${STATIC_IP_NAME}" --region="${GCP_REGION}"
fi
for r in $rules; do
  log "deleting firewall rule ${r}"
  run_gcloud compute firewall-rules delete "$r"
done
if [[ -n "$net" && -z "$keep" ]]; then
  if [[ "$subnet" == yes ]]; then
    log "deleting subnet ${NETWORK_NAME} (${GCP_REGION})"
    run_gcloud compute networks subnets delete "${NETWORK_NAME}" --region="${GCP_REGION}"
  fi
  # GCP itself refuses while anything else (other subnets, routers, peerings) still uses the network.
  log "deleting VPC ${NETWORK_NAME}"
  run_gcloud compute networks delete "${NETWORK_NAME}"
fi
log "done: netguru's resources in ${GCP_PROJECT} are deleted"
