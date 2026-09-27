# shellcheck shell=bash
# The rendered config is what clients connect to: it must be valid for the pinned sing-box, block private
# destinations, and be byte-stable across re-runs so re-deploys don't restart the service.
SB_INSTALL=gcp/services/sing-box/remote-install.sh
SB_SHOW=gcp/services/sing-box/show.sh
command -v sing-box >/dev/null || _fail "local sing-box not on PATH (plan Task 6 Step 1) — sing-box tests cannot run"

SB_TMP=$(mktemp -d)
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
  -subj "/CN=${SINGBOX_HY2_SNI}" -addext "subjectAltName=DNS:${SINGBOX_HY2_SNI}" \
  -keyout "${SB_TMP}/hy2.key" -out "${SB_TMP}/hy2.crt" 2>/dev/null
SB_KEYPAIR=$(sing-box generate reality-keypair 2>/dev/null)

# sb_fn SCRIPT FN... — call FN with fixed test credentials; prefix assignments override defaults.
# shellcheck disable=SC2034 # assignments are read by the sourced script's functions
sb_fn() {
  local script=$1; shift
  (
    NETGURU_SOURCE_ONLY=1
    # shellcheck disable=SC1090
    . "$script"
    CERT_DIR=$SB_TMP
    : "${STATIC_IP:=1.2.3.4}"
    : "${VLESS_UUID:=11111111-2222-3333-4444-555555555555}"
    : "${REALITY_PRIVATE_KEY:=$(awk '/PrivateKey/{print $2}' <<<"$SB_KEYPAIR")}"
    : "${REALITY_PUBLIC_KEY:=$(awk '/PublicKey/{print $2}' <<<"$SB_KEYPAIR")}"
    : "${REALITY_SHORT_ID:=0123456789abcdef}"
    : "${HY2_PASSWORD:=00112233445566778899aabbccddeeff}"
    : "${HY2_CERT_SHA256:=ABCDEF}"
    HY2_CERT_PEM=$(cat "${SB_TMP}/hy2.crt")
    "$@"
  )
}

sb_fn "$SB_INSTALL" render_singbox_config >"${SB_TMP}/server.json"
expect_ok "rendered server config passes 'sing-box check' (1.14.2)" sing-box check -c "${SB_TMP}/server.json"
expect_eq "rendering is deterministic (re-deploy compares equal, no restart)" \
  "$(sb_fn "$SB_INSTALL" render_singbox_config | sha256sum)" "$(sha256sum <"${SB_TMP}/server.json")"
expect_eq "domains are resolved before the private-IP reject rules" \
  "$(jq -r '[.route.rules[].action] | join(",")' "${SB_TMP}/server.json")" "resolve,reject,reject"
expect_eq "private and link-local (metadata) destinations are rejected" \
  "$(jq -c '[.route.rules[1].ip_is_private, .route.rules[2].ip_cidr]' "${SB_TMP}/server.json")" \
  '[true,["169.254.0.0/16"]]'
expect_eq "inbounds are REALITY on tcp 443 and Hysteria2 on 8443" \
  "$(jq -r '[.inbounds[] | "\(.type):\(.listen_port)"] | join(",")' "${SB_TMP}/server.json")" \
  "vless:443,hysteria2:8443"

expect_eq "restart when config changed"        "$(vm_fn "$SB_INSTALL" needs_restart yes no yes)" "yes"
expect_eq "restart when package upgraded"      "$(vm_fn "$SB_INSTALL" needs_restart no yes yes)" "yes"
expect_eq "start when service inactive"        "$(vm_fn "$SB_INSTALL" needs_restart no no no)"   "yes"
expect_eq "no restart on unchanged re-run"     "$(vm_fn "$SB_INSTALL" needs_restart no no yes)"  "no"

# First install and explicit upgrades change the package; plain re-deploys never do.
expect_eq "not installed: install"            "$(vm_fn "$SB_INSTALL" singbox_install_action "" 1.14.2 no)"      "install"
expect_eq "re-deploy keeps an older version"  "$(vm_fn "$SB_INSTALL" singbox_install_action 1.14.1 1.14.2 no)"  "keep"
expect_eq "upgrade moves to the target"       "$(vm_fn "$SB_INSTALL" singbox_install_action 1.14.1 1.14.2 yes)" "upgrade"
expect_eq "upgrade at target is a no-op"      "$(vm_fn "$SB_INSTALL" singbox_install_action 1.14.2 1.14.2 yes)" "keep"

# main() calls rollback_package inside `if !`, where errexit is off: a failed apt-get must still return non-zero.
# shellcheck disable=SC2034,SC2329 # globals and the apt-get stub are used by the sourced rollback_package
sb_rollback() {
  local apt_status=$1
  PKG_CHANGED=yes
  PREV_VERSION=1.14.1
  apt-get() { return "$apt_status"; }
  rollback_package
}
expect_ok   "rollback succeeds when apt-get succeeds"          vm_fn "$SB_INSTALL" sb_rollback 0
expect_fail "rollback fails when apt-get fails (errexit off)"  vm_fn "$SB_INSTALL" sb_rollback 100

expect_eq "VLESS-REALITY share URI" \
  "$(REALITY_PUBLIC_KEY=PUBKEY sb_fn "$SB_SHOW" vless_uri)" \
  "vless://11111111-2222-3333-4444-555555555555@1.2.3.4:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.yahoo.co.jp&fp=chrome&pbk=PUBKEY&sid=0123456789abcdef&type=tcp&headerType=none#netguru-reality"
expect_eq "Hysteria2 share URI carries the cert pin" \
  "$(sb_fn "$SB_SHOW" hy2_uri)" \
  "hysteria2://00112233445566778899aabbccddeeff@1.2.3.4:8443?sni=www.yahoo.co.jp&alpn=h3&insecure=1&pinSHA256=ABCDEF#netguru-hy2"

sb_fn "$SB_SHOW" client_outbounds >"${SB_TMP}/outbounds.json"
jq '{outbounds: .}' "${SB_TMP}/outbounds.json" >"${SB_TMP}/client.json"
expect_ok "client outbounds pass 'sing-box check'" sing-box check -c "${SB_TMP}/client.json"
expect_eq "Hysteria2 client trusts only the pinned cert, never insecure" \
  "$(jq -c '.[1].tls | [has("insecure"), (.certificate | length > 0), .server_name]' "${SB_TMP}/outbounds.json")" \
  '[false,true,"www.yahoo.co.jp"]'
expect_eq "REALITY client uses chrome uTLS and the server public key" \
  "$(jq -r '.[0].tls | [.utls.fingerprint, (.reality.public_key | length > 0)] | map(tostring) | join(",")' "${SB_TMP}/outbounds.json")" \
  "chrome,true"

# GPG keyring extraction must reject extra keys (one or two armor blocks) and wrong pins, and export only the pinned key.
SB_GPG_GH=$(mktemp -d)
chmod 700 "$SB_GPG_GH"
gpg --homedir "$SB_GPG_GH" --batch --quiet --import "${FIXTURES}/sagernet-gpg.asc"
gpg --homedir "$SB_GPG_GH" --batch --passphrase "" --pinentry-mode loopback --quiet \
  --quick-generate-key "extra@example.com" ed25519 sign never
gpg --homedir "$SB_GPG_GH" --armor --export >"${SB_TMP}/one-block-two-keys.asc"
gpg --homedir "$SB_GPG_GH" --armor --export "extra@example.com" >"${SB_TMP}/extra-only.asc"
printf '%s\n%s\n' "$(cat "${FIXTURES}/sagernet-gpg.asc")" "$(cat "${SB_TMP}/extra-only.asc")" >"${SB_TMP}/two-blocks.asc"
gpgconf --homedir "$SB_GPG_GH" --kill all 2>/dev/null || true
rm -rf "$SB_GPG_GH"

expect_ok "genuine SagerNet key is accepted and exported" \
  vm_fn "$SB_INSTALL" extract_pinned_gpg_key "${FIXTURES}/sagernet-gpg.asc" "${SINGBOX_GPG_FINGERPRINT}" "${SB_TMP}/sagernet.gpg"
expect_eq "exported keyring contains solely the pinned primary key" \
  "$(gpg --show-keys --with-colons "${SB_TMP}/sagernet.gpg" | awk -F: '$1=="pub"{want=1;next} want&&$1=="fpr"{print $10; want=0}')" \
  "${SINGBOX_GPG_FINGERPRINT}"
expect_fail "genuine key + extra key in one armor block is rejected" \
  vm_fn "$SB_INSTALL" extract_pinned_gpg_key "${SB_TMP}/one-block-two-keys.asc" "${SINGBOX_GPG_FINGERPRINT}" "${SB_TMP}/bad1.gpg"
expect_fail "genuine key + second armor block is rejected" \
  vm_fn "$SB_INSTALL" extract_pinned_gpg_key "${SB_TMP}/two-blocks.asc" "${SINGBOX_GPG_FINGERPRINT}" "${SB_TMP}/bad2.gpg"
expect_fail "wrong pinned fingerprint is rejected" \
  vm_fn "$SB_INSTALL" extract_pinned_gpg_key "${FIXTURES}/sagernet-gpg.asc" "$(printf '0%.0s' {1..40})" "${SB_TMP}/bad3.gpg"
rm -rf "$SB_TMP"
