# shellcheck shell=bash
# The diff decides whether we touch a firewall rule: false "equal" leaves holes, false "different" churns rules.

fw() { cat "${FIXTURES}/$1"; }

expect_eq "rule matching its spec has no diff" \
  "$(firewall_rule_diff "$(fw fw-outline.json)" 0.0.0.0/0 tcp:45362,udp:45362)" \
  ""
expect_eq "rule order in desired list does not matter" \
  "$(firewall_rule_diff "$(fw fw-outline.json)" 0.0.0.0/0 udp:45362,tcp:45362)" \
  ""
expect_eq "changed priority is reported" \
  "$(firewall_rule_diff "$(fw fw-outline.json | jq '.priority = 800')" 0.0.0.0/0 tcp:45362,udp:45362)" \
  "priority"
expect_eq "same-named rule on another network is reported as network" \
  "$(NETWORK_NAME=default firewall_rule_diff "$(fw fw-outline.json)" 0.0.0.0/0 tcp:45362,udp:45362)" \
  "network"
expect_eq "deny rule is reported as action" \
  "$(firewall_rule_diff "$(fw fw-outline.json | jq '.denied = .allowed | del(.allowed)')" 0.0.0.0/0 tcp:45362,udp:45362)" \
  "action"
expect_eq "multiple ports in one block and unordered ranges normalise" \
  "$(firewall_rule_diff "$(fw fw-multiport.json)" 10.0.0.0/8,35.235.240.0/20 tcp:443,tcp:8443)" \
  ""
expect_eq "changed source range and ports are both reported" \
  "$(firewall_rule_diff "$(fw fw-multiport.json)" 35.235.240.0/20 tcp:443)" \
  "source-ranges rules"
expect_eq "wrong target tag is reported" \
  "$(NETWORK_TAG=other firewall_rule_diff "$(fw fw-outline.json)" 0.0.0.0/0 tcp:45362,udp:45362)" \
  "target-tags"

# Rule names come from the tag, so a renamed VM can never reuse another VM's rule. Turned-off services' rules stay
# managed, so infra can delete them.
expect_eq "managed rule names derive from NETWORK_TAG" \
  "$(managed_fw_rules | tr '\n' ' ')" \
  "netguru-server-ssh-iap netguru-server-outline netguru-server-sing-box "
# The VM's network must hold only netguru's rules; rules on other networks don't matter.
expect_eq "unmanaged rule on our network is reported, other networks ignored" \
  "$(foreign_fw_rules "$(fw fw-list.json)")" \
  "netguru-server-open-all"
expect_eq "only managed rules: nothing reported" \
  "$(foreign_fw_rules "$(fw fw-list.json | jq 'map(select(.name != "netguru-server-open-all"))')")" \
  ""

# A turned-off service's rule is deleted, but only on netguru's network: a same-named rule elsewhere isn't ours.
# fw_remove EXISTS NETWORK — remove_service_firewall outline against a stubbed gcloud; prints its mutations.
# shellcheck disable=SC2329 # stubs invoked by remove_service_firewall in lib.sh
fw_remove() {
  local exists=$1 rule_network=$2 # not "network": remove_service_firewall's local of that name would shadow it
  gcloud_resource_exists() { [[ "$exists" == yes ]]; }
  run_gcloud() {
    if [[ " $* " == *" describe "* ]]; then
      fw fw-outline.json | jq --arg n "$rule_network" '.network = "projects/p/global/networks/\($n)"'
    else
      echo "$*"
    fi
  }
  remove_service_firewall outline
}
expect_eq   "a turned-off service's rule is deleted" \
  "$(fw_remove yes netguru-net 2>/dev/null)" "compute firewall-rules delete netguru-server-outline"
expect_eq   "no rule: nothing to delete"                         "$(fw_remove no netguru-net 2>/dev/null)" ""
expect_fail "a same-named rule on another network is refused"    fw_remove yes default
expect_eq   "a same-named rule on another network is never deleted" "$(fw_remove yes default 2>/dev/null)" ""
