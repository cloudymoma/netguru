# shellcheck shell=bash
# make clean deletes everything netguru made, and nothing else: only with CONFIRM=<project>, only resources that are
# provably netguru's, dependents first, resumable. A stateful stub gcloud plays the project; nothing reaches GCP.
CLEAN_BIN=$(mktemp -d)
CLEAN_NET="https://www.googleapis.com/compute/v1/projects/du-hast-mich/global/networks/netguru-net"
CLEAN_VM_URL="https://www.googleapis.com/compute/v1/projects/du-hast-mich/zones/asia-northeast1-a/instances/netguru-server"
cat >"${CLEAN_BIN}/gcloud" <<'STUB'
#!/usr/bin/env bash
# Stateful stub: $CLEAN_STATE holds one JSON file per resource; deletes remove them and are logged as mutations.
S=$CLEAN_STATE
args=" $* "
mutate() { sed -E 's/^--project=[^ ]+ --quiet //' <<<"$*" >>"$S/mutations"; }
show() { # describe: value(name) or json, "was not found" like gcloud when absent
  [[ -f "$1" ]] || { echo "ERROR: (gcloud) The resource '${1##*/}' was not found" >&2; exit 1; }
  if [[ "$args" == *" --format=json "* ]]; then cat "$1"; else jq -r .name "$1"; fi
}
list() { if (($#)); then jq -s . "$@"; else echo '[]'; fi; }
shopt -s nullglob
case "$args" in
  *" compute instances describe "*)  show "$S/vm.json" ;;
  *" compute instances list "*)
    files=()
    for f in "$S"/vm.json "$S"/other-vm*.json; do if [[ -f "$f" ]]; then files+=("$f"); fi; done
    list "${files[@]}" ;;
  *" compute instances update "*)    mutate "$@"; jq '.deletionProtection = false' "$S/vm.json" >"$S/t" && mv "$S/t" "$S/vm.json" ;;
  *" compute instances delete "*)    mutate "$@"; rm -f "$S/vm.json"; if [[ "$args" == *" --delete-disks=all "* ]]; then rm -f "$S/disk.json"; fi ;;
  *" compute disks describe "*)      show "$S/disk.json" ;;
  *" compute disks delete "*)        mutate "$@"; rm -f "$S/disk.json" ;;
  *" compute addresses describe "*)  show "$S/address.json" ;;
  *" compute addresses delete "*)    mutate "$@"; rm -f "$S/address.json" ;;
  *" compute firewall-rules list "*) list "$S"/fw/*.json ;;
  *" compute firewall-rules delete "*) mutate "$@"; rm -f "$S/fw/${*: -1}.json" ;;
  *" compute networks subnets describe "*) show "$S/subnet.json" ;;
  *" compute networks subnets delete "*)   mutate "$@"; rm -f "$S/subnet.json" ;;
  *" compute networks describe "*)   show "$S/network.json" ;;
  *" compute networks delete "*)     mutate "$@"; rm -f "$S/network.json" ;;
  *) echo "UNEXPECTED $*" >>"$S/mutations"; exit 1 ;;
esac
STUB
chmod +x "${CLEAN_BIN}/gcloud"

# clean_world NAME — a fresh copy of the live deployment: deletion-protected VM with its disk, the static IP in use by
# it, three netguru rules (Outline's left over), subnet and VPC. Prints the state directory.
clean_world() {
  local s="${CLEAN_BIN}/$1" r
  mkdir -p "$s/fw"
  cp "${FIXTURES}/vm-netguru.json" "$s/vm.json"
  jq -n --arg u "$CLEAN_VM_URL" '{name: "netguru-server", users: [$u]}' >"$s/disk.json"
  jq -n --arg u "$CLEAN_VM_URL" '{name: "netguru-jp-ip", address: "203.0.113.100", status: "IN_USE", users: [$u]}' >"$s/address.json"
  for r in ssh-iap sing-box outline; do
    jq -n --arg n "netguru-server-$r" --arg net "$CLEAN_NET" '{name: $n, network: $net}' >"$s/fw/netguru-server-$r.json"
  done
  jq -n '{name: "netguru-net", description: "managed by netguru"}' >"$s/network.json"
  jq -n '{name: "netguru-net", region: "asia-northeast1"}' >"$s/subnet.json"
  : >"$s/mutations"
  echo "$s"
}
# clean_run STATE [CONFIRM] — run gcp/clean.sh against STATE; stdout+stderr
clean_run() { env CLEAN_STATE="$1" CONFIRM="${2:-}" PATH="${CLEAN_BIN}:${PATH}" gcp/clean.sh 2>&1; }

CW=$(clean_world plan)
expect_fail "clean without CONFIRM only shows the plan"          env -u CONFIRM CLEAN_STATE="$CW" PATH="${CLEAN_BIN}:${PATH}" gcp/clean.sh
expect_ok   "the plan names the VM, the static IP and its address" \
  bash -c "grep -q 'VM netguru-server' <<<\"\$1\" && grep -q 'static IP netguru-jp-ip (203.0.113.100)' <<<\"\$1\"" _ "$(clean_run "$CW")"
expect_eq   "the plan deletes nothing" "$(cat "$CW/mutations")" ""
expect_fail "CONFIRM=1 is not enough: it must be the project ID" env CLEAN_STATE="$CW" CONFIRM=1 PATH="${CLEAN_BIN}:${PATH}" gcp/clean.sh
expect_eq   "a wrong CONFIRM deletes nothing" "$(cat "$CW/mutations")" ""

CW=$(clean_world all)
expect_ok   "clean with CONFIRM=<project> succeeds" env CLEAN_STATE="$CW" CONFIRM=du-hast-mich PATH="${CLEAN_BIN}:${PATH}" gcp/clean.sh
expect_eq   "deletes everything, dependents first, VM protection lifted first" "$(cat "$CW/mutations")" \
  "compute instances update netguru-server --zone=asia-northeast1-a --no-deletion-protection
compute instances delete netguru-server --zone=asia-northeast1-a --delete-disks=all
compute addresses delete netguru-jp-ip --region=asia-northeast1
compute firewall-rules delete netguru-server-outline
compute firewall-rules delete netguru-server-sing-box
compute firewall-rules delete netguru-server-ssh-iap
compute networks subnets delete netguru-net --region=asia-northeast1
compute networks delete netguru-net"
: >"$CW/mutations"
expect_eq   "running it again finds nothing to delete" "$(clean_run "$CW" du-hast-mich | tail -1)" \
  "==> nothing to delete: no netguru resources in project du-hast-mich"
expect_eq   "...and changes nothing" "$(cat "$CW/mutations")" ""

CW=$(clean_world foreign)
jq -n --arg net "$CLEAN_NET" '{name: "someone-elses-rule", network: $net}' >"$CW/fw/someone-elses-rule.json"
clean_run "$CW" du-hast-mich >/dev/null
expect_eq   "a foreign rule keeps the VPC (and subnet); netguru's own resources still go" \
  "$(grep -c 'networks' "$CW/mutations"),$(grep -c 'instances delete\|addresses delete' "$CW/mutations"),$(test -f "$CW/network.json" && echo kept),$(test -f "$CW/fw/someone-elses-rule.json" && echo rule-kept)" \
  "0,2,kept,rule-kept"

CW=$(clean_world othervm)
jq -n --arg net "$CLEAN_NET" '{name: "other-vm", networkInterfaces: [{network: $net}]}' >"$CW/other-vm.json"
expect_ok   "another VM on the network keeps the VPC" \
  bash -c "grep -q 'VPC netguru-net stays: other VMs use it: other-vm' <<<\"\$1\"" _ "$(clean_run "$CW" du-hast-mich)"

CW=$(clean_world notours)
jq 'del(.description)' "$CW/network.json" >"$CW/t" && mv "$CW/t" "$CW/network.json"
clean_run "$CW" du-hast-mich >/dev/null
expect_eq   "a VPC netguru did not create is kept" "$(test -f "$CW/network.json" && echo kept)" "kept"

CW=$(clean_world strangevm)
jq '.tags.items = ["web"]' "$CW/vm.json" >"$CW/t" && mv "$CW/t" "$CW/vm.json"
expect_fail "a same-named VM without netguru's tag is refused" env CLEAN_STATE="$CW" CONFIRM=du-hast-mich PATH="${CLEAN_BIN}:${PATH}" gcp/clean.sh
expect_eq   "...before anything is deleted" "$(cat "$CW/mutations")" ""

CW=$(clean_world sharedip)
jq '.users += ["https://www.googleapis.com/compute/v1/projects/du-hast-mich/zones/asia-northeast1-a/instances/web-1"]' \
  "$CW/address.json" >"$CW/t" && mv "$CW/t" "$CW/address.json"
expect_fail "a static IP used by another VM is refused" env CLEAN_STATE="$CW" CONFIRM=du-hast-mich PATH="${CLEAN_BIN}:${PATH}" gcp/clean.sh
expect_eq   "...before anything is deleted" "$(cat "$CW/mutations")" ""

CW=$(clean_world orphan)
rm "$CW/vm.json"
jq 'del(.users)' "$CW/disk.json" >"$CW/t" && mv "$CW/t" "$CW/disk.json"
clean_run "$CW" du-hast-mich >/dev/null
expect_eq   "a boot disk left over from a deleted VM is deleted" "$(grep 'disks delete' "$CW/mutations")" \
  "compute disks delete netguru-server --zone=asia-northeast1-a"

expect_eq   "make clean passes CONFIRM from the command line" \
  "$(env -u CONFIRM make --no-print-directory -n clean CONFIRM=du-hast-mich)" "CONFIRM='du-hast-mich' gcp/clean.sh"
expect_eq   "make clean ignores a CONFIRM exported in the environment" \
  "$(env CONFIRM=du-hast-mich make --no-print-directory -n clean)" "CONFIRM='' gcp/clean.sh"
expect_eq   "make update-ip ignores a CONFIRM exported in the environment" \
  "$(env CONFIRM=1 make --no-print-directory -n update-ip)" "CONFIRM='' gcp/update-ip.sh"
rm -rf "$CLEAN_BIN"
