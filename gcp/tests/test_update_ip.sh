# shellcheck shell=bash
# A rotation interrupted at any point must resume at the right step, never lose the static IP name.
expect_eq "reservation holds VM IP: rotate"            "$(ip_rotation_state 203.0.113.100 203.0.113.100)" "rotate"
expect_eq "VM has new IP, old reservation: release"    "$(ip_rotation_state 203.0.113.100 35.1.2.3)"      "release"
expect_eq "reservation missing: promote the VM IP"     "$(ip_rotation_state "" 35.1.2.3)"                  "promote"
expect_eq "VM lost its IP mid-swap: attach a new one"  "$(ip_rotation_state 203.0.113.100 "")"            "attach"
expect_eq "no reservation and no VM IP: attach first"  "$(ip_rotation_state "" "")"                         "attach"
