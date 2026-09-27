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
  "  [key-0] ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTpwdzA@34.146.224.39:44923/?outline=1
  [alice phone] ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTpwdzM@34.146.224.39:44923/?outline=1"

# verify.sh drives these outbounds through a local sing-box; fields must match sing-box's shadowsocks schema.
expect_eq "json output is sing-box shadowsocks outbounds" \
  "$(vm_fn "$OUTLINE_SHOW" keys_to_outbounds 1.2.3.4 <"${FIXTURES}/outline-access-keys.json" | jq -c .)" \
  '[{"type":"shadowsocks","tag":"outline-0","server":"1.2.3.4","server_port":44923,"method":"chacha20-ietf-poly1305","password":"pw0"},{"type":"shadowsocks","tag":"outline-3","server":"1.2.3.4","server_port":44923,"method":"chacha20-ietf-poly1305","password":"pw3"}]'
