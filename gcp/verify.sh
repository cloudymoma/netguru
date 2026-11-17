#!/usr/bin/env bash
# End-to-end acceptance from the workstation (spec §6.1). Exit 0 only if every check passes.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WORK=""
PROXY_PID=""
PROXY_PORT=""
FAILED=0
cleanup() {
  [[ -z "$PROXY_PID" ]] || kill "$PROXY_PID" 2>/dev/null || true
  [[ -z "$WORK" ]] || rm -rf "$WORK"
}

check() {
  local desc=$1
  shift
  if "$@"; then echo "PASS  ${desc}"; else echo "FAIL  ${desc}"; FAILED=1; fi
}

free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }

start_proxy() {
  PROXY_PORT=$(free_port)
  jq -n --argjson ob "$1" --argjson port "$PROXY_PORT" \
    '{log: {level: "warn"}, inbounds: [{type: "mixed", listen: "127.0.0.1", listen_port: $port}], outbounds: [$ob]}' \
    >"${WORK}/client.json"
  sing-box run -c "${WORK}/client.json" >"${WORK}/client.log" 2>&1 &
  PROXY_PID=$!
  for _ in $(seq 1 20); do
    kill -0 "$PROXY_PID" 2>/dev/null || break
    nc -z 127.0.0.1 "$PROXY_PORT" 2>/dev/null && return 0
    sleep 0.25
  done
  cat "${WORK}/client.log" >&2
  die "local sing-box client did not start"
}

stop_proxy() {
  kill "$PROXY_PID" 2>/dev/null || true
  wait "$PROXY_PID" 2>/dev/null || true
  PROXY_PID=""
}

via_proxy() { curl -sS --max-time 15 -x "socks5h://127.0.0.1:${PROXY_PORT}" "$@"; }
egress_is_static() { [[ "$(via_proxy --retry 2 --retry-all-errors --retry-delay 1 https://api.ipify.org 2>/dev/null)" == "${STATIC_IP}" ]]; }
blocked() { ! via_proxy -o /dev/null -H 'Metadata-Flavor: Google' "$1" 2>/dev/null; }
metadata_blocked() {
  blocked http://169.254.169.254/computeMetadata/v1/ && blocked http://metadata.google.internal/computeMetadata/v1/
}

tcp_open() { nc -z -w 5 "${STATIC_IP}" "$1" 2>/dev/null; }
tcp_closed() { ! tcp_open "$1"; }

# What an active scanner sees. REALITY hands non-clients to the real site, so a plain TLS 1.3 + X25519 + h2 client
# must get a chain that validates for the SNI (and must not validate unrelated hostnames); with Salamander, a
# Hysteria2 client without the obfs password must get nothing at all.
reality_fallback_genuine() {
  [[ "$(curl -sS -o /dev/null -w '%{http_version}' --max-time 15 --tlsv1.3 --http2 --curves X25519 \
    --resolve "${SINGBOX_REALITY_SNI}:${SINGBOX_REALITY_PORT}:${STATIC_IP}" \
    "https://${SINGBOX_REALITY_SNI}:${SINGBOX_REALITY_PORT}/" 2>/dev/null)" == 2 ]]
}

reality_rejects_unrelated_sni() {
  local canary tls
  for canary in www.adobe.com www.ikea.com aws.amazon.com www.fastly.com; do
    [[ "$canary" == "${SINGBOX_REALITY_SNI}" ]] && continue
    # Judge the TLS handshake (time_appconnect is 0.000000 unless the certificate validated), not the HTTP response.
    tls=$(curl -sS -o /dev/null --max-time 5 -w '%{time_appconnect}' \
      --resolve "${canary}:${SINGBOX_REALITY_PORT}:${STATIC_IP}" \
      "https://${canary}:${SINGBOX_REALITY_PORT}/" 2>/dev/null) || true
    if [[ -n "$tls" && "$tls" != 0.000000 ]]; then return 1; fi
  done
}

# Differential active-scanner comparison against genuine SINGBOX_REALITY_SNI:443. Differences (such as sing-box/utls
# omitting CloseWrite() TCP FIN after TLS close_notify) are reported as WARN, never FAIL.
reality_compare_genuine() {
  python3 - "${SINGBOX_REALITY_SNI}" "${STATIC_IP}" "${SINGBOX_REALITY_PORT}" \
    "${REALITY_GENUINE_ADDR:-}" "${REALITY_SSL_CA:-}" "${REALITY_FIN_WAIT:-5.0}" <<'PY'
import os, socket, ssl, sys, threading, time

sni, rhost, rport, g_override, cafile, fin_wait = (
    sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5], float(sys.argv[6])
)
if g_override:
    gh, gp = g_override.rsplit(":", 1)
    genuine = (gh, int(gp))
else:
    try:
        genuine = (socket.gethostbyname(sni), 443)
    except OSError as e:
        print(f"WARN  tcp/{rport}: {sni} does not resolve here, comparison with the genuine site skipped ({e})")
        sys.exit(0)
suspect = (rhost, rport)

def probe_garbage(addr):
    try:
        s = socket.create_connection(addr, timeout=8)
        s.sendall(os.urandom(64))
        s.settimeout(5.0)
        while True:
            try:
                d = s.recv(4096)
            except ConnectionResetError:
                return "RST"
            except socket.timeout:
                return "open"
            if not d:
                return "FIN"
    except ConnectionResetError:
        return "RST"
    except Exception as e:
        return f"err:{type(e).__name__}"
    finally:
        try: s.close()
        except Exception: pass

def probe_fin(addr):
    try:
        ctx = ssl.create_default_context(cafile=cafile or None)
        ctx.set_alpn_protocols(["http/1.1"])
        s = ctx.wrap_socket(socket.create_connection(addr, timeout=8), server_hostname=sni)
        s.sendall(f"GET /robots.txt HTTP/1.1\r\nHost: {sni}\r\nConnection: close\r\nUser-Agent: curl/8.5\r\n\r\n".encode())
        s.settimeout(1.0)
        t0 = time.time()
        while time.time() - t0 < 15.0:
            try:
                d = s.recv(65536)
            except (socket.timeout, ssl.SSLWantReadError):
                continue
            if not d:
                break
        else:
            s.close()
            return "no-TLS-EOF"
        raw = socket.socket(fileno=os.dup(s.fileno()))
        raw.settimeout(0.5)
        t1 = time.time()
        try:
            while time.time() - t1 < fin_wait:
                try:
                    p = raw.recv(4096, socket.MSG_PEEK)
                except socket.timeout:
                    continue
                except ConnectionResetError:
                    return "RST"
                if p == b"":
                    return "FIN"
                raw.recv(len(p))
            return "no-FIN"
        finally:
            raw.close()
            s.close()
    except Exception as e:
        return f"err:{type(e).__name__}"

res = {}
threads = []
for key, fn, addr in [
    ("g_garb", probe_garbage, genuine), ("r_garb", probe_garbage, suspect),
    ("g_fin", probe_fin, genuine), ("r_fin", probe_fin, suspect),
]:
    t = threading.Thread(target=lambda k=key, f=fn, a=addr: res.__setitem__(k, f(a)))
    t.start()
    threads.append(t)
for t in threads:
    t.join()

def report(what, g, r, outcomes, note=""):
    # Only real close behaviours can match: two probes that failed the same way prove nothing.
    if g not in outcomes or r not in outcomes:
        print(f"WARN  tcp/{rport}: {what} could not be compared with {sni} (genuine={g}, reality={r})")
    elif g == r:
        print(f"PASS  tcp/{rport}: {what} matches {sni} ({r})")
    else:
        print(f"WARN  tcp/{rport}: {what} differs from {sni} (genuine={g}, reality={r}{note})")

report("invalid-input close", res.get("g_garb"), res.get("r_garb"), {"FIN", "RST", "open"})
report("TCP close after TLS EOF", res.get("g_fin"), res.get("r_fin"), {"FIN", "RST", "no-FIN"}, "; upstream sing-box/utls gap")
PY
}

egress_blocked() { ! curl -sS -o /dev/null --max-time 8 -x "socks5h://127.0.0.1:${PROXY_PORT}" https://api.ipify.org 2>/dev/null; }

fw_matches() {
  local actual
  actual=$(run_gcloud compute firewall-rules describe "$1" --format=json 2>/dev/null) || return 1
  [[ -z "$(firewall_rule_diff "$actual" "$2" "$3")" ]]
}

# rule_absent NAME — true if NETWORK_NAME has no firewall rule called NAME (reads $rules, the rules list)
rule_absent() {
  jq -e --arg name "$1" --arg network "${NETWORK_NAME}" \
    'any(.[]; .name == $name and (.network | split("/") | last) == $network) | not' <<<"$rules" >/dev/null
}

main() {
  command -v sing-box >/dev/null || die "local sing-box not found on PATH (plan Task 6 Step 1)"
  validate_config
  STATIC_IP=$(get_static_ip)
  require_ipv4 STATIC_IP "${STATIC_IP}"

  WORK=$(mktemp -d)
  chmod 700 "$WORK"
  trap cleanup EXIT

  echo "== tunnels via ${STATIC_IP}"
  local outbounds ob tag hy2 p rule rule_ports foreign
  outbounds=$(SHOW_FORMAT=json "${GCP_DIR}/show.sh")
  (($(jq length <<<"$outbounds") > 0)) || die "no client outbounds returned by show.sh"
  while IFS= read -r ob; do
    tag=$(jq -r .tag <<<"$ob")
    start_proxy "$ob"
    check "${tag}: egress IP is ${STATIC_IP}" egress_is_static
    if [[ "$tag" == outline-* ]]; then
      if metadata_blocked; then
        echo "PASS  ${tag}: metadata server unreachable"
      else
        echo "WARN  ${tag}: metadata server reachable through Outline (spec §7.5; VM has no service account)"
      fi
    else
      check "${tag}: metadata server unreachable (IP and hostname)" metadata_blocked
    fi
    stop_proxy
  done < <(jq -c '.[]' <<<"$outbounds")

  if service_enabled sing-box; then
    echo "== what an active scanner sees"
    check "tcp/${SINGBOX_REALITY_PORT}: plain TLS 1.3 + X25519 + h2 gets the genuine ${SINGBOX_REALITY_SNI} certificate" reality_fallback_genuine
    check "tcp/${SINGBOX_REALITY_PORT}: unrelated hostnames do not get a valid certificate" reality_rejects_unrelated_sni
    reality_compare_genuine ||
      echo "WARN  tcp/${SINGBOX_REALITY_PORT}: comparison with the genuine ${SINGBOX_REALITY_SNI} did not run"
    hy2=$(jq -c '.[] | select(.type == "hysteria2" and .obfs.type == "salamander")' <<<"$outbounds")
    if [[ -n "$hy2" ]]; then
      start_proxy "$(jq -c 'del(.obfs)' <<<"$hy2")"
      check "udp/${SINGBOX_HY2_PORT}: Hysteria2 without the Salamander password gets nothing" egress_blocked
      stop_proxy
    fi
  fi

  echo "== exposure (from this workstation)"
  for p in $(list_service_ports | awk '{print $2}' | sed -n 's/^tcp://p'); do
    check "tcp/${p} open" tcp_open "$p"
  done
  for p in 22 "${OUTLINE_API_PORT}"; do
    check "tcp/${p} closed" tcp_closed "$p"
  done

  echo "== VM and firewall"
  local problems
  problems=$(vm_invariant_problems "$(vm_json)" "${STATIC_IP}")
  check "VM matches config${problems:+ (${problems})}" test -z "$problems"
  rule=$(fw_rule_name ssh-iap)
  check "${rule} matches spec" fw_matches "$rule" "${IAP_SOURCE_RANGE}" tcp:22
  for s in ${SERVICES}; do
    rule=$(fw_rule_name "$s")
    rule_ports=$(load_service "$s" && echo "${FW_RULES}")
    check "${rule} matches spec" fw_matches "$rule" 0.0.0.0/0 "$rule_ports"
  done
  rules=$(run_gcloud compute firewall-rules list --format=json)
  for s in $(disabled_services); do
    rule=$(fw_rule_name "$s")
    check "${rule} absent (${s} is turned off)" rule_absent "$rule"
  done
  foreign=$(foreign_fw_rules "$rules")
  check "${NETWORK_NAME} has no other firewall rules${foreign:+ (found: ${foreign})}" test -z "$foreign"

  ((FAILED == 0)) || die "verification failed (see FAIL lines above)"
  log "all checks passed"
}

[[ -n "${NETGURU_SOURCE_ONLY:-}" ]] || main
