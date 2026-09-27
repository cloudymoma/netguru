#!/usr/bin/env bash
# VM-side (root): install and configure official sing-box — VLESS-REALITY + Hysteria2 (spec §4.6).
# Env: STATIC_IP UPGRADE(yes|no) SINGBOX_VERSION(latest|X.Y.Z) SINGBOX_TARGET_VERSION (resolved on the workstation, spec §4.10)
#      SINGBOX_GPG_FINGERPRINT SINGBOX_REALITY_PORT SINGBOX_REALITY_SNI
#      SINGBOX_HY2_PORT SINGBOX_HY2_SNI SINGBOX_ENABLE_BBR
set -euo pipefail

ETC=/etc/sing-box
CREDS="${ETC}/credentials.env"
CERT_DIR="${ETC}/certs"
APT_OPTS=(-y -q -o Dpkg::Options::=--force-confold)
PKG_CHANGED=no
PREV_VERSION=""

die() { echo "[sing-box] ERROR: $*" >&2; exit 1; }
log() { echo "[sing-box] $*" >&2; }

enable_bbr() {
  if [[ "${SINGBOX_ENABLE_BBR}" != true ]]; then log "BBR disabled by config"; return; fi
  printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' >/etc/sysctl.d/99-bbr.conf
  sysctl --system >/dev/null
  [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == bbr ]] || die "BBR did not take effect"
}

# singbox_install_action INSTALLED(empty if none) TARGET UPGRADE(yes|no) -> install|upgrade|keep
singbox_install_action() {
  if [[ -z "$1" ]]; then echo install
  elif [[ "$3" == yes && "$1" != "$2" ]]; then echo upgrade
  else echo keep
  fi
}

install_package() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install "${APT_OPTS[@]}" ca-certificates curl gnupg jq openssl
  local key fpr installed action newest
  key=$(mktemp)
  curl -fsSL https://sing-box.app/gpg.key -o "$key"
  fpr=$(gpg --show-keys --with-colons "$key" | awk -F: '/^fpr/{print $10; exit}')
  [[ "$fpr" == "${SINGBOX_GPG_FINGERPRINT}" ]] ||
    die "sing-box GPG key fingerprint ${fpr} != pinned ${SINGBOX_GPG_FINGERPRINT}"
  install -D -m 0644 "$key" /etc/apt/keyrings/sagernet.asc
  rm -f "$key"
  cat >/etc/apt/sources.list.d/sagernet.sources <<'SOURCES'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
SOURCES
  apt-get update -q
  installed=$(dpkg-query -W -f='${Version}' sing-box 2>/dev/null || true)
  action=$(singbox_install_action "$installed" "${SINGBOX_TARGET_VERSION}" "${UPGRADE:-no}")
  if [[ "$action" == keep ]]; then
    log "keeping installed sing-box ${installed} (target ${SINGBOX_TARGET_VERSION:-unresolved}, upgrade=${UPGRADE:-no})"
    return
  fi
  [[ "${SINGBOX_TARGET_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "SINGBOX_TARGET_VERSION not resolved (got '${SINGBOX_TARGET_VERSION}'); run via make"
  newest=$(apt-cache madison sing-box | awk '{print $3}' | sort -V | tail -n1)
  if [[ "${SINGBOX_VERSION}" == latest && "$newest" != "${SINGBOX_TARGET_VERSION}" ]]; then
    die "newest signed sing-box in apt is '${newest}' but GitHub's latest release is ${SINGBOX_TARGET_VERSION} (stale index or not yet published); retry later"
  fi
  grep -qxF "${SINGBOX_TARGET_VERSION}" <<<"$(apt-cache madison sing-box | awk '{print $3}')" ||
    die "sing-box ${SINGBOX_TARGET_VERSION} is not in the signed repo index"
  log "${action}: sing-box ${installed:-none} -> ${SINGBOX_TARGET_VERSION}"
  PREV_VERSION=$installed
  apt-get install "${APT_OPTS[@]}" --allow-downgrades "sing-box=${SINGBOX_TARGET_VERSION}"
  [[ "$(dpkg-query -W -f='${Version}' sing-box)" == "${SINGBOX_TARGET_VERSION}" ]] ||
    die "installed sing-box $(dpkg-query -W -f='${Version}' sing-box) != ${SINGBOX_TARGET_VERSION}"
  PKG_CHANGED=yes
}

# Never leave a package on disk that rejects our config: it would fail at the next restart or reboot.
rollback_package() {
  [[ "$PKG_CHANGED" == yes && -n "$PREV_VERSION" ]] || return 0
  log "rolling back sing-box to ${PREV_VERSION}"
  apt-get install "${APT_OPTS[@]}" --allow-downgrades "sing-box=${PREV_VERSION}"
  PKG_CHANGED=no
}

check_reality_target() {
  local v
  v=$(curl -sS --tlsv1.3 --http2 -o /dev/null -w '%{http_version}' --max-time 10 "https://${SINGBOX_REALITY_SNI}/") ||
    die "cannot reach REALITY target ${SINGBOX_REALITY_SNI} over TLS 1.3"
  [[ "$v" == 2 ]] || die "REALITY target ${SINGBOX_REALITY_SNI} must speak HTTP/2 over TLS 1.3 (got HTTP/${v})"
}

ensure_credentials() {
  if [[ -f "$CREDS" ]]; then
    log "reusing existing credentials"
  else
    log "generating credentials"
    local kp tmp
    kp=$(sing-box generate reality-keypair)
    tmp=$(mktemp "${ETC}/.credentials.XXXXXX")
    {
      echo "VLESS_UUID=$(sing-box generate uuid)"
      echo "REALITY_PRIVATE_KEY=$(awk '/PrivateKey/{print $2}' <<<"$kp")"
      echo "REALITY_PUBLIC_KEY=$(awk '/PublicKey/{print $2}' <<<"$kp")"
      echo "REALITY_SHORT_ID=$(sing-box generate rand 8 --hex)"
      echo "HY2_PASSWORD=$(sing-box generate rand 16 --hex)"
    } >"$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$CREDS"
  fi
  # shellcheck disable=SC1090
  . "$CREDS"
  local v
  for v in VLESS_UUID REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID HY2_PASSWORD; do
    [[ -n "${!v:-}" ]] || die "${v} missing from ${CREDS}"
  done
}

ensure_cert() {
  install -d -m 0700 "$CERT_DIR"
  [[ -f "${CERT_DIR}/hy2.crt" && -f "${CERT_DIR}/hy2.key" ]] && return
  log "generating Hysteria2 self-signed certificate for ${SINGBOX_HY2_SNI}"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
    -subj "/CN=${SINGBOX_HY2_SNI}" -addext "subjectAltName=DNS:${SINGBOX_HY2_SNI}" \
    -keyout "${CERT_DIR}/hy2.key" -out "${CERT_DIR}/hy2.crt" 2>/dev/null
  chmod 600 "${CERT_DIR}/hy2.key"
}

render_singbox_config() {
  jq -n --arg uuid "$VLESS_UUID" --arg priv "$REALITY_PRIVATE_KEY" --arg sid "$REALITY_SHORT_ID" \
    --arg sni "$SINGBOX_REALITY_SNI" --argjson rport "$SINGBOX_REALITY_PORT" \
    --arg pass "$HY2_PASSWORD" --argjson hport "$SINGBOX_HY2_PORT" \
    --arg crt "${CERT_DIR}/hy2.crt" --arg key "${CERT_DIR}/hy2.key" '{
    log: {level: "info"},
    dns: {servers: [{type: "local", tag: "local"}]},
    inbounds: [
      {type: "vless", tag: "vless-reality-in", listen: "::", listen_port: $rport,
       users: [{uuid: $uuid, flow: "xtls-rprx-vision"}],
       tls: {enabled: true, server_name: $sni,
             reality: {enabled: true, handshake: {server: $sni, server_port: 443},
                       private_key: $priv, short_id: [$sid]}}},
      {type: "hysteria2", tag: "hysteria2-in", listen: "::", listen_port: $hport,
       users: [{password: $pass}],
       tls: {enabled: true, alpn: ["h3"], certificate_path: $crt, key_path: $key}}
    ],
    outbounds: [{type: "direct", tag: "direct"}],
    route: {
      default_domain_resolver: "local",
      rules: [
        {action: "resolve", server: "local"},
        {ip_is_private: true, action: "reject"},
        {ip_cidr: ["169.254.0.0/16"], action: "reject"}
      ]
    }
  }'
}

# needs_restart CONFIG_CHANGED PKG_CHANGED IS_ACTIVE -> yes|no
needs_restart() {
  if [[ "$1" == yes || "$2" == yes || "$3" == no ]]; then echo yes; else echo no; fi
}

apply_config() {
  local new="${ETC}/config.json.new" others changed=no active=no
  others=$(find "$ETC" -maxdepth 1 -name '*.json' ! -name config.json)
  [[ -z "$others" ]] || die "unexpected *.json in ${ETC} (sing-box -C would merge them): ${others}"
  render_singbox_config >"$new"
  chmod 600 "$new"
  if ! sing-box check -c "$new"; then
    rm -f "$new"
    rollback_package
    die "sing-box check failed; existing config left untouched"
  fi
  if cmp -s "$new" "${ETC}/config.json"; then rm -f "$new"; else mv "$new" "${ETC}/config.json"; changed=yes; fi
  systemctl enable sing-box >/dev/null 2>&1
  systemctl is-active --quiet sing-box && active=yes
  if [[ "$(needs_restart "$changed" "$PKG_CHANGED" "$active")" == yes ]]; then
    log "restarting sing-box (config changed=${changed}, package changed=${PKG_CHANGED}, was active=${active})"
    systemctl restart sing-box
  else
    log "config and package unchanged; not restarting"
  fi
}

check_end_state() {
  for _ in $(seq 1 10); do
    systemctl is-active --quiet sing-box && break
    sleep 1
  done
  if ! systemctl is-active --quiet sing-box; then
    journalctl -u sing-box -n 30 --no-pager >&2
    die "sing-box is not active"
  fi
  ss -Hltn "sport = :${SINGBOX_REALITY_PORT}" | grep -q . || die "not listening on tcp/${SINGBOX_REALITY_PORT}"
  ss -Hlun "sport = :${SINGBOX_HY2_PORT}" | grep -q . || die "not listening on udp/${SINGBOX_HY2_PORT}"
  log "healthy: sing-box $(dpkg-query -W -f='${Version}' sing-box) on tcp/${SINGBOX_REALITY_PORT} and udp/${SINGBOX_HY2_PORT}"
}

main() {
  install -d -m 0755 "$ETC"
  enable_bbr
  install_package
  check_reality_target
  ensure_credentials
  ensure_cert
  apply_config
  check_end_state
}

[[ -n "${NETGURU_SOURCE_ONLY:-}" ]] || main
