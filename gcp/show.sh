#!/usr/bin/env bash
# Print client configs for every enabled service (spec §4.5, §4.6).
# SHOW_FORMAT=text (default) for humans, also writing the sing-box client profiles to netguru-client.json and
# netguru-client-full.json in the repo root;
# SHOW_FORMAT=json for a JSON array of sing-box outbounds.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

SHOW_FORMAT=${SHOW_FORMAT:-text}
[[ "$SHOW_FORMAT" == text || "$SHOW_FORMAT" == json ]] || die "SHOW_FORMAT must be text or json (got '${SHOW_FORMAT}')"
require_bool CLIENT_BYPASS_CN "${CLIENT_BYPASS_CN}"
PROFILE_FILE="${NETGURU_ROOT}/netguru-client.json"
FULL_PROFILE_FILE="${NETGURU_ROOT}/netguru-client-full.json"
STATIC_IP=$(get_static_ip)
require_ipv4 STATIC_IP "${STATIC_IP}"

# show_service SERVICE FORMAT — run the service's VM-side show.sh (FORMAT: text or json).
show_service() {
  local SHOW_FORMAT=$2
  load_service "$1"
  # shellcheck disable=SC2086 # REMOTE_VARS is a space-separated list of variable names
  run_remote "${SERVICE_DIR}/show.sh" STATIC_IP SHOW_FORMAT ${REMOTE_VARS}
}

all_outbounds() {
  local s
  # `|| exit 1`: one failed SSH must fail the whole list, never yield a list missing that service's servers.
  for s in ${SERVICES}; do (show_service "$s" json) || exit 1; done | jq -s 'add'
}

if [[ "$SHOW_FORMAT" == json ]]; then
  all_outbounds
  exit 0
fi

echo "== netguru: ${VM_NAME} (${GCP_ZONE}) — ${STATIC_IP}"
for s in ${SERVICES}; do
  echo
  echo "== ${s}"
  (show_service "$s" text)
done
outbounds=$(all_outbounds) # all services or nothing: a partial profile would silently drop servers
write_client_profile "${PROFILE_FILE}" <<<"$outbounds"
CLIENT_BYPASS_CN=false write_client_profile "${FULL_PROFILE_FILE}" <<<"$outbounds"
echo
echo "== sing-box client profiles (SFI/SFA/SFM 1.14+; contain secrets):"
echo "   ${PROFILE_FILE} (default; CLIENT_BYPASS_CN=${CLIENT_BYPASS_CN})"
echo "   ${FULL_PROFILE_FILE} (full-tunnel fallback, no rule-set download on first start)"
echo "   Import: Profiles → New Profile → Local → Import, or paste into Edit Content"
