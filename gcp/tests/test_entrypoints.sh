# shellcheck shell=bash
# Entry points must reject bad input before touching GCP, and make must run infra before any service.

expect_fail "deploy requires a service argument"       gcp/deploy.sh
expect_fail "deploy rejects services not in SERVICES"  gcp/deploy.sh nope
expect_eq   "deploy explains an unknown service" \
  "$(gcp/deploy.sh nope 2>&1)" \
  "ERROR: unknown service 'nope' (known: outline sing-box)"
expect_eq   "deploy refuses a turned-off service and names its switch" \
  "$(gcp/deploy.sh outline 2>&1)" \
  "ERROR: service 'outline' is turned off: set OUTLINE_ENABLED=true in gcp/config.env"
# make outline / upgrade-outline on a turned-off service: the same refusal, at once, without running infra first.
# (--no-print-directory: under `make test` these are nested makes, which would print "Entering directory".)
expect_eq   "make outline (turned off) runs only the refusing deploy, never infra" \
  "$(make --no-print-directory -n outline)" "gcp/deploy.sh outline"
expect_eq   "make upgrade-outline (turned off) runs only the refusing deploy" \
  "$(make --no-print-directory -n upgrade-outline)" "gcp/deploy.sh outline"
expect_eq   "make outline (turned off) names the switch to set" \
  "$(make --no-print-directory outline 2>&1 | head -1)" \
  "ERROR: service 'outline' is turned off: set OUTLINE_ENABLED=true in gcp/config.env"
expect_fail "show rejects unknown SHOW_FORMAT"         env SHOW_FORMAT=yaml gcp/show.sh
expect_eq   "default make target is help (runs no GCP scripts)" \
  "$(make -n)" "$(make -n help)"
expect_ok   "make help lists core targets" \
  bash -c 'make help | grep -q "update-ip CONFIRM=1" && make help | grep -q "upgrade-sing-box"'
expect_eq   "make all runs infra, then the enabled services in order, then show" \
  "$(make -n all | grep -oE 'gcp/(infra|deploy|show)\.sh( [a-z-]+)?' | tr '\n' '|')" \
  "gcp/infra.sh|gcp/deploy.sh sing-box|gcp/show.sh|"
expect_eq   "make upgrade upgrades each enabled service in order, without touching infra" \
  "$(make -n upgrade | grep -oE '(UPGRADE=yes )?gcp/(infra|deploy)\.sh( [a-z-]+)?' | tr '\n' '|')" \
  "UPGRADE=yes gcp/deploy.sh sing-box|"
expect_fail "deploy rejects UPGRADE other than yes/no" env UPGRADE=maybe gcp/deploy.sh sing-box

# PATH with only bash and dirname: no sing-box and no gcloud, wherever they are installed, so verify never reaches GCP.
NOSB_BIN=$(mktemp -d)
ln -s "$(command -v bash)" "$(command -v dirname)" "$NOSB_BIN/"
expect_fail "verify refuses to run without a local sing-box" env PATH="$NOSB_BIN" gcp/verify.sh
expect_eq   "verify says how to get sing-box" \
  "$(env PATH="$NOSB_BIN" gcp/verify.sh 2>&1 | tail -1)" \
  "ERROR: local sing-box not found on PATH (plan Task 6 Step 1)"
rm -rf "$NOSB_BIN"

# make show writes the profile only when every service answered: one failed SSH must not leave a profile missing
# servers. Two services (Outline switched on in a copy), and only sing-box's JSON call fails.
SHOW_TMP=$(mktemp -d)
cp -r Makefile gcp "$SHOW_TMP/"
sed -i 's/^OUTLINE_ENABLED=.*/OUTLINE_ENABLED="true"/' "$SHOW_TMP/gcp/config.env"
mkdir "$SHOW_TMP/bin"
cat >"$SHOW_TMP/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
if [[ " $* " == *" addresses describe "* ]]; then echo 203.0.113.100; exit 0; fi
script=$(cat) # the VM-side script arrives on stdin
if [[ " $* " != *"SHOW_FORMAT=json"* ]]; then echo "(text)"; exit 0; fi
if [[ "$script" == *"print sing-box client configs"* ]]; then exit 255; fi
echo '[{"type":"shadowsocks","tag":"outline-0","server":"203.0.113.100","server_port":45362,"method":"chacha20-ietf-poly1305","password":"x"}]'
STUB
chmod +x "$SHOW_TMP/bin/gcloud"
printf 'previous\n' >"$SHOW_TMP/netguru-client.json"
expect_fail "make show fails when one service's SSH fails" env PATH="$SHOW_TMP/bin:$PATH" "$SHOW_TMP/gcp/show.sh"
expect_eq   "a failed make show leaves the previous profile untouched" "$(cat "$SHOW_TMP/netguru-client.json")" "previous"
# The Makefile takes SERVICES from lib.sh: switching Outline on adds its deploy step, first.
expect_eq   "with Outline switched on, make all deploys it first" \
  "$(make -s -C "$SHOW_TMP" -n all | grep -oE 'gcp/(infra|deploy|show)\.sh( [a-z-]+)?' | tr '\n' '|')" \
  "gcp/infra.sh|gcp/deploy.sh outline|gcp/deploy.sh sing-box|gcp/show.sh|"
rm -rf "$SHOW_TMP"

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
