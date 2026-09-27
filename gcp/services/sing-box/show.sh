#!/usr/bin/env bash
# VM-side (root): print sing-box client configs (spec §4.6).
# Env: STATIC_IP SHOW_FORMAT(text|json) SINGBOX_REALITY_PORT SINGBOX_REALITY_SNI SINGBOX_HY2_PORT SINGBOX_HY2_SNI
set -euo pipefail

ETC=/etc/sing-box

vless_uri() {
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#netguru-reality\n' \
    "$VLESS_UUID" "$STATIC_IP" "$SINGBOX_REALITY_PORT" "$SINGBOX_REALITY_SNI" "$REALITY_PUBLIC_KEY" "$REALITY_SHORT_ID"
}

hy2_uri() {
  printf 'hysteria2://%s@%s:%s?sni=%s&alpn=h3&insecure=1&pinSHA256=%s#netguru-hy2\n' \
    "$HY2_PASSWORD" "$STATIC_IP" "$SINGBOX_HY2_PORT" "$SINGBOX_HY2_SNI" "$HY2_CERT_SHA256"
}

client_outbounds() {
  jq -n --arg ip "$STATIC_IP" --arg uuid "$VLESS_UUID" --arg pbk "$REALITY_PUBLIC_KEY" \
    --arg sid "$REALITY_SHORT_ID" --arg sni "$SINGBOX_REALITY_SNI" --argjson rport "$SINGBOX_REALITY_PORT" \
    --arg pass "$HY2_PASSWORD" --arg hsni "$SINGBOX_HY2_SNI" --argjson hport "$SINGBOX_HY2_PORT" \
    --arg pem "$HY2_CERT_PEM" '[
    {type: "vless", tag: "netguru-reality", server: $ip, server_port: $rport,
     uuid: $uuid, flow: "xtls-rprx-vision",
     tls: {enabled: true, server_name: $sni, utls: {enabled: true, fingerprint: "chrome"},
           reality: {enabled: true, public_key: $pbk, short_id: $sid}}},
    {type: "hysteria2", tag: "netguru-hy2", server: $ip, server_port: $hport, password: $pass,
     tls: {enabled: true, server_name: $hsni, alpn: ["h3"],
           certificate: ($pem | split("\n") | map(select(length > 0)))}}
  ]'
}

main() {
  if [[ ! -f "${ETC}/credentials.env" || ! -f "${ETC}/certs/hy2.crt" ]]; then
    if [[ "${SHOW_FORMAT:-text}" == json ]]; then echo '[]'; else echo "sing-box: not installed"; fi
    return 0
  fi
  # shellcheck disable=SC1091
  . "${ETC}/credentials.env"
  HY2_CERT_PEM=$(cat "${ETC}/certs/hy2.crt")
  HY2_CERT_SHA256=$(openssl x509 -in "${ETC}/certs/hy2.crt" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d :)
  if [[ "${SHOW_FORMAT:-text}" == json ]]; then
    client_outbounds
    return 0
  fi
  cat <<TEXT
VLESS-REALITY (tcp/${SINGBOX_REALITY_PORT}):
  $(vless_uri)

Hysteria2 (udp/${SINGBOX_HY2_PORT}) — only use clients that honor pinSHA256 (official Hysteria2, sing-box based):
  $(hy2_uri)
TEXT
}

[[ -n "${NETGURU_SOURCE_ONLY:-}" ]] || main
