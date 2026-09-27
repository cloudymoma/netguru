#!/usr/bin/env bash
# Print client configs for every enabled service (spec §4.5, §4.6).
# SHOW_FORMAT=text (default) for humans; SHOW_FORMAT=json for a JSON array of sing-box outbounds.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

SHOW_FORMAT=${SHOW_FORMAT:-text}
[[ "$SHOW_FORMAT" == text || "$SHOW_FORMAT" == json ]] || die "SHOW_FORMAT must be text or json (got '${SHOW_FORMAT}')"
STATIC_IP=$(get_static_ip)
require_ipv4 STATIC_IP "${STATIC_IP}"

show_service() {
  load_service "$1"
  # shellcheck disable=SC2086 # REMOTE_VARS is a space-separated list of variable names
  run_remote "${SERVICE_DIR}/show.sh" STATIC_IP SHOW_FORMAT ${REMOTE_VARS}
}

if [[ "$SHOW_FORMAT" == json ]]; then
  for s in ${SERVICES}; do (show_service "$s"); done | jq -s 'add'
  exit 0
fi

echo "== netguru: ${VM_NAME} (${GCP_ZONE}) — ${STATIC_IP}"
for s in ${SERVICES}; do
  echo
  echo "== ${s}"
  (show_service "$s")
done
