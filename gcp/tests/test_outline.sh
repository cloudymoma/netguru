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

# If a new shadowbox image fails wait_healthy during upgrade, upgrade_image re-tags the previous image ID and restarts.
# shellcheck disable=SC2034,SC2329 # globals and stubs are used by the sourced upgrade_image
outline_upgrade_rollback() {
  local fail_rollback=${1:-no}
  STATE_DIR="${OUTLINE_TMP}/state"
  OUTLINE_IMAGE_DIGEST="sha256:545c6f7c7261bb30ae1dffe24a6fca5f8512f5d17c72cfb9e410e7e655444e62"
  mkdir -p "$STATE_DIR"
  : >"${OUTLINE_TMP}/docker-log"
  printf 'docker run "%s:%s"\n' "${OUTLINE_IMAGE_REPO}" "${OUTLINE_IMAGE_TAG}" >"${STATE_DIR}/start_container.sh"
  running_repo_digests() { echo "quay.io/outline/shadowbox@sha256:$(printf '0%.0s' {1..64})"; }
  key_count() { echo 2; }
  load_api() { :; }
  wait_healthy() { exit 1; }
  docker() {
    if [[ "$1" == inspect ]]; then echo "sha256:prev-image-id"; return 0; fi
    if [[ "$fail_rollback" == yes && "$1" == tag && "$2" == "sha256:prev-image-id" ]]; then return 1; fi
    echo "$*" >>"${OUTLINE_TMP}/docker-log"
  }
  bash() { echo "start $*" >>"${OUTLINE_TMP}/docker-log"; }
  upgrade_image
}
expect_fail "unhealthy shadowbox upgrade fails" vm_fn "$OUTLINE_INSTALL" outline_upgrade_rollback
expect_eq   "unhealthy shadowbox upgrade re-tags the previous image and restarts" \
  "$(tail -n 2 "${OUTLINE_TMP}/docker-log")" \
  $'tag sha256:prev-image-id quay.io/outline/shadowbox:stable\nstart '"${OUTLINE_TMP}/state/start_container.sh"
expect_eq   "failed shadowbox rollback warns loudly" \
  "$(vm_fn "$OUTLINE_INSTALL" outline_upgrade_rollback yes 2>&1 | grep 'WARN:')" \
  "[outline] WARN: rollback failed; shadowbox may be down"

# apt-get update does not honor DPkg::Lock::Timeout on /var/lib/apt/lists/lock: apt_update retries until the lock clears.
# shellcheck disable=SC2329
outline_apt_update() {
  local succeed_on=$1 tries="${OUTLINE_TMP}/apt-tries"
  : >"$tries"
  sleep() { :; }
  apt-get() {
    echo try >>"$tries"
    ((succeed_on > 0 && $(wc -l <"$tries") >= succeed_on))
  }
  apt_update
}
expect_ok   "apt_update succeeds once the lists lock clears" vm_fn "$OUTLINE_INSTALL" outline_apt_update 3
expect_eq   "apt_update stops retrying after success"        "$(wc -l <"${OUTLINE_TMP}/apt-tries")" "3"
expect_fail "apt_update dies after 12 failed attempts"       vm_fn "$OUTLINE_INSTALL" outline_apt_update 0
expect_eq   "apt_update tries 12 times before dying"         "$(wc -l <"${OUTLINE_TMP}/apt-tries")" "12"

# OUTLINE_ENABLED=false: make infra stops shadowbox for good (restart=no survives reboots) but keeps its keys.
OUTLINE_DISABLE=gcp/services/outline/remote-disable.sh
# outline_disable STATE — remote-disable main against a stubbed Docker; prints the mutating docker calls.
# STATE: nodocker | nodaemon | absent | running | stopped
# shellcheck disable=SC2329 # stubs invoked by the sourced main
outline_disable() {
  local state=$1 log="${OUTLINE_TMP}/disable-log"
  : >"$log"
  have_docker() { [[ "$state" != nodocker ]]; }
  docker() {
    case "$1" in
      info) [[ "$state" != nodaemon ]] ;;
      inspect)
        if [[ "$2" != -f ]]; then [[ "$2" == shadowbox && "$state" != absent ]]
        elif [[ "$state" == running ]]; then echo true
        else echo false
        fi ;;
      *) echo "$*" >>"$log" ;;
    esac
  }
  main
  cat "$log"
}
expect_eq   "turning Outline off stops a running shadowbox for good" \
  "$(vm_fn "$OUTLINE_DISABLE" outline_disable running 2>/dev/null)" $'update --restart=no shadowbox\nstop shadowbox'
expect_eq   "an already stopped shadowbox only loses restart=always" \
  "$(vm_fn "$OUTLINE_DISABLE" outline_disable stopped 2>/dev/null)" "update --restart=no shadowbox"
expect_eq   "no shadowbox container: nothing to do" "$(vm_fn "$OUTLINE_DISABLE" outline_disable absent 2>/dev/null)" ""
expect_ok   "no Docker at all: nothing to do"       vm_fn "$OUTLINE_DISABLE" outline_disable nodocker
expect_fail "Docker installed but not running: refuses to guess" vm_fn "$OUTLINE_DISABLE" outline_disable nodaemon

# Turning Outline back on adopts the stopped container: restart=always is restored before it starts.
# shellcheck disable=SC2034,SC2329 # globals and stubs are used by the sourced adopt
outline_adopt_stopped() {
  local log="${OUTLINE_TMP}/adopt-log"
  : >"$log"
  STATIC_IP=203.0.113.100
  docker() {
    echo "$*" >>"$log"
    if [[ "$1 $2" == "inspect -f" ]]; then echo false; fi
    return 0
  }
  load_api() { :; }
  wait_healthy() { :; }
  api() { echo '{"hostnameForAccessKeys":"203.0.113.100"}'; }
  adopt
  grep -E '^(update|start) ' "$log"
}
expect_eq   "adopting a turned-off Outline restores restart=always, then starts it" \
  "$(vm_fn "$OUTLINE_INSTALL" outline_adopt_stopped 2>/dev/null)" $'update --restart=always shadowbox\nstart shadowbox'
rm -rf "$OUTLINE_TMP"
