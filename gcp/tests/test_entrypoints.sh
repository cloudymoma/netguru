# shellcheck shell=bash
# Entry points must reject bad input before touching GCP, and make must run infra before any service.

expect_fail "deploy requires a service argument"       gcp/deploy.sh
expect_fail "deploy rejects services not in SERVICES"  gcp/deploy.sh nope
expect_eq   "deploy explains the rejection" \
  "$(gcp/deploy.sh nope 2>&1)" \
  "ERROR: service 'nope' is not in SERVICES (outline sing-box)"
expect_fail "show rejects unknown SHOW_FORMAT"         env SHOW_FORMAT=yaml gcp/show.sh
expect_eq   "make all runs infra, then services in order, then show" \
  "$(make -n all | grep -oE 'gcp/(infra|deploy|show)\.sh( [a-z-]+)?' | tr '\n' '|')" \
  "gcp/infra.sh|gcp/deploy.sh outline|gcp/deploy.sh sing-box|gcp/show.sh|"
expect_eq   "make upgrade upgrades each service in order, without touching infra" \
  "$(make -n upgrade | grep -oE '(UPGRADE=yes )?gcp/(infra|deploy)\.sh( [a-z-]+)?' | tr '\n' '|')" \
  "UPGRADE=yes gcp/deploy.sh outline|UPGRADE=yes gcp/deploy.sh sing-box|"
expect_fail "deploy rejects UPGRADE other than yes/no" env UPGRADE=maybe gcp/deploy.sh outline

expect_fail "verify refuses to run without a local sing-box" env PATH=/usr/bin:/bin gcp/verify.sh
expect_eq   "verify says how to get sing-box" \
  "$(env PATH=/usr/bin:/bin gcp/verify.sh 2>&1 | tail -1)" \
  "ERROR: local sing-box not found on PATH (plan Task 6 Step 1)"

expect_fail "harden refuses without CONFIRM=1" env -u CONFIRM gcp/harden.sh
expect_eq   "harden tells the user how to proceed" \
  "$(env -u CONFIRM gcp/harden.sh 2>&1 | tail -1)" \
  "Re-run with CONFIRM=1 to proceed."
