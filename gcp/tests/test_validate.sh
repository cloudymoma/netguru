# shellcheck shell=bash
# Literal $ inside single quotes is the input under test:
# shellcheck disable=SC2016
# Validators guard every value that reaches gcloud or the VM: bad input must fail before any side effect.

expect_ok   "port 1 is valid"                 require_port P 1
expect_ok   "port 65535 is valid"             require_port P 65535
expect_fail "port 0 is rejected"              require_port P 0
expect_fail "port 65536 is rejected"          require_port P 65536
expect_fail "non-numeric port is rejected"    require_port P 44a
expect_fail "empty port is rejected"          require_port P ""
expect_fail "zero-padded port is rejected (bash reads it as octal)" require_port P 0443
expect_fail "zero-padded 22 cannot slip past the SSH guard"         require_port P 00022
expect_fail "port 08 is rejected, not an arithmetic error"          require_port P 08

expect_ok   "IPv4 accepted"                   require_ipv4 IP 203.0.113.100
expect_fail "octet >255 rejected"             require_ipv4 IP 203.0.113.256
expect_fail "hostname is not an IPv4"         require_ipv4 IP example.com
expect_fail "IPv4 with suffix rejected"       require_ipv4 IP "1.2.3.4;rm"

expect_ok   "hostname accepted"               require_hostname H www.yahoo.co.jp
expect_fail "shell metachars rejected"        require_hostname H 'www.a.com$(id)'
expect_fail "bare label rejected"             require_hostname H localhost
expect_fail "IP is not a hostname"            require_hostname H 1.2.3.4

expect_ok   "sha256 accepted"                 require_sha256 S e7594b713d19b365765690624afbabe3c97ab96eb377d43630fc3c6a27d5b986
expect_fail "short sha256 rejected"           require_sha256 S e7594b71
expect_fail "uppercase sha256 rejected"       require_sha256 S E7594B713D19B365765690624AFBABE3C97AB96EB377D43630FC3C6A27D5B986

expect_ok   "gpg fingerprint accepted"        require_gpg_fpr F 2C317FBD5D886B4E89BAE8DA6D9152172A2B2F0C
expect_fail "gpg fingerprint with spaces"     require_gpg_fpr F "2C31 7FBD 5D88 6B4E 89BA E8DA 6D91 5217 2A2B 2F0C"

expect_ok   "true is a bool"                  require_bool B true
expect_fail "yes is not a bool"               require_bool B yes

expect_fail "TBD placeholder rejected"        require_not_tbd V "<TBD: pick one>"
expect_fail "empty value rejected"            require_not_tbd V ""
expect_ok   "real value accepted"             require_not_tbd V du-hast-mich

expect_eq   "die message names the variable" \
  "$( (require_port OUTLINE_KEYS_PORT 0) 2>&1)" \
  "ERROR: OUTLINE_KEYS_PORT must be a port 1-65535 (got '0')"
