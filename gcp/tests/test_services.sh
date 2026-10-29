# shellcheck shell=bash
# Literal $ inside single quotes is the input under test:
# shellcheck disable=SC2016
# Two services sharing a port would silently break one of them; SSH must never be claimed.

expect_eq "enabled services expose their declared ports (Outline off by default)" \
  "$(list_service_ports)" \
  "sing-box tcp:443
sing-box udp:8443"
expect_eq "with Outline on, it is deployed first and exposes its port" \
  "$(SERVICES="outline sing-box" list_service_ports)" \
  "outline tcp:45362
outline udp:45362
sing-box tcp:443
sing-box udp:8443"

# Each service has a <NAME>_ENABLED switch; SERVICES is derived from them (Outline is off by default).
expect_eq   "Outline is off and sing-box on by default" "${OUTLINE_ENABLED}:${SINGBOX_ENABLED}:${SERVICES}" "false:true:sing-box"
expect_eq   "switch names: upper-cased, dashes dropped" "$(service_switch outline) $(service_switch sing-box)" \
  "OUTLINE_ENABLED SINGBOX_ENABLED"
expect_eq   "OUTLINE_ENABLED=true deploys Outline first" "$(OUTLINE_ENABLED=true enabled_services)" "outline sing-box"
expect_eq   "SINGBOX_ENABLED=false leaves only Outline" \
  "$(OUTLINE_ENABLED=true SINGBOX_ENABLED=false enabled_services)" "outline"
expect_fail "a switch must be true or false"         bash -c '. gcp/lib.sh; OUTLINE_ENABLED=yes; validate_config'
expect_fail "every service needs its switch"         bash -c '. gcp/lib.sh; unset SINGBOX_ENABLED; validate_config'
expect_fail "at least one service must be on" \
  bash -c '. gcp/lib.sh; SINGBOX_ENABLED=false; SERVICES=$(enabled_services); validate_config'
expect_ok   "Outline switched on validates" \
  bash -c '. gcp/lib.sh; OUTLINE_ENABLED=true; SERVICES=$(enabled_services); validate_config'
expect_eq   "every service module is known, on or off"       "$(known_services | tr '\n' ' ')" "outline sing-box "
expect_eq   "Outline is the turned-off service by default"   "$(disabled_services)" "outline"
expect_eq   "nothing is turned off when every service is on" "$(SERVICES="outline sing-box" disabled_services)" ""

# make infra stops each turned-off service with its VM-side remote-disable.sh, and nothing else.
# shellcheck disable=SC2329 # run_remote stub invoked by retire_disabled_services
retire_calls() { run_remote() { echo "run_remote $*"; }; retire_disabled_services 2>/dev/null; }
expect_eq "turned-off Outline is stopped on the VM" \
  "$(retire_calls)" "run_remote ${GCP_DIR}/services/outline/remote-disable.sh"
expect_eq "turned-off sing-box is stopped on the VM" \
  "$(SERVICES="outline" retire_calls)" "run_remote ${GCP_DIR}/services/sing-box/remote-disable.sh"
expect_eq "nothing is stopped when every service is on" "$(SERVICES="outline sing-box" retire_calls)" ""

expect_ok   "current config has no collisions"  bash -c '. gcp/lib.sh; list_service_ports | check_port_collisions'
expect_ok   "same port on tcp and udp is fine"  bash -c '. gcp/lib.sh; printf "a tcp:443\nb udp:443\n" | check_port_collisions'
expect_fail "duplicate tcp port is rejected"    bash -c '. gcp/lib.sh; printf "a tcp:443\nb tcp:443\n" | check_port_collisions'
expect_fail "tcp:22 is reserved for SSH"        bash -c '. gcp/lib.sh; printf "a tcp:22\n" | check_port_collisions'
expect_fail "port ranges are rejected"          bash -c '. gcp/lib.sh; printf "a tcp:443-450\n" | check_port_collisions'
expect_fail "missing port is rejected"          bash -c '. gcp/lib.sh; printf "a tcp:\n" | check_port_collisions'
expect_fail "uppercase protocol is rejected"    bash -c '. gcp/lib.sh; printf "a TCP:443\n" | check_port_collisions'

expect_fail "unknown service is rejected"       load_service nope
expect_ok   "service_enabled finds sing-box"    service_enabled sing-box
expect_fail "service_enabled rejects partial names" service_enabled sing

expect_ok   "outline config validates"          bash -c '. gcp/lib.sh; load_service outline; service_validate'
expect_ok   "sing-box config validates"         bash -c '. gcp/lib.sh; load_service sing-box; service_validate'
expect_fail "TBD SNI fails sing-box validation" bash -c '. gcp/lib.sh; SINGBOX_REALITY_SNI="<TBD>"; load_service sing-box; service_validate'

expect_eq "remote command quotes values" \
  "$(STATIC_IP=1.2.3.4 X='a b$c' build_remote_cmd STATIC_IP X)" \
  'sudo env STATIC_IP=1.2.3.4 X=a\ b\$c bash -s'
expect_fail "unset remote var is rejected"      build_remote_cmd NETGURU_DEFINITELY_UNSET
expect_fail "invalid remote var name rejected"  build_remote_cmd 'X;id'

expect_ok   "full config validates"             validate_config
expect_fail "empty subnet range is rejected"    bash -c '. gcp/lib.sh; SUBNET_RANGE=""; validate_config'
# gcloud defaults an unset source range to 0.0.0.0/0, which would open SSH to the internet.
expect_fail "empty IAP source range is rejected" bash -c '. gcp/lib.sh; IAP_SOURCE_RANGE=""; validate_config'
# Call inside `if` so errexit is suppressed: the subshell failure on the first service must still propagate.
expect_fail "unknown first service fails list_service_ports (errexit off)" \
  bash -c '. gcp/lib.sh; SERVICES="nope sing-box"; if list_service_ports; then exit 0; else exit 1; fi'
expect_fail "bad service config fails validate_config" \
  bash -c '. gcp/lib.sh; SINGBOX_REALITY_SNI="<TBD>"; if validate_config; then exit 0; else exit 1; fi'
expect_fail "bad first service fails validate_config (errexit off)" \
  bash -c '. gcp/lib.sh; OUTLINE_ENABLED=true; SERVICES=$(enabled_services); OUTLINE_API_PORT=bad; if validate_config; then exit 0; else exit 1; fi'

# Install/upgrade targets come from the network: anything but one stable version / one digest must stop the run.
expect_eq   "stable GitHub release resolves to X.Y.Z" \
  "$(echo '{"tag_name":"v1.14.2","draft":false,"prerelease":false}' | release_json_to_version)" "1.14.2"
expect_fail "pre-release is never a target"      bash -c ". gcp/lib.sh; echo '{\"tag_name\":\"v1.15.0-alpha.1\",\"draft\":false,\"prerelease\":true}' | release_json_to_version"
expect_fail "non-semver tag is rejected"         bash -c ". gcp/lib.sh; echo '{\"tag_name\":\"nightly\",\"draft\":false,\"prerelease\":false}' | release_json_to_version"
expect_eq   "quay tag resolves to its digest" \
  "$(echo '{"tags":[{"name":"stable","manifest_digest":"sha256:545c6f7c7261bb30ae1dffe24a6fca5f8512f5d17c72cfb9e410e7e655444e62"}]}' | quay_json_to_digest)" \
  "sha256:545c6f7c7261bb30ae1dffe24a6fca5f8512f5d17c72cfb9e410e7e655444e62"
expect_fail "missing quay tag is rejected"       bash -c ". gcp/lib.sh; echo '{\"tags\":[]}' | quay_json_to_digest"
expect_ok   "sing-box accepts latest"            bash -c '. gcp/lib.sh; SINGBOX_VERSION=latest; load_service sing-box; service_validate'
expect_ok   "sing-box accepts an X.Y.Z pin"      bash -c '. gcp/lib.sh; SINGBOX_VERSION=1.14.2; load_service sing-box; service_validate'
expect_fail "sing-box rejects the stable alias"  bash -c '. gcp/lib.sh; SINGBOX_VERSION=stable; load_service sing-box; service_validate'
expect_fail "outline rejects non-quay images"    bash -c '. gcp/lib.sh; OUTLINE_IMAGE_REPO=docker.io/evil/shadowbox; load_service outline; service_validate'
