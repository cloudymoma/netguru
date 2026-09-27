# shellcheck shell=bash
# The VM must stay as ensure_vm created it: any drift (IP, tag, network, posture) stops the run.

vm() { cat "${FIXTURES}/$1"; }

expect_eq "VM as created has no drift" \
  "$(vm_invariant_problems "$(vm vm-netguru.json)" 203.0.113.100)" ""
expect_eq "IP mismatch is drift" \
  "$(vm_invariant_problems "$(vm vm-netguru.json)" 1.2.3.4)" \
  "external IP 203.0.113.100 != static 1.2.3.4"
expect_eq "missing tag is drift" \
  "$(NETWORK_TAG=other vm_invariant_problems "$(vm vm-netguru.json)" 203.0.113.100)" \
  "missing tag other"
VM_DRIFTED=$(vm vm-netguru.json | jq '.networkInterfaces[0].network = "projects/p/global/networks/default"
  | .serviceAccounts = [{"email": "sa@example.com"}]
  | .shieldedInstanceConfig.enableSecureBoot = false | .deletionProtection = false')
expect_eq "network and posture drift are all reported" \
  "$(vm_invariant_problems "$VM_DRIFTED" 203.0.113.100)" \
  "network default != netguru-net; service account attached; secure boot off; deletion protection off"

# A stopped VM is started, then held to the same checks.
# ensure_vm_stopped [STATIC_IP] — ensure_vm against a TERMINATED copy of the fixture; the stubbed start flips it to RUNNING.
# shellcheck disable=SC2329 # stubs invoked by ensure_vm in lib.sh
ensure_vm_stopped() {
  local ip=${1:-203.0.113.100} status=TERMINATED
  gcloud_resource_exists() { return 0; }
  get_static_ip() { echo "$ip"; }
  run_gcloud() { status=RUNNING; }
  vm_json() { jq --arg s "$status" '.status = $s' "${FIXTURES}/vm-netguru.json"; }
  ensure_vm
}
expect_ok   "ensure_vm starts a stopped VM" ensure_vm_stopped
expect_fail "ensure_vm stops the run on drift" ensure_vm_stopped 1.2.3.4

# A missing VM is created with the configured boot disk type: gcloud's default (pd-standard) gives a 10 GB disk
# only 1.2 MiB/s, too slow for the fresh install and any swapping.
# ensure_vm_created — ensure_vm when the VM does not exist; prints the create call's arguments, one per line.
# shellcheck disable=SC2329 # stubs invoked by ensure_vm in lib.sh
ensure_vm_created() {
  gcloud_resource_exists() { return 1; }
  get_static_ip() { echo 203.0.113.100; }
  run_gcloud() { printf '%s\n' "$@"; }
  vm_json() { cat "${FIXTURES}/vm-netguru.json"; }
  ensure_vm
}
expect_eq "a new VM gets the configured boot disk type" \
  "$(ensure_vm_created 2>/dev/null | grep -xF -e "--boot-disk-type=${VM_DISK_TYPE:-unset}")" \
  "--boot-disk-type=${VM_DISK_TYPE:-unset}"
