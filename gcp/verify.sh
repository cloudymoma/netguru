#!/usr/bin/env bash
# End-to-end acceptance from the workstation (spec §6.1). Exit 0 only if every check passes.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

command -v sing-box >/dev/null || die "local sing-box not found on PATH (plan Task 6 Step 1)"
validate_config
STATIC_IP=$(get_static_ip)
require_ipv4 STATIC_IP "${STATIC_IP}"

WORK=$(mktemp -d)
chmod 700 "$WORK"
PROXY_PID=""
PROXY_PORT=""
cleanup() {
  [[ -z "$PROXY_PID" ]] || kill "$PROXY_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

FAILED=0
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
egress_is_static() { [[ "$(via_proxy https://api.ipify.org 2>/dev/null)" == "${STATIC_IP}" ]]; }
blocked() { ! via_proxy -o /dev/null -H 'Metadata-Flavor: Google' "$1" 2>/dev/null; }
metadata_blocked() {
  blocked http://169.254.169.254/computeMetadata/v1/ && blocked http://metadata.google.internal/computeMetadata/v1/
}

tcp_open() { nc -z -w 5 "${STATIC_IP}" "$1" 2>/dev/null; }
tcp_closed() { ! tcp_open "$1"; }

fw_matches() {
  local actual
  actual=$(run_gcloud compute firewall-rules describe "$1" --format=json 2>/dev/null) || return 1
  [[ -z "$(firewall_rule_diff "$actual" "$2" "$3")" ]]
}

echo "== tunnels via ${STATIC_IP}"
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

echo "== exposure (from this workstation)"
for p in $(list_service_ports | awk '{print $2}' | sed -n 's/^tcp://p'); do
  check "tcp/${p} open" tcp_open "$p"
done
for p in 22 "${OUTLINE_API_PORT}"; do
  check "tcp/${p} closed" tcp_closed "$p"
done

echo "== VM and firewall"
problems=$(vm_invariant_problems "$(vm_json)" "${STATIC_IP}")
check "VM matches config${problems:+ (${problems})}" test -z "$problems"
rule=$(fw_rule_name ssh-iap)
check "${rule} matches spec" fw_matches "$rule" "${IAP_SOURCE_RANGE}" tcp:22
for s in ${SERVICES}; do
  rule=$(fw_rule_name "$s")
  rule_ports=$(load_service "$s" && echo "${FW_RULES}")
  check "${rule} matches spec" fw_matches "$rule" 0.0.0.0/0 "$rule_ports"
done
foreign=$(foreign_fw_rules "$(run_gcloud compute firewall-rules list --format=json)")
check "${NETWORK_NAME} has no other firewall rules${foreign:+ (found: ${foreign})}" test -z "$foreign"

((FAILED == 0)) || die "verification failed (see FAIL lines above)"
log "all checks passed"
