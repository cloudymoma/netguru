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
    : "${HY2_OBFS_PASSWORD:=ffeeddccbbaa99887766554433221100}"
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

# Salamander (on by default): probes without the obfs password get no reply, so the self-signed cert never leaks.
expect_eq "Hysteria2 obfuscates with Salamander by default" \
  "$(jq -c '.inbounds[1].obfs' "${SB_TMP}/server.json")" \
  '{"type":"salamander","password":"ffeeddccbbaa99887766554433221100"}'
SINGBOX_HY2_SALAMANDER=false sb_fn "$SB_INSTALL" render_singbox_config >"${SB_TMP}/server-plain.json"
expect_ok "Salamander off: config still passes 'sing-box check'" sing-box check -c "${SB_TMP}/server-plain.json"
expect_eq "Salamander off: no obfs in the Hysteria2 inbound" \
  "$(jq -c '.inbounds[1] | has("obfs")' "${SB_TMP}/server-plain.json")" "false"

# Server logging defaults to warn: no per-connection lines (info and below record every client IP and destination).
# It can be turned off entirely, or set to any level.
expect_eq "server logging defaults to warn" "$(jq -c '.log' "${SB_TMP}/server.json")" '{"level":"warn"}'
SINGBOX_LOG_ENABLED=false sb_fn "$SB_INSTALL" render_singbox_config >"${SB_TMP}/server-nolog.json"
expect_ok "logging off: config still passes 'sing-box check'" sing-box check -c "${SB_TMP}/server-nolog.json"
expect_eq "logging off: sing-box logging is disabled" "$(jq -c '.log' "${SB_TMP}/server-nolog.json")" '{"disabled":true}'
SINGBOX_LOG_ENABLED=true SINGBOX_LOG_LEVEL=debug sb_fn "$SB_INSTALL" render_singbox_config >"${SB_TMP}/server-log.json"
expect_ok "logging on: config still passes 'sing-box check'" sing-box check -c "${SB_TMP}/server-log.json"
expect_eq "logging on: the configured level is used" "$(jq -c '.log' "${SB_TMP}/server-log.json")" '{"level":"debug"}'
# shellcheck disable=SC2016 # $l is expanded by the inner bash
expect_ok   "every sing-box log level is accepted" \
  bash -c '. gcp/lib.sh; load_service sing-box; for l in trace debug info warn error fatal panic; do SINGBOX_LOG_LEVEL=$l service_validate; done'
expect_fail "an unknown log level is rejected" \
  bash -c '. gcp/lib.sh; SINGBOX_LOG_LEVEL=verbose; load_service sing-box; service_validate'
expect_fail "SINGBOX_LOG_ENABLED must be true or false" \
  bash -c '. gcp/lib.sh; SINGBOX_LOG_ENABLED=on; load_service sing-box; service_validate'

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

# apt-get update does not honor DPkg::Lock::Timeout on /var/lib/apt/lists/lock: apt_update retries until the lock clears.
# shellcheck disable=SC2329
sb_apt_update() {
  local succeed_on=$1 tries="${SB_TMP}/apt-tries"
  : >"$tries"
  sleep() { :; }
  apt-get() {
    echo try >>"$tries"
    ((succeed_on > 0 && $(wc -l <"$tries") >= succeed_on))
  }
  apt_update
}
expect_ok   "sing-box apt_update succeeds once the lists lock clears" vm_fn "$SB_INSTALL" sb_apt_update 3
expect_fail "sing-box apt_update dies after 12 failed attempts"       vm_fn "$SB_INSTALL" sb_apt_update 0

# systemd reports the Type=simple unit active as soon as it forks, before sing-box binds its ports.
# sb_end_state N — check_end_state with both ports bound from the Nth ss probe on (0 = never bound).
# shellcheck disable=SC2329 # the stubs are called by the sourced check_end_state
sb_end_state() {
  local bound_from=$1 probes="${SB_TMP}/ss-probes"
  : >"$probes"
  systemctl() { return 0; }
  journalctl() { :; }
  sleep() { :; }
  dpkg-query() { echo 1.14.2; }
  ss() {
    echo probe >>"$probes" # a file, not a variable: each ss call runs in a pipeline subshell
    if ((bound_from > 0 && $(wc -l <"$probes") >= bound_from)); then echo "LISTEN 0 4096 *:443 *:*"; fi
  }
  check_end_state
}
expect_ok   "health check waits for the ports to bind after systemd reports active"  vm_fn "$SB_INSTALL" sb_end_state 3
expect_fail "health check fails when the ports never bind"                          vm_fn "$SB_INSTALL" sb_end_state 0

# Turning sing-box back on (after SINGBOX_ENABLED=false disabled it at boot) must leave it enabled, or the next reboot
# brings it down. Both checks hold where errexit is off, as in these tests and in main's `if ! (check_end_state)`.
# shellcheck disable=SC2329 # stubs invoked by the sourced check_end_state
sb_end_state_not_enabled() {
  systemctl() { [[ "$1" != is-enabled ]]; }
  journalctl() { :; }
  sleep() { :; }
  dpkg-query() { echo 1.14.2; }
  ss() { echo "LISTEN 0 4096 *:443 *:*"; }
  check_end_state
}
expect_fail "health check fails when sing-box is not enabled at boot" vm_fn "$SB_INSTALL" sb_end_state_not_enabled
# shellcheck disable=SC2034,SC2329 # globals and stubs are used by the sourced apply_config
sb_apply_enable_fails() {
  ETC="${SB_TMP}/etc-apply"
  mkdir -p "$ETC"
  render_singbox_config() { echo '{}'; }
  sing-box() { return 0; }
  systemctl() {
    if [[ " $* " == *" enable "* ]]; then echo "Failed to enable unit: Unit file sing-box.service is masked." >&2; return 1; fi
    return 0
  }
  apply_config
}
expect_fail "a failed enable stops the install" vm_fn "$SB_INSTALL" sb_apply_enable_fails
expect_eq   "...and says why" "$(vm_fn "$SB_INSTALL" sb_apply_enable_fails 2>&1 | tail -1)" \
  "[sing-box] ERROR: cannot enable sing-box at boot"

# SINGBOX_ENABLED=false: make infra stops sing-box and disables it at boot, keeping /etc/sing-box (credentials).
# sb_disable STATE — remote-disable main against a stubbed systemctl; prints its mutating calls. STATE: absent|running|stopped
SB_DISABLE=gcp/services/sing-box/remote-disable.sh
# shellcheck disable=SC2329 # stub invoked by the sourced main
sb_disable() {
  local state=$1 log="${SB_TMP}/disable-log"
  : >"$log"
  systemctl() {
    case "$1" in
      cat) [[ "$state" != absent ]] ;;
      is-enabled | is-active) [[ "$state" == running ]] ;;
      *) echo "$*" >>"$log" ;;
    esac
  }
  main
  cat "$log"
}
expect_eq "turning sing-box off stops it and disables it at boot" \
  "$(vm_fn "$SB_DISABLE" sb_disable running 2>/dev/null)" "disable --now sing-box"
expect_eq "an already stopped sing-box is left alone" "$(vm_fn "$SB_DISABLE" sb_disable stopped 2>/dev/null)" ""
expect_eq "no sing-box installed: nothing to do"      "$(vm_fn "$SB_DISABLE" sb_disable absent 2>/dev/null)" ""

# Credentials are generated once and reused forever: a file with a missing value must never be persisted.
# shellcheck disable=SC2034,SC2329 # globals and the sing-box stub are used by the sourced ensure_credentials
sb_creds() {
  local fail_uuid=$1
  ETC="${SB_TMP}/etc-${fail_uuid}"
  CREDS="${ETC}/credentials.env"
  mkdir -p "$ETC"
  if [[ "$fail_uuid" == yes ]]; then
    sing-box() { if [[ "$2" == uuid ]]; then return 1; fi; command sing-box "$@"; }
  fi
  ensure_credentials
}
expect_ok   "credentials are generated when absent"                    vm_fn "$SB_INSTALL" sb_creds no
expect_eq   "generated credentials are complete and owner-only" \
  "$(stat -c %a "${SB_TMP}/etc-no/credentials.env"),$(grep -c '^[A-Z0-9_]*=.' "${SB_TMP}/etc-no/credentials.env")" "600,6"
expect_fail "a failed generator step stops the install"                vm_fn "$SB_INSTALL" sb_creds yes
expect_fail "a failed generator step persists no credentials file"     test -e "${SB_TMP}/etc-yes/credentials.env"

# VMs installed before Salamander get only the obfs password added; the values clients already have never change.
# shellcheck disable=SC2034 # read by the sourced ensure_credentials
sb_creds_old() { ETC="${SB_TMP}/etc-old"; CREDS="${ETC}/credentials.env"; ensure_credentials; }
mkdir -p "${SB_TMP}/etc-old"
grep -v '^HY2_OBFS_PASSWORD=' "${SB_TMP}/etc-no/credentials.env" >"${SB_TMP}/etc-old/credentials.env"
chmod 600 "${SB_TMP}/etc-old/credentials.env"
cp "${SB_TMP}/etc-old/credentials.env" "${SB_TMP}/creds-before"
expect_ok   "pre-Salamander credentials are accepted"                  vm_fn "$SB_INSTALL" sb_creds_old
expect_eq   "existing credential values are kept as they were" \
  "$(grep -v '^HY2_OBFS_PASSWORD=' "${SB_TMP}/etc-old/credentials.env")" "$(cat "${SB_TMP}/creds-before")"
expect_ok   "re-running keeps the added obfs password"                 vm_fn "$SB_INSTALL" sb_creds_old
expect_eq   "exactly one obfs password is added, owner-only" \
  "$(grep -c '^HY2_OBFS_PASSWORD=[0-9a-f]\{32\}$' "${SB_TMP}/etc-old/credentials.env"),$(stat -c %a "${SB_TMP}/etc-old/credentials.env")" \
  "1,600"

# Clients verify the Hysteria2 cert against SINGBOX_HY2_SNI (JSON profile) and pin its hash (URI): keep it while
# the SNI is unchanged, replace it when the SNI changes.
# shellcheck disable=SC2034 # read by the sourced ensure_cert
sb_cert() { CERT_DIR="${SB_TMP}/certs"; SINGBOX_HY2_SNI=$1; ensure_cert && echo "$CERT_CHANGED"; }
sb_cert_fpr() { openssl x509 -in "${SB_TMP}/certs/hy2.crt" -noout -fingerprint -sha256; }
expect_eq "initial cert generation marks CERT_CHANGED=yes" "$(vm_fn "$SB_INSTALL" sb_cert a.example.com 2>/dev/null)" "yes"
SB_FPR=$(sb_cert_fpr)
expect_eq "re-deploy with the same SNI marks CERT_CHANGED=no" "$(vm_fn "$SB_INSTALL" sb_cert a.example.com 2>/dev/null)" "no"
expect_eq "re-deploy with the same SNI keeps the cert (clients pin it)" "$(sb_cert_fpr)" "$SB_FPR"
expect_eq "a changed SNI marks CERT_CHANGED=yes" "$(vm_fn "$SB_INSTALL" sb_cert b.example.com 2>/dev/null)" "yes"
expect_ok "a changed SNI gets a cert valid for the new name" \
  bash -c "openssl x509 -in '${SB_TMP}/certs/hy2.crt' -noout -checkhost b.example.com | grep -q 'does match'"

expect_eq "VLESS-REALITY share URI" \
  "$(REALITY_PUBLIC_KEY=PUBKEY sb_fn "$SB_SHOW" vless_uri)" \
  "vless://11111111-2222-3333-4444-555555555555@1.2.3.4:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.yahoo.co.jp&fp=chrome&pbk=PUBKEY&sid=0123456789abcdef&type=tcp&headerType=none#netguru-reality"
expect_eq "Hysteria2 share URI carries the Salamander password and the cert pin" \
  "$(sb_fn "$SB_SHOW" hy2_uri)" \
  "hysteria2://00112233445566778899aabbccddeeff@1.2.3.4:8443?obfs=salamander&obfs-password=ffeeddccbbaa99887766554433221100&sni=www.yahoo.co.jp&alpn=h3&insecure=1&pinSHA256=ABCDEF#netguru-hy2"
expect_eq "Salamander off: the share URI has no obfs" \
  "$(SINGBOX_HY2_SALAMANDER=false sb_fn "$SB_SHOW" hy2_uri)" \
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
expect_eq "Hysteria2 client uses the server's Salamander password" \
  "$(jq -c '.[1].obfs' "${SB_TMP}/outbounds.json")" \
  '{"type":"salamander","password":"ffeeddccbbaa99887766554433221100"}'
expect_eq "Salamander off: the Hysteria2 client has no obfs" \
  "$(SINGBOX_HY2_SALAMANDER=false sb_fn "$SB_SHOW" client_outbounds | jq -c '.[1] | has("obfs")')" "false"

# A VM whose credentials predate Salamander (not redeployed yet) must not get a client config that cannot connect.
mkdir -p "${SB_TMP}/show-etc/certs"
grep -v '^HY2_OBFS_PASSWORD=' "${SB_TMP}/etc-no/credentials.env" >"${SB_TMP}/show-etc/credentials.env"
cp "${SB_TMP}/hy2.crt" "${SB_TMP}/show-etc/certs/hy2.crt"
# shellcheck disable=SC2034 # read by the sourced main
sb_show_old() { ETC="${SB_TMP}/show-etc"; SHOW_FORMAT=json; STATIC_IP=1.2.3.4; main; }
expect_fail "show refuses Salamander until the VM has an obfs password" vm_fn "$SB_SHOW" sb_show_old

# make show prints a whole profile that the sing-box apps accept as pasted; a bare outbounds array is rejected by them.
vm_fn "$OUTLINE_SHOW" keys_to_outbounds 1.2.3.4 <"${FIXTURES}/outline-access-keys.json" |
  jq -s 'add' - "${SB_TMP}/outbounds.json" | jq -s 'add' | client_profile >"${SB_TMP}/profile.json"
expect_ok "client profile passes 'sing-box check' (1.14.2)" sing-box check -c "${SB_TMP}/profile.json"
expect_eq "client profile offers every service, REALITY by default" \
  "$(jq -c '.outbounds[0] | [.tag, .default, .outbounds]' "${SB_TMP}/profile.json")" \
  '["proxy","netguru-reality",["outline-0","outline-3","netguru-reality","netguru-hy2"]]'
expect_eq "client profile sends private destinations direct, everything else through the proxy" \
  "$(jq -c '.route | [(.rules[] | select(.ip_is_private) | .outbound), .final]' "${SB_TMP}/profile.json")" \
  '["direct","proxy"]'
expect_eq "client profile defaults to the first server when REALITY is absent" \
  "$(vm_fn "$OUTLINE_SHOW" keys_to_outbounds 1.2.3.4 <"${FIXTURES}/outline-access-keys.json" | client_profile | jq -r '.outbounds[0].default')" \
  "outline-0"
expect_fail "client profile refuses an empty server list" client_profile <<<'[]'

# The profile file holds client secrets: owner-only even when it replaces an older, looser file; never clobbered by a failure.
printf 'old\n' >"${SB_TMP}/netguru-client.json"
chmod 644 "${SB_TMP}/netguru-client.json"
write_client_profile "${SB_TMP}/netguru-client.json" <"${SB_TMP}/outbounds.json"
expect_ok "written profile file passes 'sing-box check'" sing-box check -c "${SB_TMP}/netguru-client.json"
expect_eq "written profile file is readable only by its owner" "$(stat -c %a "${SB_TMP}/netguru-client.json")" "600"
expect_fail "writing a profile with no servers fails" write_client_profile "${SB_TMP}/netguru-client.json" <<<'[]'
expect_ok "a failed write leaves the previous profile intact" sing-box check -c "${SB_TMP}/netguru-client.json"
printf 'elsewhere\n' >"${SB_TMP}/elsewhere"
ln -s "${SB_TMP}/elsewhere" "${SB_TMP}/linked.json"
write_client_profile "${SB_TMP}/linked.json" <"${SB_TMP}/outbounds.json"
expect_eq "a symlinked profile path is replaced, never written through" \
  "$(cat "${SB_TMP}/elsewhere"),$(test -L "${SB_TMP}/linked.json" && echo link || echo file)" "elsewhere,file"

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
