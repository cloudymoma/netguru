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

# Rule names come from the tag, so a renamed VM can never reuse another VM's rule.
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
