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

# --- gcloud / SSH -------------------------------------------------------------
run_gcloud() { gcloud --project="${GCP_PROJECT}" --quiet "$@"; }

gcp_ssh() { run_gcloud compute ssh "${VM_NAME}" --zone="${GCP_ZONE}" --tunnel-through-iap --command="$1"; }

# run_remote SCRIPT VAR... — stream a VM-side script over stdin; run as root with VARs in env.
run_remote() {
  local script=$1; shift
  [[ -f "$script" ]] || die "remote script not found: ${script}"
  gcp_ssh "$(build_remote_cmd "$@")" <"$script"
}

wait_for_ssh() {
  local i
  for i in $(seq 1 30); do
    gcp_ssh true >/dev/null 2>&1 && return 0
    log "waiting for SSH over IAP (${i}/30)"
    sleep 5
  done
  die "SSH over IAP to ${VM_NAME} not available after 150s"
}

# gcloud_resource_exists <describe args...> -> 0 exists, 1 not found, dies on any other error
gcloud_resource_exists() {
  local err
  if err=$(run_gcloud "$@" --format='value(name)' 2>&1 >/dev/null); then return 0; fi
  [[ "$err" == *"was not found"* || "$err" == *"notFound"* ]] && return 1
  die "gcloud $* failed: ${err}"
}

# --- firewall (spec §4.2) -----------------------------------------------------
# firewall_rule_diff ACTUAL_JSON ACTION PRIORITY RANGES RULES -> differing field names, space-separated
firewall_rule_diff() {
  jq -r --arg network "${NETWORK_NAME}" --arg tag "${NETWORK_TAG}" \
    --arg action "$2" --arg priority "$3" --arg ranges "$4" --arg rules "$5" '
    def norm: split(",") | map(select(length > 0)) | sort | join(",");
    def actual_rules:
      (.allowed // .denied // [])
      | map(if .IPProtocol == "all" then "all"
            else .IPProtocol as $p | (.ports // [""])[] | if . == "" then $p else "\($p):\(.)" end
            end)
      | sort | join(",");
    [ (if (.network | split("/") | last) != $network then "network" else empty end),
      (if .direction != "INGRESS" then "direction" else empty end),
      (if (if .allowed then "allow" else "deny" end) != $action then "action" else empty end),
      (if (.priority | tostring) != $priority then "priority" else empty end),
      (if ((.sourceRanges // []) | sort | join(",")) != ($ranges | norm) then "source-ranges" else empty end),
      (if ((.targetTags // []) | sort | join(",")) != $tag then "target-tags" else empty end),
      (if actual_rules != ($rules | norm) then "rules" else empty end)
    ] | join(" ")' <<<"$1"
}

# ensure_firewall_rule NAME ACTION(allow|deny) PRIORITY SOURCE_RANGES RULES("tcp:443,udp:8443" | "all")
ensure_firewall_rule() {
  local name=$1 action=$2 priority=$3 ranges=$4 rules=$5 actual diff
  if ! gcloud_resource_exists compute firewall-rules describe "$name"; then
    log "creating firewall rule ${name}: ${action} ${rules} from ${ranges} (priority ${priority})"
    run_gcloud compute firewall-rules create "$name" --network="${NETWORK_NAME}" --direction=INGRESS \
      --action="$action" --rules="$rules" --priority="$priority" --source-ranges="$ranges" \
      --target-tags="${NETWORK_TAG}" --description="managed by netguru"
    return
  fi
  actual=$(run_gcloud compute firewall-rules describe "$name" --format=json)
  diff=$(firewall_rule_diff "$actual" "$action" "$priority" "$ranges" "$rules")
  if [[ -z "$diff" ]]; then
    log "firewall rule ${name} is up to date"
    return
  fi
  case " ${diff} " in
    *" network "* | *" direction "* | *" action "*)
      die "firewall rule ${name} differs in immutable field(s) (${diff}); delete it manually and re-run" ;;
  esac
  log "updating firewall rule ${name} (${diff})"
  run_gcloud compute firewall-rules update "$name" --rules="$rules" --priority="$priority" \
    --source-ranges="$ranges" --target-tags="${NETWORK_TAG}"
}

delete_firewall_rule_if_exists() {
  if gcloud_resource_exists compute firewall-rules describe "$1"; then
    log "deleting firewall rule $1"
    run_gcloud compute firewall-rules delete "$1"
  else
    log "firewall rule $1 already absent"
  fi
}

ensure_service_firewall() {
  (load_service "$1" && ensure_firewall_rule "${FW_RULE_NAME}" allow "${FW_ALLOW_PRIORITY}" 0.0.0.0/0 "${FW_RULES}")
}

# Order is a safety invariant (spec §4.2): never create the deny before SSH-over-IAP works
# and every service allow already outranks it.
ensure_base_firewall() {
  run_gcloud services enable iap.googleapis.com
  ensure_firewall_rule "${FW_SSH_IAP}" allow "${FW_ALLOW_PRIORITY}" "${IAP_SOURCE_RANGE}" tcp:22
  log "verifying SSH over IAP"
  gcp_ssh true || die "SSH over IAP failed; refusing to create ${FW_DENY_ALL} (would risk lock-out)"
  local s
  for s in ${SERVICES}; do ensure_service_firewall "$s"; done
  ensure_firewall_rule "${FW_DENY_ALL}" deny "${FW_DENY_PRIORITY}" 0.0.0.0/0 all
}

# --- static IP / VM (spec §4.3) -----------------------------------------------
get_static_ip() {
  run_gcloud compute addresses describe "${STATIC_IP_NAME}" --region="${GCP_REGION}" --format='value(address)'
}

ensure_static_ip() {
  if gcloud_resource_exists compute addresses describe "${STATIC_IP_NAME}" --region="${GCP_REGION}"; then
    log "static IP ${STATIC_IP_NAME} = $(get_static_ip)"
  else
    log "reserving static IP ${STATIC_IP_NAME}"
    run_gcloud compute addresses create "${STATIC_IP_NAME}" --region="${GCP_REGION}" --network-tier=PREMIUM
  fi
}

vm_json() { run_gcloud compute instances describe "${VM_NAME}" --zone="${GCP_ZONE}" --format=json; }

# vm_invariant_problems VM_JSON STATIC_IP -> "; "-joined drift descriptions (empty = OK)
vm_invariant_problems() {
  jq -r --arg tag "${NETWORK_TAG}" --arg ip "$2" '
    (.networkInterfaces[0].accessConfigs[0].natIP // "none") as $nat
    | [ (if .status != "RUNNING" then "status \(.status)" else empty end),
        (if ((.tags.items // []) | index($tag)) == null then "missing tag \($tag)" else empty end),
        (if $nat != $ip then "external IP \($nat) != static \($ip)" else empty end)
      ] | join("; ")' <<<"$1"
}

# vm_hardening_gaps VM_JSON -> ", "-joined missing hardening items (empty = hardened)
vm_hardening_gaps() {
  jq -r '
    [ (if ((.serviceAccounts // []) | length) > 0 then "service account attached" else empty end),
      (if .shieldedInstanceConfig.enableSecureBoot != true then "secure boot off" else empty end),
      (if ((.metadata.items // []) | map(.key) | index("startup-script")) != null then "startup-script present" else empty end),
      (if .deletionProtection != true then "deletion protection off" else empty end)
    ] | join(", ")' <<<"$1"
}

ensure_vm() {
  if ! gcloud_resource_exists compute instances describe "${VM_NAME}" --zone="${GCP_ZONE}"; then
    log "creating VM ${VM_NAME}"
    run_gcloud compute instances create "${VM_NAME}" --zone="${GCP_ZONE}" \
      --machine-type="${VM_MACHINE_TYPE}" --boot-disk-size="${VM_DISK_SIZE}" \
      --image-family="${VM_IMAGE_FAMILY}" --image-project="${VM_IMAGE_PROJECT}" \
      --network="${NETWORK_NAME}" --tags="${NETWORK_TAG}" \
      --address="${STATIC_IP_NAME}" --network-tier=PREMIUM \
      --no-service-account --no-scopes \
      --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring \
      --metadata=enable-oslogin=TRUE --deletion-protection
  fi
  local vm problems gaps
  vm=$(vm_json)
  if [[ "$(jq -r .status <<<"$vm")" == "TERMINATED" ]]; then
    log "starting VM ${VM_NAME}"
    run_gcloud compute instances start "${VM_NAME}" --zone="${GCP_ZONE}"
    vm=$(vm_json)
  fi
  problems=$(vm_invariant_problems "$vm" "$(get_static_ip)")
  [[ -z "$problems" ]] || die "VM ${VM_NAME} drifted from config: ${problems}"
  gaps=$(vm_hardening_gaps "$vm")
  [[ -z "$gaps" ]] || warn "VM ${VM_NAME} is not hardened (${gaps}); run: make harden CONFIRM=1"
}

# vm_startup_script VM_JSON -> startup-script metadata value (empty if none)
vm_startup_script() {
  jq -r '(.metadata.items // [])[] | select(.key == "startup-script") | .value' <<<"$1"
}

# vm_offline_hardening_needed VM_JSON -> yes if a stop/start is needed (SA attached or Secure Boot off)
vm_offline_hardening_needed() {
  jq -r 'if ((.serviceAccounts // []) | length) > 0 or .shieldedInstanceConfig.enableSecureBoot != true
         then "yes" else "no" end' <<<"$1"
}

# ip_rotation_state RESERVED_IP(empty if none) VM_IP(empty if none) -> attach|rotate|release|promote (spec §4.8)
ip_rotation_state() {
  if [[ -z "$2" ]]; then echo attach
  elif [[ -z "$1" ]]; then echo promote
  elif [[ "$1" == "$2" ]]; then echo rotate
  else echo release
  fi
}
