# shellcheck shell=bash
# The diff decides whether we touch a live firewall rule: false "equal" leaves holes, false "different" churns rules.

fw() { cat "${FIXTURES}/$1"; }

expect_eq "live outline rule differs only in priority (1000 -> 800)" \
  "$(firewall_rule_diff "$(fw fw-outline-access.json)" allow 800 0.0.0.0/0 tcp:44923,udp:44923)" \
  "priority"
expect_eq "rule order in desired list does not matter" \
  "$(firewall_rule_diff "$(fw fw-outline-access.json)" allow 1000 0.0.0.0/0 udp:44923,tcp:44923)" \
  ""
expect_eq "deny-all matches desired deny all" \
  "$(firewall_rule_diff "$(fw fw-deny-all.json)" deny 900 0.0.0.0/0 all)" \
  ""
expect_eq "allow vs deny is reported as action" \
  "$(firewall_rule_diff "$(fw fw-deny-all.json)" allow 900 0.0.0.0/0 all)" \
  "action"
expect_eq "multiple ports in one block and unordered ranges normalise" \
  "$(firewall_rule_diff "$(fw fw-multiport.json)" allow 800 10.0.0.0/8,35.235.240.0/20 tcp:443,tcp:8443)" \
  ""
expect_eq "changed source range and ports are both reported" \
  "$(firewall_rule_diff "$(fw fw-multiport.json)" allow 800 35.235.240.0/20 tcp:443)" \
  "source-ranges rules"
expect_eq "wrong target tag is reported" \
  "$(NETWORK_TAG=other firewall_rule_diff "$(fw fw-deny-all.json)" deny 900 0.0.0.0/0 all)" \
  "target-tags"
