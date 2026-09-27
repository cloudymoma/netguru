# shellcheck shell=bash
# Drift (wrong IP/tag) must stop the run; missing hardening must be surfaced, not ignored.

vm() { cat "${FIXTURES}/$1"; }

expect_eq "live VM satisfies invariants" \
  "$(vm_invariant_problems "$(vm vm-live.json)" 34.146.224.39)" ""
expect_eq "IP mismatch is drift" \
  "$(vm_invariant_problems "$(vm vm-live.json)" 1.2.3.4)" \
  "external IP 34.146.224.39 != static 1.2.3.4"
expect_eq "missing tag is drift" \
  "$(NETWORK_TAG=other vm_invariant_problems "$(vm vm-live.json)" 34.146.224.39)" \
  "missing tag other"
expect_eq "live VM reports all four hardening gaps" \
  "$(vm_hardening_gaps "$(vm vm-live.json)")" \
  "service account attached, secure boot off, startup-script present, deletion protection off"
expect_eq "hardened VM has no gaps" \
  "$(vm_hardening_gaps "$(vm vm-hardened.json)")" ""

# The startup script must be backed up verbatim before removal; stop/start only when it buys something.
expect_eq "startup script extracted verbatim" \
  "$(vm_startup_script "$(vm vm-live.json)")" \
  $'#!/bin/bash\necho redacted'
expect_eq "no startup script on hardened VM" "$(vm_startup_script "$(vm vm-hardened.json)")" ""
expect_eq "live VM needs the offline (stop/start) hardening" "$(vm_offline_hardening_needed "$(vm vm-live.json)")" "yes"
expect_eq "hardened VM needs no stop/start" "$(vm_offline_hardening_needed "$(vm vm-hardened.json)")" "no"
