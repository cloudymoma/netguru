# shellcheck shell=bash
# Entry points must reject bad input before touching GCP, and make must run infra before any service.

expect_fail "deploy requires a service argument"       gcp/deploy.sh
expect_fail "deploy rejects services not in SERVICES"  gcp/deploy.sh nope
expect_eq   "deploy explains the rejection" \
  "$(gcp/deploy.sh nope 2>&1)" \
  "ERROR: service 'nope' is not in SERVICES (outline sing-box)"
expect_fail "show rejects unknown SHOW_FORMAT"         env SHOW_FORMAT=yaml gcp/show.sh
expect_eq   "default make target is help (touches no GCP scripts)" \
  "$(make)" "$(make help)"
expect_ok   "make help lists core targets" \
  bash -c 'make help | grep -q "update-ip CONFIRM=1" && make help | grep -q "upgrade-sing-box"'
expect_eq   "make all runs infra, then services in order, then show" \
  "$(make -n all | grep -oE 'gcp/(infra|deploy|show)\.sh( [a-z-]+)?' | tr '\n' '|')" \
  "gcp/infra.sh|gcp/deploy.sh outline|gcp/deploy.sh sing-box|gcp/show.sh|"
expect_eq   "make upgrade upgrades each service in order, without touching infra" \
  "$(make -n upgrade | grep -oE '(UPGRADE=yes )?gcp/(infra|deploy)\.sh( [a-z-]+)?' | tr '\n' '|')" \
  "UPGRADE=yes gcp/deploy.sh outline|UPGRADE=yes gcp/deploy.sh sing-box|"
expect_fail "deploy rejects UPGRADE other than yes/no" env UPGRADE=maybe gcp/deploy.sh outline

expect_fail "verify refuses to run without a local sing-box" env PATH=/usr/bin:/bin gcp/verify.sh
expect_eq   "verify says how to get sing-box" \
  "$(env PATH=/usr/bin:/bin gcp/verify.sh 2>&1 | tail -1)" \
  "ERROR: local sing-box not found on PATH (plan Task 6 Step 1)"

expect_fail "update-ip refuses without CONFIRM=1" env -u CONFIRM gcp/update-ip.sh
expect_eq   "update-ip warns that client configs change" \
  "$(env -u CONFIRM gcp/update-ip.sh 2>&1 | head -1)" \
  "make update-ip gives ${VM_NAME} a NEW public IP: every Outline key, vless:// and hysteria2:// config changes."

# A stopped VM gets no ephemeral IP, so a swap would strand it without one: refuse before any gcloud mutation.
UIP_BIN=$(mktemp -d)
cat >"${UIP_BIN}/gcloud" <<STUB
#!/usr/bin/env bash
if [[ " \$* " == *" instances describe "* ]]; then jq '.status = "TERMINATED"' "${PWD}/${FIXTURES}/vm-netguru.json"; exit 0; fi
if [[ " \$* " == *" addresses describe "* ]]; then echo 203.0.113.100; exit 0; fi
echo "\$*" >>"${UIP_BIN}/mutations"
STUB
chmod +x "${UIP_BIN}/gcloud"
expect_fail "update-ip refuses a stopped VM" env CONFIRM=1 PATH="${UIP_BIN}:${PATH}" gcp/update-ip.sh
expect_eq   "update-ip changes nothing on a stopped VM" "$(cat "${UIP_BIN}/mutations" 2>/dev/null)" ""
rm -rf "$UIP_BIN"
