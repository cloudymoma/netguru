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
