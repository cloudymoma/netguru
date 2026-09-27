# shellcheck shell=bash
# Shared helpers for netguru host-side scripts. Source this file; do not execute it.
set -euo pipefail

NETGURU_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GCP_DIR="${NETGURU_ROOT}/gcp"
# shellcheck source=config.env
. "${GCP_DIR}/config.env"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*" >&2; }
warn() { echo "WARN: $*" >&2; }

# --- validators: require_<kind> NAME VALUE -----------------------------------
require_not_tbd() {
  [[ -n "$2" && "$2" != *"<TBD"* ]] || die "$1 is not set (got '$2')"
}
require_port() {
  if ! [[ "$2" =~ ^[0-9]{1,5}$ ]] || (($2 < 1 || $2 > 65535)); then
    die "$1 must be a port 1-65535 (got '$2')"
  fi
}
require_ipv4() {
  local octet='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
  [[ "$2" =~ ^${octet}\.${octet}\.${octet}\.${octet}$ ]] || die "$1 must be an IPv4 address (got '$2')"
}
require_hostname() {
  [[ "$2" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]] ||
    die "$1 must be a DNS hostname (got '$2')"
}
require_sha256() {
  [[ "$2" =~ ^[0-9a-f]{64}$ ]] || die "$1 must be a lowercase hex SHA-256 (got '$2')"
}
require_gpg_fpr() {
  [[ "$2" =~ ^[0-9A-F]{40}$ ]] || die "$1 must be a 40-char uppercase GPG fingerprint (got '$2')"
}
require_bool() {
  [[ "$2" == true || "$2" == false ]] || die "$1 must be true or false (got '$2')"
}

# --- service modules (spec §4.4) --------------------------------------------
service_enabled() { [[ " ${SERVICES} " == *" $1 "* ]]; }

load_service() {
  SERVICE_DIR="${GCP_DIR}/services/$1"
  [[ -f "${SERVICE_DIR}/service.env" ]] || die "unknown service '$1' (no ${SERVICE_DIR}/service.env)"
  unset FW_RULE_NAME FW_RULES REMOTE_VARS
  unset -f service_validate service_prepare
  # shellcheck disable=SC1091
  . "${SERVICE_DIR}/service.env"
  [[ -n "${FW_RULE_NAME:-}" && -n "${FW_RULES:-}" ]] || die "service '$1': FW_RULE_NAME and FW_RULES are required"
  declare -F service_validate >/dev/null || die "service '$1': service_validate() is required"
  REMOTE_VARS="${REMOTE_VARS:-}"
}

list_service_ports() {
  local s
  for s in ${SERVICES}; do
    (load_service "$s" && tr ',' '\n' <<<"${FW_RULES}" | sed "s/^/${s} /")
  done
}

check_port_collisions() {
  awk '
    $2 !~ /^(tcp|udp):[0-9]+$/ { printf "service %s: malformed port entry \"%s\" (want tcp:N or udp:N)\n", $1, $2; bad = 1; next }
    $2 == "tcp:22"             { printf "service %s claims tcp:22 (reserved for SSH)\n", $1; bad = 1 }
    ($2 in seen)               { printf "port %s claimed by both %s and %s\n", $2, seen[$2], $1; bad = 1 }
                               { seen[$2] = $1 }
    END                        { exit bad }' >&2 || die "service port check failed"
}

# build_remote_cmd VAR... -> "sudo env VAR=<quoted> ... bash -s" (values must be non-secret)
build_remote_cmd() {
  local cmd="sudo env" v
  for v in "$@"; do
    [[ "$v" =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "invalid variable name '$v'"
    [[ -n "${!v+x}" ]] || die "variable $v is not set"
    cmd+=" ${v}=$(printf '%q' "${!v}")"
  done
  printf '%s bash -s' "$cmd"
}

validate_config() {
  local v
  for v in GCP_PROJECT GCP_REGION GCP_ZONE VM_NAME NETWORK_NAME NETWORK_TAG STATIC_IP_NAME SERVICES; do
    require_not_tbd "$v" "${!v}"
  done
  ((FW_ALLOW_PRIORITY < FW_DENY_PRIORITY)) ||
    die "FW_ALLOW_PRIORITY (${FW_ALLOW_PRIORITY}) must be lower than FW_DENY_PRIORITY (${FW_DENY_PRIORITY})"
  list_service_ports | check_port_collisions
}

# --- install/upgrade targets, resolved on the workstation (spec §4.10) ---------
release_json_to_version() {
  local v
  v=$(jq -r 'if .draft == false and .prerelease == false then .tag_name else "" end | ltrimstr("v")')
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "latest GitHub release is not a stable X.Y.Z release (got '${v}')"
  echo "$v"
}

quay_json_to_digest() {
  local d
  d=$(jq -r 'if (.tags | length) == 1 then .tags[0].manifest_digest else "" end')
  [[ "$d" =~ ^sha256:[0-9a-f]{64}$ ]] || die "quay.io did not return exactly one digest for the tag (got '${d}')"
  echo "$d"
}

github_latest_version() {
  curl -fsS --max-time 20 "https://api.github.com/repos/$1/releases/latest" | release_json_to_version
}

quay_tag_digest() {
  curl -fsS --max-time 20 "https://quay.io/api/v1/repository/${1#quay.io/}/tag/?specificTag=$2&onlyActiveTags=true" |
    quay_json_to_digest
}
