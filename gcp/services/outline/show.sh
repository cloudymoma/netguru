#!/usr/bin/env bash
# VM-side (root): print Outline access keys (spec §4.5).
# Env: STATIC_IP SHOW_FORMAT(text|json) OUTLINE_API_PORT (others from service.env are ignored)
set -euo pipefail

API_CERT=/opt/outline/persisted-state/shadowbox-selfsigned.crt

keys_to_text() {
  jq -r '.accessKeys[] | "  [\(if (.name // "") == "" then "key-\(.id)" else .name end)] \(.accessUrl)"'
}

keys_to_outbounds() {
  jq --arg ip "$1" '[.accessKeys[] | {type: "shadowsocks", tag: "outline-\(.id)", server: $ip,
    server_port: .port, method: .method, password: .password}]'
}

container_env() {
  docker inspect shadowbox --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n "s/^$1=//p"
}

main() {
  if ! command -v docker >/dev/null || ! docker inspect shadowbox >/dev/null 2>&1; then
    if [[ "${SHOW_FORMAT:-text}" == json ]]; then echo '[]'; else echo "outline: not installed"; fi
    return 0
  fi
  local prefix port pin keys
  prefix=$(container_env SB_API_PREFIX)
  port=$(container_env SB_API_PORT)
  pin=$(openssl x509 -in "$API_CERT" -pubkey -noout | openssl pkey -pubin -outform der |
    openssl dgst -sha256 -binary | base64)
  keys=$(curl -fsS --max-time 10 --retry 3 --retry-connrefused --retry-delay 1 -k \
    --pinnedpubkey "sha256//${pin}" "https://localhost:${port}/${prefix}/access-keys")
  if [[ "${SHOW_FORMAT:-text}" == json ]]; then
    keys_to_outbounds "${STATIC_IP}" <<<"$keys"
  else
    echo "Outline access keys (ss://) — import into the Outline client:"
    keys_to_text <<<"$keys"
  fi
}

[[ -n "${NETGURU_SOURCE_ONLY:-}" ]] || main
