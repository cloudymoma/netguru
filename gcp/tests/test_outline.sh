# shellcheck shell=bash
# The installer must only run on a clean VM: any partial state would get its keys/prefix/cert regenerated.
OUTLINE_INSTALL=gcp/services/outline/remote-install.sh
OUTLINE_SHOW=gcp/services/outline/show.sh

expect_eq "clean VM installs"                "$(vm_fn "$OUTLINE_INSTALL" outline_state no no)"   "fresh"
expect_eq "existing install is adopted"      "$(vm_fn "$OUTLINE_INSTALL" outline_state yes yes)" "adopt"
expect_eq "container without state refuses"  "$(vm_fn "$OUTLINE_INSTALL" outline_state yes no)"  "partial"
expect_eq "state without container refuses"  "$(vm_fn "$OUTLINE_INSTALL" outline_state no yes)"  "partial"

# An upgrade is a no-op when the verified digest already runs, and a recreate otherwise.
OUTLINE_T=quay.io/outline/shadowbox@sha256:545c6f7c7261bb30ae1dffe24a6fca5f8512f5d17c72cfb9e410e7e655444e62
expect_eq "target digest already running: keep" "$(vm_fn "$OUTLINE_INSTALL" outline_upgrade_action "$OUTLINE_T" "$OUTLINE_T")" "keep"
expect_eq "other digest running: recreate" \
  "$(vm_fn "$OUTLINE_INSTALL" outline_upgrade_action "quay.io/outline/shadowbox@sha256:$(printf '0%.0s' {1..64})" "$OUTLINE_T")" "recreate"
expect_eq "no repo digest known: recreate"  "$(vm_fn "$OUTLINE_INSTALL" outline_upgrade_action "" "$OUTLINE_T")" "recreate"

# Users identify keys by label; unnamed keys still need one.
expect_eq "text output labels unnamed keys by id" \
  "$(vm_fn "$OUTLINE_SHOW" keys_to_text <"${FIXTURES}/outline-access-keys.json")" \
  "  [key-0] ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTpwdzA@203.0.113.100:45362/?outline=1
  [alice phone] ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTpwdzM@203.0.113.100:45362/?outline=1"

# verify.sh drives these outbounds through a local sing-box; fields must match sing-box's shadowsocks schema.
expect_eq "json output is sing-box shadowsocks outbounds" \
  "$(vm_fn "$OUTLINE_SHOW" keys_to_outbounds 1.2.3.4 <"${FIXTURES}/outline-access-keys.json" | jq -c .)" \
  '[{"type":"shadowsocks","tag":"outline-0","server":"1.2.3.4","server_port":45362,"method":"chacha20-ietf-poly1305","password":"pw0"},{"type":"shadowsocks","tag":"outline-3","server":"1.2.3.4","server_port":45362,"method":"chacha20-ietf-poly1305","password":"pw3"}]'

# Fresh install strips the single Watchtower launch line after SHA-256 check; 0 or 2 occurrences must fail.
OUTLINE_TMP=$(mktemp -d)
WT_LINE='  run_step "Starting Watchtower" start_watchtower'
printf 'before\n%s\nafter\n' "$WT_LINE" >"${OUTLINE_TMP}/one.sh"
printf 'before\nafter\n' >"${OUTLINE_TMP}/zero.sh"
printf 'before\n%s\n%s\nafter\n' "$WT_LINE" "$WT_LINE" >"${OUTLINE_TMP}/two.sh"

expect_ok   "installer with one watchtower line is stripped" vm_fn "$OUTLINE_INSTALL" strip_installer_watchtower "${OUTLINE_TMP}/one.sh"
expect_eq   "only the watchtower line is removed"            "$(cat "${OUTLINE_TMP}/one.sh")" $'before\nafter'
expect_fail "installer without watchtower line is rejected"  vm_fn "$OUTLINE_INSTALL" strip_installer_watchtower "${OUTLINE_TMP}/zero.sh"
expect_fail "installer with two watchtower lines is rejected" vm_fn "$OUTLINE_INSTALL" strip_installer_watchtower "${OUTLINE_TMP}/two.sh"

# The installer prints Outline Manager's {"apiUrl": …} credential (the API's secret prefix) to stdout; it must not
# leave the VM, while progress lines still stream and an installer failure still fails the deploy.
cat >"${OUTLINE_TMP}/installer.sh" <<'SH'
echo "> Starting Shadowbox ........ OK"
printf '\033[1;32m{"apiUrl":"https://203.0.113.100:15634/c2VjcmV0","certSha256":"AB12"}\033[0m\n'
echo "- Management port 15634, for TCP"
exit "$1"
SH
expect_eq   "installer output drops only the credential line" \
  "$(vm_fn "$OUTLINE_INSTALL" run_installer "${OUTLINE_TMP}/installer.sh" 0)" \
  $'> Starting Shadowbox ........ OK\n- Management port 15634, for TCP'
expect_ok   "installer success passes through the filter" vm_fn "$OUTLINE_INSTALL" run_installer "${OUTLINE_TMP}/installer.sh" 0
expect_fail "installer failure survives the filter"       vm_fn "$OUTLINE_INSTALL" run_installer "${OUTLINE_TMP}/installer.sh" 3
rm -rf "$OUTLINE_TMP"
