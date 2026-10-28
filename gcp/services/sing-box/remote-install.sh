#!/usr/bin/env bash
# VM-side (root): install and configure official sing-box — VLESS-REALITY + Hysteria2 (spec §4.6).
# Env: STATIC_IP UPGRADE(yes|no) SINGBOX_VERSION(latest|X.Y.Z) SINGBOX_TARGET_VERSION (resolved on the workstation, spec §4.10)
#      SINGBOX_GPG_FINGERPRINT SINGBOX_REALITY_PORT SINGBOX_REALITY_SNI
#      SINGBOX_HY2_PORT SINGBOX_HY2_SNI SINGBOX_ENABLE_BBR
set -euo pipefail

ETC=/etc/sing-box
CREDS="${ETC}/credentials.env"
CERT_DIR="${ETC}/certs"
APT_OPTS=(-y -q -o DPkg::Lock::Timeout=120 -o Acquire::Retries=3 -o Dpkg::Options::=--force-confold) # wait out unattended-upgrades
PKG_CHANGED=no
CERT_CHANGED=no
PREV_VERSION=""

die() { echo "[sing-box] ERROR: $*" >&2; exit 1; }
log() { echo "[sing-box] $*" >&2; }
warn() { echo "[sing-box] WARN: $*" >&2; }

# DPkg::Lock::Timeout only covers the dpkg locks; apt-get update takes /var/lib/apt/lists/lock without waiting.
apt_update() {
  local i
  for i in $(seq 1 12); do
    apt-get "${APT_OPTS[@]}" update && return 0
    log "apt-get update failed (attempt ${i}/12; apt-daily may hold the lists lock); retrying in 10s"
    sleep 10
  done
  die "apt-get update failed after 12 attempts"
}

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

# extract_pinned_gpg_key KEY_FILE PINNED_FPR OUT_FILE — fail unless KEY_FILE holds one armor block
# whose sole primary key is PINNED_FPR; write only that re-exported binary key to OUT_FILE.
extract_pinned_gpg_key() {
  local key_file=$1 pinned_fpr=$2 out_file=$3 blocks gh fprs tmp
  blocks=$(grep -cxFe '-----BEGIN PGP PUBLIC KEY BLOCK-----' "$key_file" || true)
  [[ "$blocks" == 1 ]] || die "expected 1 PGP key block in ${key_file}, got ${blocks}"
  gh=$(mktemp -d)
  chmod 700 "$gh"
  gpg --homedir "$gh" --batch --quiet --import "$key_file" 2>/dev/null ||
    { rm -rf "$gh"; die "gpg failed to import ${key_file}"; }
  fprs=$(gpg --homedir "$gh" --batch --with-colons --list-keys |
    awk -F: '$1 == "pub" { want = 1; next } want && $1 == "fpr" { print $10; want = 0 }')
  if [[ "$fprs" != "$pinned_fpr" ]]; then
    rm -rf "$gh"
    die "sing-box GPG key fingerprint(s) '${fprs//$'\n'/,}' != pinned ${pinned_fpr}"
  fi
  tmp="${gh}/pinned.gpg"
  gpg --homedir "$gh" --batch --export "$pinned_fpr" >"$tmp"
  [[ -s "$tmp" ]] || { rm -rf "$gh"; die "gpg export produced an empty keyring for ${pinned_fpr}"; }
  install -D -m 0644 "$tmp" "$out_file"
  rm -rf "$gh"
}

install_package() {
  export DEBIAN_FRONTEND=noninteractive
  apt_update
  apt-get "${APT_OPTS[@]}" install ca-certificates curl gnupg jq openssl
  local key installed action newest
  key=$(mktemp)
  curl -fsSL --retry 3 --max-time 30 https://sing-box.app/gpg.key -o "$key"
  extract_pinned_gpg_key "$key" "${SINGBOX_GPG_FINGERPRINT}" /etc/apt/keyrings/sagernet.gpg
  rm -f "$key"
  cat >/etc/apt/sources.list.d/sagernet.sources <<'SOURCES'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.gpg
SOURCES
  apt_update
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
# Explicit `|| return 1`: main() calls this inside `if !`, where errexit is off.
rollback_package() {
  [[ "$PKG_CHANGED" == yes && -n "$PREV_VERSION" ]] || return 0
  log "rolling back sing-box to ${PREV_VERSION}"
  apt-get install "${APT_OPTS[@]}" --allow-downgrades "sing-box=${PREV_VERSION}" || return 1
  PKG_CHANGED=no
}

check_reality_target() {
  local v
  v=$(curl -sS --tlsv1.3 --http2 -o /dev/null -w '%{http_version}' --retry 3 --max-time 10 "https://${SINGBOX_REALITY_SNI}/") ||
    die "cannot reach REALITY target ${SINGBOX_REALITY_SNI} over TLS 1.3"
  [[ "$v" == 2 ]] || die "REALITY target ${SINGBOX_REALITY_SNI} must speak HTTP/2 over TLS 1.3 (got HTTP/${v})"
}

# A generated file is validated before it becomes $CREDS: once there, it is reused on every later deploy.
ensure_credentials() {
  local src=$CREDS v
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
    src=$tmp
  fi
  # shellcheck disable=SC1090
  . "$src"
  for v in VLESS_UUID REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID HY2_PASSWORD; do
    [[ -n "${!v:-}" ]] || { [[ "$src" == "$CREDS" ]] || rm -f "$src"; die "${v} missing from ${src}"; }
  done
  [[ "$src" == "$CREDS" ]] || mv "$src" "$CREDS"
}

# Keep the cert while it matches SINGBOX_HY2_SNI (clients pin it); mark CERT_CHANGED when replaced so sing-box restarts.
# -checkhost exits 0 on a mismatch in OpenSSL 3.0 (Debian 12): match its output instead.
ensure_cert() {
  install -d -m 0700 "$CERT_DIR"
  if [[ -s "${CERT_DIR}/hy2.key" ]] && openssl x509 -in "${CERT_DIR}/hy2.crt" -noout \
    -checkhost "${SINGBOX_HY2_SNI}" 2>/dev/null | grep -q ' does match '; then
    return
  fi
  log "generating Hysteria2 self-signed certificate for ${SINGBOX_HY2_SNI}"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
    -subj "/CN=${SINGBOX_HY2_SNI}" -addext "subjectAltName=DNS:${SINGBOX_HY2_SNI}" \
    -keyout "${CERT_DIR}/hy2.key" -out "${CERT_DIR}/hy2.crt" 2>/dev/null
  chmod 600 "${CERT_DIR}/hy2.key"
  CERT_CHANGED=yes
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
  local new="${ETC}/config.json.new" others changed=${CERT_CHANGED} active=no
  others=$(find "$ETC" -maxdepth 1 -name '*.json' ! -name config.json)
  [[ -z "$others" ]] || die "unexpected *.json in ${ETC} (sing-box -C would merge them): ${others}"
  (umask 077 && render_singbox_config >"$new") # holds private keys: never world-readable
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

# listening tcp|udp PORT — true once a socket is bound on PORT.
listening() {
  local flags=-Hltn
  [[ "$1" == udp ]] && flags=-Hlun
  ss "$flags" "sport = :$2" | grep -q .
}

# systemd reports the Type=simple unit active as soon as it forks, before sing-box binds its ports: poll all three.
check_end_state() {
  local problem
  for _ in $(seq 1 10); do
    if ! systemctl is-active --quiet sing-box; then problem="sing-box is not active"
    elif ! listening tcp "$SINGBOX_REALITY_PORT"; then problem="not listening on tcp/${SINGBOX_REALITY_PORT}"
    elif ! listening udp "$SINGBOX_HY2_PORT"; then problem="not listening on udp/${SINGBOX_HY2_PORT}"
    else
      log "healthy: sing-box $(dpkg-query -W -f='${Version}' sing-box) on tcp/${SINGBOX_REALITY_PORT} and udp/${SINGBOX_HY2_PORT}"
      return 0
    fi
    sleep 1
  done
  journalctl -u sing-box -n 30 --no-pager >&2
  die "$problem"
}

main() {
  install -d -m 0755 "$ETC"
  enable_bbr
  install_package
  check_reality_target
  ensure_credentials
  ensure_cert
  apply_config
  if ! (check_end_state); then
    if [[ "$PKG_CHANGED" == yes && -n "$PREV_VERSION" ]]; then
      if ! { rollback_package && systemctl restart sing-box; }; then warn "rollback/restart failed"; fi
    fi
    die "sing-box unhealthy after install/upgrade"
  fi
}

[[ -n "${NETGURU_SOURCE_ONLY:-}" ]] || main
