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
expect_eq "narrow BitTorrent sniff runs before resolve and private-IP reject rules" \
  "$(jq -r '[.route.rules[].action] | join(",")' "${SB_TMP}/server.json")" "sniff,reject,resolve,reject,reject"
expect_eq "server sniff is scoped to bittorrent with a 50ms timeout" \
  "$(jq -c '[.route.rules[0], .route.rules[1]]' "${SB_TMP}/server.json")" \
  '[{"action":"sniff","sniffer":["bittorrent"],"timeout":"50ms"},{"protocol":"bittorrent","action":"reject"}]'
expect_eq "private and link-local (metadata) destinations are rejected" \
  "$(jq -c '[.route.rules[3].ip_is_private, .route.rules[4].ip_cidr]' "${SB_TMP}/server.json")" \
  '[true,["169.254.0.0/16"]]'
expect_eq "inbounds are REALITY on tcp 443 and Hysteria2 on 8443" \
  "$(jq -r '[.inbounds[] | "\(.type):\(.listen_port)"] | join(",")' "${SB_TMP}/server.json")" \
  "vless:443,hysteria2:8443"
expect_eq "REALITY limits client clock skew to SINGBOX_REALITY_MAX_TIME_DIFF by default" \
  "$(jq -r '.inbounds[0].tls.reality.max_time_difference' "${SB_TMP}/server.json")" "1m"
SINGBOX_REALITY_MAX_TIME_DIFF="" sb_fn "$SB_INSTALL" render_singbox_config >"${SB_TMP}/server-notd.json"
expect_ok "empty SINGBOX_REALITY_MAX_TIME_DIFF passes 'sing-box check'" sing-box check -c "${SB_TMP}/server-notd.json"
expect_eq "empty SINGBOX_REALITY_MAX_TIME_DIFF omits max_time_difference" \
  "$(jq -c '.inbounds[0].tls.reality | has("max_time_difference")' "${SB_TMP}/server-notd.json")" "false"
# shellcheck disable=SC2016
expect_ok   "SINGBOX_REALITY_MAX_TIME_DIFF accepts empty or s/m/h durations" \
  bash -c '. gcp/lib.sh; load_service sing-box; for d in "" 30s 1m 2m 1h; do SINGBOX_REALITY_MAX_TIME_DIFF=$d service_validate || exit 1; done'
expect_fail "SINGBOX_REALITY_MAX_TIME_DIFF rejects unitless numbers" \
  bash -c '. gcp/lib.sh; SINGBOX_REALITY_MAX_TIME_DIFF=60; load_service sing-box; service_validate'
expect_fail "SINGBOX_REALITY_MAX_TIME_DIFF rejects zero duration" \
  bash -c '. gcp/lib.sh; SINGBOX_REALITY_MAX_TIME_DIFF=0m; load_service sing-box; service_validate'

# check_time_sync ensures VM NTP sync before enabling max_time_difference, and names the escape hatch on failure.
# shellcheck disable=SC2034,SC2329 # globals and stubs invoked by sourced check_time_sync
sb_time_sync() {
  local max_td=$1 sync_on=$2 tries="${SB_TMP}/ntp-tries"
  : >"$tries"
  SINGBOX_REALITY_MAX_TIME_DIFF=$max_td
  sleep() { :; }
  timedatectl() {
    echo try >>"$tries"
    if ((sync_on > 0 && $(wc -l <"$tries") >= sync_on)); then echo yes; else echo no; fi
  }
  check_time_sync
}
expect_ok   "check_time_sync succeeds once NTPSynchronized becomes yes" vm_fn "$SB_INSTALL" sb_time_sync 1m 3
expect_fail "check_time_sync fails when NTP never synchronizes"         vm_fn "$SB_INSTALL" sb_time_sync 1m 0
# shellcheck disable=SC2016 # $1 is expanded by the inner bash
expect_ok   "check_time_sync error names SINGBOX_REALITY_MAX_TIME_DIFF=\"\" escape hatch" \
  bash -c 'grep -qF '\''SINGBOX_REALITY_MAX_TIME_DIFF=""'\'' <<<"$1"' _ "$(vm_fn "$SB_INSTALL" sb_time_sync 1m 0 2>&1)"
expect_ok   "check_time_sync is skipped when SINGBOX_REALITY_MAX_TIME_DIFF is empty" vm_fn "$SB_INSTALL" sb_time_sync "" 0
expect_eq   "...without calling timedatectl" "$(wc -l <"${SB_TMP}/ntp-tries")" "0"

# check_reality_target requires TLS 1.3 + HTTP/2 + X25519, rejects targets whose IP serves valid certs for unrelated
# hostnames (shared CDNs), and warns on CDN CNAMEs or headers without failing dedicated origins.
# shellcheck disable=SC2034,SC2329 # globals and stubs used by sourced check_reality_target
sb_reality_target() {
  local mode=$1
  SINGBOX_REALITY_SNI=origin.example.jp
  getent() {
    if [[ "$mode" == cdn-cname ]]; then
      printf '198.51.100.7    STREAM a488.r.akamai.net\n'
    else
      printf '198.51.100.7    STREAM edge12.g.yimg.jp\n'
    fi
  }
  curl() {
    local args=" $* " hdr="" i
    for ((i = 1; i <= $#; i++)); do
      if [[ "${!i}" == "-D" ]]; then local next=$((i + 1)); hdr=${!next}; fi
    done
    if [[ "$args" == *" --resolve "* ]]; then # canary probe: prints %{time_appconnect}
      if [[ "$mode" == shared-cdn* && "$args" == *" https://www.adobe.com/ "* ]]; then
        printf '0.104706'
        [[ "$mode" == shared-cdn-stall ]] && return 28 # certificate validated, then the HTTP response never arrives
        return 0
      fi
      printf '0.000000'
      return 60
    fi
    [[ "$args" == *" --curves X25519 "* ]] || return 99
    case "$mode" in
      no-x25519) return 35 ;;
      http1)     [[ -z "$hdr" ]] || printf 'HTTP/1.1 200 OK\r\n\r\n' >"$hdr"; printf '1.1 198.51.100.7' ;;
      cdn-hdr)   [[ -z "$hdr" ]] || printf 'HTTP/2 200\r\nserver: AkamaiGHost\r\n\r\n' >"$hdr"; printf '2 198.51.100.7' ;;
      *)         [[ -z "$hdr" ]] || printf 'HTTP/2 200\r\nserver: yserver\r\n\r\n' >"$hdr"; printf '2 198.51.100.7' ;;
    esac
  }
  check_reality_target
}
expect_ok   "check_reality_target accepts TLS 1.3 + h2 + X25519 dedicated origin" vm_fn "$SB_INSTALL" sb_reality_target ok
expect_fail "check_reality_target rejects target without X25519"                  vm_fn "$SB_INSTALL" sb_reality_target no-x25519
expect_fail "check_reality_target rejects HTTP/1.1 target"                        vm_fn "$SB_INSTALL" sb_reality_target http1
expect_fail "check_reality_target rejects target serving valid cert for unrelated SNI" vm_fn "$SB_INSTALL" sb_reality_target shared-cdn
expect_fail "...even when the canary's HTTP response stalls after the handshake" vm_fn "$SB_INSTALL" sb_reality_target shared-cdn-stall
# shellcheck disable=SC2016
expect_ok   "...naming the unrelated hostname" \
  bash -c 'grep -q "www.adobe.com" <<<"$1"' _ "$(vm_fn "$SB_INSTALL" sb_reality_target shared-cdn 2>&1)"
# shellcheck disable=SC2016
expect_ok   "check_reality_target warns on CDN headers when certs do not leak" \
  bash -c 'grep -q "WARN:.*CDN" <<<"$1"' _ "$(vm_fn "$SB_INSTALL" sb_reality_target cdn-hdr 2>&1)"
# shellcheck disable=SC2016
expect_ok   "check_reality_target warns on CDN CNAME even when headers are quiet" \
  bash -c 'grep -q "WARN:.*CDN" <<<"$1" && grep -q "a488.r.akamai.net" <<<"$1"' _ "$(vm_fn "$SB_INSTALL" sb_reality_target cdn-cname 2>&1)"
expect_eq   "check_reality_target emits no CDN warning for a dedicated origin (e.g. yimg.jp)" \
  "$(vm_fn "$SB_INSTALL" sb_reality_target ok 2>&1)" ""

# verify.sh differential scanner comparison: reports PASS when close behavior matches and WARN (not FAIL) when it differs.
SB_VERIFY=gcp/verify.sh
sb_diff_test() {
  python3 - "$SB_VERIFY" "$1" <<'PY'
import socket, ssl, subprocess, sys, tempfile, threading, time

verify_sh, mode = sys.argv[1], sys.argv[2]
with tempfile.TemporaryDirectory() as d:
    subprocess.check_call([
        "openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
        "-nodes", "-days", "1", "-subj", "/CN=origin.example.jp",
        "-addext", "subjectAltName=DNS:origin.example.jp",
        "-keyout", f"{d}/k.pem", "-out", f"{d}/c.pem",
    ], stderr=subprocess.DEVNULL)

    def serve(hold_open, rst_garbage):
        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(8)
        port = srv.getsockname()[1]
        def loop():
            while True:
                try:
                    c, _ = srv.accept()
                except OSError:
                    break
                def handle(conn):
                    try:
                        conn.settimeout(2)
                        first = conn.recv(1, socket.MSG_PEEK)
                        if not first or first[0] != 0x16:
                            if rst_garbage:
                                conn.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, b"\x01\x00\x00\x00\x00\x00\x00\x00")
                            else:
                                conn.recv(4096)
                            conn.close()
                            return
                        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                        ctx.load_cert_chain(f"{d}/c.pem", f"{d}/k.pem")
                        ctx.set_alpn_protocols(["http/1.1", "h2"])
                        ib, ob = ssl.MemoryBIO(), ssl.MemoryBIO()
                        sobj = ctx.wrap_bio(ib, ob, server_side=True)
                        while True:
                            try:
                                sobj.do_handshake()
                                break
                            except ssl.SSLWantReadError:
                                conn.sendall(ob.read())
                                ib.write(conn.recv(4096))
                        conn.sendall(ob.read())
                        while True:
                            try:
                                sobj.read(4096)
                                break
                            except ssl.SSLWantReadError:
                                ib.write(conn.recv(4096))
                        sobj.write(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
                        try:
                            sobj.unwrap()
                        except ssl.SSLWantReadError:
                            pass
                        conn.sendall(ob.read())
                        if hold_open:
                            time.sleep(2.0)
                        conn.close()
                    except Exception:
                        try: conn.close()
                        except Exception: pass
                threading.Thread(target=handle, args=(c,), daemon=True).start()
        threading.Thread(target=loop, daemon=True).start()
        return srv, port

    ca = f"{d}/c.pem"
    if mode == "bad-ca":  # neither probe can verify TLS: the two identical failures must not count as a match
        subprocess.check_call([
            "openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
            "-nodes", "-days", "1", "-subj", "/CN=unrelated.example", "-keyout", f"{d}/k2.pem", "-out", f"{d}/other.pem",
        ], stderr=subprocess.DEVNULL)
        ca = f"{d}/other.pem"
    s1, p1 = serve(hold_open=False, rst_garbage=(mode == "rst-diff"))
    s2, p2 = serve(hold_open=(mode == "no-fin"), rst_garbage=False)
    cmd = f"NETGURU_SOURCE_ONLY=1 . ./{verify_sh}; SINGBOX_REALITY_SNI=origin.example.jp SINGBOX_REALITY_PORT={p2} STATIC_IP=127.0.0.1 REALITY_GENUINE_ADDR=127.0.0.1:{p1} REALITY_SSL_CA={ca} REALITY_FIN_WAIT=1.0 reality_compare_genuine; echo EXIT=$FAILED"
    out = subprocess.check_output(["bash", "-c", cmd], text=True)
    s1.close(); s2.close()
    print(out.strip())
PY
}
# shellcheck disable=SC2016
expect_ok "verify differential check passes when fallback matches genuine close behavior" \
  bash -c '[[ "$1" == *"PASS"* && "$1" != *"WARN"* && "$1" == *"EXIT=0" ]]' _ "$(sb_diff_test match 2>&1)"
# shellcheck disable=SC2016
expect_ok "verify differential check warns (without failing) when fallback omits TCP FIN" \
  bash -c '[[ "$1" == *"WARN"* && "$1" == *"no-FIN"* && "$1" == *"EXIT=0" ]]' _ "$(sb_diff_test no-fin 2>&1)"
# shellcheck disable=SC2016
expect_ok "verify differential check warns (without failing) when invalid-input close differs" \
  bash -c '[[ "$1" == *"WARN"* && "$1" == *"RST"* && "$1" == *"EXIT=0" ]]' _ "$(sb_diff_test rst-diff 2>&1)"
# shellcheck disable=SC2016
expect_ok "verify differential check reports no match when both probes fail the same way" \
  bash -c '[[ "$1" == *"TCP close after TLS EOF could not be compared"* && "$1" != *"TLS EOF matches"* && "$1" == *"EXIT=0" ]]' _ "$(sb_diff_test bad-ca 2>&1)"

# Salamander (on by default): probes without the obfs password get no reply, so the self-signed cert never leaks.
expect_eq "Hysteria2 obfuscates with Salamander by default" \
  "$(jq -c '.inbounds[1].obfs' "${SB_TMP}/server.json")" \
  '{"type":"salamander","password":"ffeeddccbbaa99887766554433221100"}'
expect_eq "Hysteria2 configures proxy masquerade with rewrite_host" \
  "$(jq -c '.inbounds[1].masquerade' "${SB_TMP}/server.json")" \
  "{\"type\":\"proxy\",\"url\":\"https://${SINGBOX_HY2_SNI}\",\"rewrite_host\":true}"
SINGBOX_HY2_SALAMANDER=false sb_fn "$SB_INSTALL" render_singbox_config >"${SB_TMP}/server-plain.json"
expect_ok "Salamander off: config still passes 'sing-box check'" sing-box check -c "${SB_TMP}/server-plain.json"
expect_eq "Salamander off: no obfs, masquerade remains" \
  "$(jq -c '.inbounds[1] | [has("obfs"), .masquerade.rewrite_host]' "${SB_TMP}/server-plain.json")" "[false,true]"

# tune_network sets 8 MiB UDP _default and _max buffers (needed when Salamander wraps the socket) plus optional BBR.
# shellcheck disable=SC2034,SC2329 # globals and sysctl stub read by sourced tune_network
sb_tune_net() {
  local bbr=$1
  SINGBOX_ENABLE_BBR=$bbr
  SYSCTL_CONF="${SB_TMP}/99-sing-box-${bbr}.conf"
  LEGACY_BBR_CONF="${SB_TMP}/99-bbr-${bbr}.conf"
  printf 'old\n' >"$LEGACY_BBR_CONF"
  sysctl() {
    case "$*" in
      "--system") return 0 ;;
      "-n net.ipv4.tcp_congestion_control") echo bbr ;;
      "-n net.core.rmem_default" | "-n net.core.wmem_default") echo 8388608 ;;
    esac
  }
  tune_network
}
expect_ok "tune_network configures UDP buffers and BBR when SINGBOX_ENABLE_BBR=true" vm_fn "$SB_INSTALL" sb_tune_net true
expect_eq "tune_network writes rmem/wmem max+default and BBR, removing legacy 99-bbr.conf" \
  "$(test -e "${SB_TMP}/99-bbr-true.conf" && echo kept || echo gone),$(grep -c '=' "${SB_TMP}/99-sing-box-true.conf"),$(grep -c 'rmem_default=8388608' "${SB_TMP}/99-sing-box-true.conf")" \
  "gone,6,1"
expect_ok "tune_network omits BBR when SINGBOX_ENABLE_BBR=false while keeping UDP buffers" vm_fn "$SB_INSTALL" sb_tune_net false
expect_eq "tune_network writes only the 4 UDP buffer keys when BBR is off" \
  "$(grep -c '=' "${SB_TMP}/99-sing-box-false.conf"),$(grep -c 'bbr' "${SB_TMP}/99-sing-box-false.conf")" "4,0"

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
  "vless://11111111-2222-3333-4444-555555555555@1.2.3.4:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SINGBOX_REALITY_SNI}&fp=chrome&pbk=PUBKEY&sid=0123456789abcdef&type=tcp&headerType=none#netguru-reality"
expect_eq "Hysteria2 share URI carries the Salamander password and the cert pin" \
  "$(sb_fn "$SB_SHOW" hy2_uri)" \
  "hysteria2://00112233445566778899aabbccddeeff@1.2.3.4:8443?obfs=salamander&obfs-password=ffeeddccbbaa99887766554433221100&sni=${SINGBOX_HY2_SNI}&alpn=h3&insecure=1&pinSHA256=ABCDEF#netguru-hy2"
expect_eq "Salamander off: the share URI has no obfs" \
  "$(SINGBOX_HY2_SALAMANDER=false sb_fn "$SB_SHOW" hy2_uri)" \
  "hysteria2://00112233445566778899aabbccddeeff@1.2.3.4:8443?sni=${SINGBOX_HY2_SNI}&alpn=h3&insecure=1&pinSHA256=ABCDEF#netguru-hy2"

sb_fn "$SB_SHOW" client_outbounds >"${SB_TMP}/outbounds.json"
jq '{outbounds: .}' "${SB_TMP}/outbounds.json" >"${SB_TMP}/client.json"
expect_ok "client outbounds pass 'sing-box check'" sing-box check -c "${SB_TMP}/client.json"
expect_eq "Hysteria2 client trusts only the pinned cert, never insecure" \
  "$(jq -c '.[1].tls | [has("insecure"), (.certificate | length > 0), .server_name]' "${SB_TMP}/outbounds.json")" \
  "[false,true,\"${SINGBOX_HY2_SNI}\"]"
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
expect_eq "client profile sends private and CN destinations direct, everything else through the proxy" \
  "$(jq -c '.route | [(.rules[] | select(.ip_is_private) | .outbound), (.rules[] | select(.rule_set) | [.rule_set, .outbound]), .final, .default_domain_resolver, .default_http_client]' "${SB_TMP}/profile.json")" \
  '["direct",[["geosite-cn","geoip-cn"],"direct"],"proxy","remote","via-proxy"]'
expect_eq "bypass-CN profile splits DNS (geosite-cn -> AliDNS DoH, rest -> remote DoH via proxy)" \
  "$(jq -c '.dns | [([.servers[] | [.tag, .server, (.detour // "direct")]]), .rules, .final]' "${SB_TMP}/profile.json")" \
  '[[["remote","1.1.1.1","proxy"],["cn-dns","223.5.5.5","direct"]],[{"rule_set":["geosite-cn"],"server":"cn-dns"}],"remote"]'
expect_eq "bypass-CN profile uses http_clients + cache_file and never deprecated download_detour or independent_cache" \
  "$(jq -c '[.http_clients, .experimental.cache_file.enabled, (any(.route.rule_set[]; has("download_detour"))), (.dns | has("independent_cache"))]' "${SB_TMP}/profile.json")" \
  '[[{"tag":"via-proxy","detour":"proxy"}],true,false,false]'
CLIENT_BYPASS_CN=false client_profile <"${SB_TMP}/outbounds.json" >"${SB_TMP}/profile-full.json"
expect_ok "full-tunnel client profile passes 'sing-box check'" sing-box check -c "${SB_TMP}/profile-full.json"
expect_eq "full-tunnel client profile has no remote rule-sets, no local/CN DNS, remote resolver, and cache_file enabled" \
  "$(jq -c '[([.dns.servers[].tag]), (.route | has("rule_set")), .route.default_domain_resolver, .experimental.cache_file.enabled]' "${SB_TMP}/profile-full.json")" \
  '[["remote"],false,"remote",true]'
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
