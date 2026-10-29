#!/usr/bin/env bash
# VM-side (root): install Outline on a clean VM, or re-run on an existing install (spec §4.5).
# Env: STATIC_IP UPGRADE(yes|no) OUTLINE_API_PORT OUTLINE_KEYS_PORT OUTLINE_INSTALLER_URL OUTLINE_INSTALLER_SHA256
#      OUTLINE_IMAGE_REPO OUTLINE_IMAGE_TAG OUTLINE_IMAGE_DIGEST (resolved on the workstation, spec §4.10)
set -euo pipefail

STATE_DIR=/opt/outline/persisted-state
SERVER_CONFIG="${STATE_DIR}/shadowbox_server_config.json"
API_CERT="${STATE_DIR}/shadowbox-selfsigned.crt"
APT_OPTS=(-y -q -o DPkg::Lock::Timeout=120 -o Acquire::Retries=3) # wait out unattended-upgrades and transient mirror errors

die() { echo "[outline] ERROR: $*" >&2; exit 1; }
log() { echo "[outline] $*" >&2; }
warn() { echo "[outline] WARN: $*" >&2; }

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

# outline_state HAS_CONTAINER HAS_STATE -> fresh|adopt|partial
outline_state() {
  case "$1:$2" in
    no:no) echo fresh ;;
    yes:yes) echo adopt ;;
    *) echo partial ;;
  esac
}

# outline_upgrade_action RUNNING_REPO_DIGESTS(newline list) TARGET_REF -> keep|recreate
outline_upgrade_action() {
  if [[ -n "$1" ]] && grep -qxF "$2" <<<"$1"; then echo keep; else echo recreate; fi
}

running_repo_digests() {
  docker image inspect "$(docker inspect -f '{{.Image}}' shadowbox)" \
    --format '{{range .RepoDigests}}{{println .}}{{end}}' | sed '/^$/d'
}

remove_watchtower() {
  if docker inspect watchtower >/dev/null 2>&1; then
    log "removing watchtower (no unattended updates, spec §4.10)"
    docker rm -f watchtower >/dev/null
  fi
}

require_digest() {
  [[ "${OUTLINE_IMAGE_DIGEST:-}" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    die "OUTLINE_IMAGE_DIGEST not resolved (got '${OUTLINE_IMAGE_DIGEST:-}'); run via make"
}

# Pull exactly the digest resolved on the workstation (Docker rejects mismatching content), then tag it as the
# reference the installer / start_container.sh run, so they use this verified local image (neither pulls).
pull_verified_image() {
  require_digest
  log "pulling ${OUTLINE_IMAGE_REPO}@${OUTLINE_IMAGE_DIGEST}"
  docker pull -q "${OUTLINE_IMAGE_REPO}@${OUTLINE_IMAGE_DIGEST}" >/dev/null
  docker tag "${OUTLINE_IMAGE_REPO}@${OUTLINE_IMAGE_DIGEST}" "${OUTLINE_IMAGE_REPO}:${OUTLINE_IMAGE_TAG}"
}

container_env() {
  docker inspect shadowbox --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n "s/^$1=//p"
}

load_api() {
  API_PREFIX=$(container_env SB_API_PREFIX)
  API_PORT=$(container_env SB_API_PORT)
  [[ -n "$API_PREFIX" && -n "$API_PORT" ]] || die "cannot read SB_API_PREFIX/SB_API_PORT from the shadowbox container"
  [[ "$API_PORT" == "${OUTLINE_API_PORT}" ]] || die "shadowbox API port ${API_PORT} != OUTLINE_API_PORT ${OUTLINE_API_PORT}"
  API_PIN=$(openssl x509 -in "$API_CERT" -pubkey -noout | openssl pkey -pubin -outform der |
    openssl dgst -sha256 -binary | base64)
}

# api METHOD PATH [curl args...] — localhost management API, pinned to the server's public key
api() {
  local method=$1 path=$2
  shift 2
  curl -fsS --max-time 10 -k --pinnedpubkey "sha256//${API_PIN}" -X "$method" \
    "https://localhost:${API_PORT}/${API_PREFIX}${path}" "$@"
}

wait_healthy() {
  for _ in $(seq 1 30); do
    api GET /server >/dev/null 2>&1 && return 0
    sleep 2
  done
  die "Outline API not healthy after 60s (docker logs shadowbox for details)"
}

ensure_packages() {
  local missing=() p
  for p in ca-certificates curl jq openssl; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  ((${#missing[@]} == 0)) && return
  export DEBIAN_FRONTEND=noninteractive
  apt_update
  apt-get "${APT_OPTS[@]}" install "${missing[@]}"
}

ensure_swap() {
  if ! swapon --show=NAME --noheadings | grep -qx /swapfile; then
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
  fi
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
}

# strip_installer_watchtower FILE — remove the single Watchtower launch line from the verified installer.
strip_installer_watchtower() {
  local line='  run_step "Starting Watchtower" start_watchtower' count tmp
  count=$(grep -cxF "$line" "$1" || true)
  [[ "$count" == 1 ]] || die "expected 1 '${line}' line in $1, got ${count}"
  tmp=$(mktemp)
  grep -vxF "$line" "$1" >"$tmp"
  mv "$tmp" "$1"
}

# run_installer FILE ARGS... — run the verified installer; drop its Outline Manager credential line
# ({"apiUrl": …}, which embeds the management API's secret prefix) so it never leaves the VM (spec §1.3).
# pipefail keeps the installer's exit status; sed -u passes progress through line by line.
run_installer() {
  local installer=$1
  shift
  bash "$installer" "$@" </dev/null | sed -u '/"apiUrl"/d'
}

fresh_install() {
  log "no Outline found: installing (pinned installer)"
  ensure_swap
  export DEBIAN_FRONTEND=noninteractive
  apt_update
  apt-get "${APT_OPTS[@]}" install docker.io
  systemctl enable --now docker
  pull_verified_image
  local installer target="${OUTLINE_IMAGE_REPO}@${OUTLINE_IMAGE_DIGEST}"
  installer=$(mktemp)
  curl -fsSL --retry 3 --max-time 30 "${OUTLINE_INSTALLER_URL}" -o "$installer"
  echo "${OUTLINE_INSTALLER_SHA256}  ${installer}" | sha256sum -c --quiet - ||
    die "installer checksum mismatch for ${OUTLINE_INSTALLER_URL}"
  strip_installer_watchtower "$installer"
  run_installer "$installer" --hostname="${STATIC_IP}" --api-port="${OUTLINE_API_PORT}" \
    --keys-port="${OUTLINE_KEYS_PORT}"
  rm -f "$installer"
  remove_watchtower
  grep -qxF "$target" <<<"$(running_repo_digests)" || die "shadowbox is not running ${target} after fresh install"
}

adopt() {
  log "existing Outline found: adopting (keys untouched)"
  remove_watchtower
  # Turning Outline off sets restart=no (remote-disable.sh): restore the installer's policy before starting it.
  docker update --restart=always shadowbox >/dev/null
  if [[ "$(docker inspect -f '{{.State.Running}}' shadowbox)" != true ]]; then
    log "starting shadowbox"
    docker start shadowbox >/dev/null
  fi
  load_api
  wait_healthy
  local host
  host=$(api GET /server | jq -r .hostnameForAccessKeys)
  if [[ "$host" != "${STATIC_IP}" ]]; then
    log "access-key hostname ${host} -> ${STATIC_IP}"
    api PUT /server/hostname-for-access-keys -H 'Content-Type: application/json' \
      -d "{\"hostname\":\"${STATIC_IP}\"}" >/dev/null
  fi
  if [[ "${UPGRADE:-no}" == yes ]]; then upgrade_image; fi
}

check_end_state() {
  load_api
  wait_healthy
  local server
  server=$(api GET /server)
  [[ "$(jq -r .portForNewAccessKeys <<<"$server")" == "${OUTLINE_KEYS_PORT}" ]] ||
    die "portForNewAccessKeys is $(jq -r .portForNewAccessKeys <<<"$server"), want ${OUTLINE_KEYS_PORT}"
  [[ "$(jq -r .hostnameForAccessKeys <<<"$server")" == "${STATIC_IP}" ]] ||
    die "hostnameForAccessKeys is $(jq -r .hostnameForAccessKeys <<<"$server"), want ${STATIC_IP}"
  if docker inspect watchtower >/dev/null 2>&1; then die "watchtower is running; unattended updates are not allowed (spec §4.10)"; fi
  [[ "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' shadowbox)" == always ]] ||
    die "shadowbox restart policy is not 'always': it would stay down after a reboot"
  log "healthy: $(key_count) access key(s); image $(running_repo_digests | head -n1)"
}

key_count() { api GET /access-keys | jq '.accessKeys | length'; }

upgrade_image() {
  require_digest
  local target="${OUTLINE_IMAGE_REPO}@${OUTLINE_IMAGE_DIGEST}" start="${STATE_DIR}/start_container.sh" prev before after
  if [[ "$(outline_upgrade_action "$(running_repo_digests)" "$target")" == keep ]]; then
    log "shadowbox already runs ${target}; nothing to upgrade"
    return
  fi
  grep -qF "\"${OUTLINE_IMAGE_REPO}:${OUTLINE_IMAGE_TAG}\"" "$start" ||
    die "${start} does not run ${OUTLINE_IMAGE_REPO}:${OUTLINE_IMAGE_TAG}; refusing to recreate"
  if grep -q 'docker pull' "$start"; then die "${start} pulls images itself; refusing (would bypass digest verification)"; fi
  prev=$(docker inspect -f '{{.Image}}' shadowbox)
  before=$(key_count)
  log "upgrading shadowbox: $(running_repo_digests | head -n1) -> ${target}"
  pull_verified_image
  if ! (bash "$start" >/dev/null && load_api && wait_healthy); then
    log "rolling back shadowbox to ${prev}"
    if ! { docker tag "$prev" "${OUTLINE_IMAGE_REPO}:${OUTLINE_IMAGE_TAG}" && bash "$start" >/dev/null; }; then
      warn "rollback failed; shadowbox may be down"
    fi
    die "shadowbox unhealthy after upgrade"
  fi
  load_api
  after=$(key_count)
  [[ "$after" == "$before" ]] || die "access-key count changed during upgrade: ${before} -> ${after}"
  grep -qxF "$target" <<<"$(running_repo_digests)" || die "shadowbox is not running ${target} after the upgrade"
}

main() {
  ensure_packages
  local has_container=no has_state=no
  if command -v docker >/dev/null && docker inspect shadowbox >/dev/null 2>&1; then has_container=yes; fi
  [[ -f "$SERVER_CONFIG" ]] && has_state=yes
  case "$(outline_state "$has_container" "$has_state")" in
    fresh) fresh_install ;;
    adopt) adopt ;;
    partial) die "partial Outline state (container=${has_container}, state=${has_state}); refusing to run the installer over it — inspect /opt/outline and 'docker ps -a' manually" ;;
  esac
  check_end_state
}

[[ -n "${NETGURU_SOURCE_ONLY:-}" ]] || main
