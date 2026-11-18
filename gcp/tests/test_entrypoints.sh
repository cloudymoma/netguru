# shellcheck shell=bash
# Entry points must reject bad input before touching GCP, and make must run infra before any service.

expect_fail "deploy requires a service argument"       gcp/deploy.sh
expect_fail "deploy rejects services not in SERVICES"  gcp/deploy.sh nope
expect_eq   "deploy explains an unknown service" \
  "$(gcp/deploy.sh nope 2>&1)" \
  "ERROR: unknown service 'nope' (known: outline sing-box)"
expect_eq   "deploy refuses a turned-off service and names its switch" \
  "$(gcp/deploy.sh outline 2>&1)" \
  "ERROR: service 'outline' is turned off: set OUTLINE_ENABLED=true in gcp/config.env"
# make outline / upgrade-outline on a turned-off service: the same refusal, at once, without running infra first.
# (--no-print-directory: under `make test` these are nested makes, which would print "Entering directory".)
expect_eq   "make outline (turned off) runs only the refusing deploy, never infra" \
  "$(make --no-print-directory -n outline)" "gcp/deploy.sh outline"
expect_eq   "make upgrade-outline (turned off) runs only the refusing deploy" \
  "$(make --no-print-directory -n upgrade-outline)" "gcp/deploy.sh outline"
expect_eq   "make outline (turned off) names the switch to set" \
  "$(make --no-print-directory outline 2>&1 | head -1)" \
  "ERROR: service 'outline' is turned off: set OUTLINE_ENABLED=true in gcp/config.env"
expect_fail "show rejects unknown SHOW_FORMAT"         env SHOW_FORMAT=yaml gcp/show.sh
expect_eq   "default make target is help (runs no GCP scripts)" \
  "$(make -n)" "$(make -n help)"
expect_ok   "make help lists core targets" \
  bash -c 'make help | grep -q "update-ip CONFIRM=1" && make help | grep -q "upgrade-sing-box"'
expect_eq   "make all runs infra, then the enabled services in order, then show" \
  "$(make -n all | grep -oE 'gcp/(infra|deploy|show)\.sh( [a-z-]+)?' | tr '\n' '|')" \
  "gcp/infra.sh|gcp/deploy.sh sing-box|gcp/show.sh|"
expect_eq   "make upgrade upgrades each enabled service in order, without touching infra" \
  "$(make -n upgrade | grep -oE '(UPGRADE=yes )?gcp/(infra|deploy)\.sh( [a-z-]+)?' | tr '\n' '|')" \
  "UPGRADE=yes gcp/deploy.sh sing-box|"
expect_fail "deploy rejects UPGRADE other than yes/no" env UPGRADE=maybe gcp/deploy.sh sing-box

# PATH with only bash and dirname: no sing-box and no gcloud, wherever they are installed, so verify never reaches GCP.
NOSB_BIN=$(mktemp -d)
ln -s "$(command -v bash)" "$(command -v dirname)" "$NOSB_BIN/"
expect_fail "verify refuses to run without a local sing-box" env PATH="$NOSB_BIN" gcp/verify.sh
expect_eq   "verify says how to get sing-box" \
  "$(env PATH="$NOSB_BIN" gcp/verify.sh 2>&1 | tail -1)" \
  "ERROR: local sing-box not found on PATH (plan Task 6 Step 1)"
rm -rf "$NOSB_BIN"

# make show writes the profile only when every service answered: one failed SSH must not leave a profile missing
# servers. Two services (Outline switched on in a copy), and only sing-box's JSON call fails.
SHOW_TMP=$(mktemp -d)
cp -r Makefile gcp "$SHOW_TMP/"
sed -i 's/^OUTLINE_ENABLED=.*/OUTLINE_ENABLED="true"/' "$SHOW_TMP/gcp/config.env"
mkdir "$SHOW_TMP/bin"
cat >"$SHOW_TMP/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
if [[ " $* " == *" addresses describe "* ]]; then echo 203.0.113.100; exit 0; fi
script=$(cat) # the VM-side script arrives on stdin
if [[ " $* " != *"SHOW_FORMAT=json"* ]]; then echo "(text)"; exit 0; fi
if [[ "$script" == *"print sing-box client configs"* ]]; then exit 255; fi
echo '[{"type":"shadowsocks","tag":"outline-0","server":"203.0.113.100","server_port":45362,"method":"chacha20-ietf-poly1305","password":"x"}]'
STUB
chmod +x "$SHOW_TMP/bin/gcloud"
printf 'previous\n' >"$SHOW_TMP/netguru-client.json"
printf 'previous-full\n' >"$SHOW_TMP/netguru-client-full.json"
expect_fail "make show fails when one service's SSH fails" env PATH="$SHOW_TMP/bin:$PATH" "$SHOW_TMP/gcp/show.sh"
expect_eq   "a failed make show leaves the previous profile untouched" "$(cat "$SHOW_TMP/netguru-client.json")" "previous"
expect_eq   "a failed make show leaves the fallback profile untouched" "$(cat "$SHOW_TMP/netguru-client-full.json")" "previous-full"
sed -i 's/^SINGBOX_ENABLED=.*/SINGBOX_ENABLED="false"/' "$SHOW_TMP/gcp/config.env"
expect_ok   "make show succeeds when all enabled services answer" env PATH="$SHOW_TMP/bin:$PATH" "$SHOW_TMP/gcp/show.sh"
expect_ok   "make show writes a valid primary bypass-CN profile (0600)" \
  bash -c "[[ \$(stat -c %a '$SHOW_TMP/netguru-client.json') == 600 ]] && sing-box check -c '$SHOW_TMP/netguru-client.json' && jq -e '.route.rule_set | length == 2' '$SHOW_TMP/netguru-client.json'"
expect_ok   "make show also writes a valid full-tunnel fallback profile (0600)" \
  bash -c "[[ \$(stat -c %a '$SHOW_TMP/netguru-client-full.json') == 600 ]] && sing-box check -c '$SHOW_TMP/netguru-client-full.json' && jq -e '(.route | has(\"rule_set\")) | not' '$SHOW_TMP/netguru-client-full.json'"
cat >"$SHOW_TMP/bin/getent" <<'STUB'
#!/usr/bin/env bash
case "${FAKE_DNS:-match}" in
  match) printf '203.0.113.100   STREAM %s\n203.0.113.100   DGRAM\n' "$2" ;;
  stale) printf '198.51.100.9    STREAM %s\n203.0.113.100   STREAM\n' "$2" ;;
  none)  exit 2 ;;
  die)   echo "UNEXPECTED getent call" >&2; exit 99 ;;
esac
STUB
chmod +x "$SHOW_TMP/bin/getent"
sed -i 's/^CLIENT_SERVER_HOST=.*/CLIENT_SERVER_HOST="proxy.example.com"/' "$SHOW_TMP/gcp/config.env"
grep -q '^CLIENT_SERVER_HOST=' "$SHOW_TMP/gcp/config.env" || echo 'CLIENT_SERVER_HOST="proxy.example.com"' >>"$SHOW_TMP/gcp/config.env"
expect_eq   "show with matching CLIENT_SERVER_HOST emits no DNS warning" \
  "$(env FAKE_DNS=match PATH="$SHOW_TMP/bin:$PATH" "$SHOW_TMP/gcp/show.sh" 2>&1 >/dev/null)" ""
expect_eq   "show writes CLIENT_SERVER_HOST into both generated profiles" \
  "$(jq -r '.outbounds[1].server' "$SHOW_TMP/netguru-client.json"),$(jq -r '.outbounds[1].server' "$SHOW_TMP/netguru-client-full.json")" \
  "proxy.example.com,proxy.example.com"
# shellcheck disable=SC2016
expect_ok   "show warns (without failing) when CLIENT_SERVER_HOST also returns a stale A record" \
  bash -c 'out=$(env FAKE_DNS=stale PATH="$1/bin:$PATH" "$1/gcp/show.sh" 2>&1 >/dev/null) && [[ "$out" == *"WARN"* && "$out" == *"203.0.113.100"* ]]' _ "$SHOW_TMP"
# shellcheck disable=SC2016
expect_ok   "show warns (without failing) when CLIENT_SERVER_HOST does not resolve" \
  bash -c 'out=$(env FAKE_DNS=none PATH="$1/bin:$PATH" "$1/gcp/show.sh" 2>&1 >/dev/null) && [[ "$out" == *"WARN"* && "$out" == *"proxy.example.com"* ]]' _ "$SHOW_TMP"
expect_eq   "SHOW_FORMAT=json skips the CLIENT_SERVER_HOST DNS check" \
  "$(env SHOW_FORMAT=json FAKE_DNS=die PATH="$SHOW_TMP/bin:$PATH" "$SHOW_TMP/gcp/show.sh" 2>&1 >/dev/null)" ""
# Without getent the lookup falls back to dig (macOS has no getent); with neither, show says it cannot check instead
# of claiming that the name does not resolve.
RES_BIN=$(mktemp -d)
ln -s "$(command -v grep)" "$(command -v sort)" "$RES_BIN/"
printf '#!/bin/sh\nprintf "alias.example.net.\\n203.0.113.100\\n198.51.100.9\\n"\n' >"$RES_BIN/dig"
chmod +x "$RES_BIN/dig"
expect_eq   "resolve_ipv4 falls back to dig and keeps only the addresses" \
  "$(PATH="$RES_BIN" resolve_ipv4 proxy.example.com | tr '\n' ' ')" "198.51.100.9 203.0.113.100 "
expect_eq   "resolve_ipv4 cannot tell without getent or dig" \
  "$(PATH=/nonexistent resolve_ipv4 proxy.example.com; echo "rc=$?")" "rc=2"
rm -rf "$RES_BIN"
NODNS_BIN=$(mktemp -d) # only what show.sh itself runs: no getent, no dig
for tool in bash dirname tr cat jq mktemp mv rm; do ln -s "$(command -v "$tool")" "$NODNS_BIN/"; done
cp "$SHOW_TMP/bin/gcloud" "$NODNS_BIN/"
# shellcheck disable=SC2016
expect_ok   "show says it cannot check CLIENT_SERVER_HOST when neither getent nor dig exists" \
  bash -c 'out=$(env PATH="$2" "$1/gcp/show.sh" 2>&1 >/dev/null) && [[ "$out" == NOTE:*"proxy.example.com"* && "$out" != *WARN* ]]' _ "$SHOW_TMP" "$NODNS_BIN"
rm -rf "$NODNS_BIN"
# shellcheck disable=SC2016
expect_ok   "update-ip with CLIENT_SERVER_HOST notes profiles need no re-import while share links change" \
  bash -c 'out=$(env -u CONFIRM "$1/gcp/update-ip.sh" 2>&1); [[ "$out" == *"no re-import"* && "$out" == *"proxy.example.com"* && "$out" == *"vless://"* ]]' _ "$SHOW_TMP"
sed -i 's/^CLIENT_SERVER_HOST=.*/CLIENT_SERVER_HOST="1.2.3.4"/' "$SHOW_TMP/gcp/config.env"
expect_fail "show rejects non-hostname CLIENT_SERVER_HOST before touching GCP" env PATH="$SHOW_TMP/bin:$PATH" "$SHOW_TMP/gcp/show.sh"
sed -i 's/^CLIENT_SERVER_HOST=.*/CLIENT_SERVER_HOST=""/; s/^CLIENT_AUTO_FAILOVER=.*/CLIENT_AUTO_FAILOVER="yes"/' "$SHOW_TMP/gcp/config.env"
expect_fail "show rejects non-bool CLIENT_AUTO_FAILOVER before touching GCP" env PATH="$SHOW_TMP/bin:$PATH" "$SHOW_TMP/gcp/show.sh"
sed -i 's/^CLIENT_AUTO_FAILOVER=.*/CLIENT_AUTO_FAILOVER="false"/; s/^SINGBOX_ENABLED=.*/SINGBOX_ENABLED="true"/' "$SHOW_TMP/gcp/config.env"
# The Makefile takes SERVICES from lib.sh: switching Outline on adds its deploy step, first.
expect_eq   "with Outline switched on, make all deploys it first" \
  "$(make -s -C "$SHOW_TMP" -n all | grep -oE 'gcp/(infra|deploy|show)\.sh( [a-z-]+)?' | tr '\n' '|')" \
  "gcp/infra.sh|gcp/deploy.sh outline|gcp/deploy.sh sing-box|gcp/show.sh|"
rm -rf "$SHOW_TMP"

expect_fail "update-ip refuses without CONFIRM=1" env -u CONFIRM gcp/update-ip.sh
expect_eq   "update-ip warns that client configs change" \
  "$(env -u CONFIRM gcp/update-ip.sh 2>&1 | head -1)" \
  "make update-ip gives ${VM_NAME} a NEW public IP: every Outline key, vless:// and hysteria2:// config changes."

# A stopped VM gets no ephemeral IP, so a swap would strand it without one: refuse before any gcloud mutation.
UIP_BIN=$(mktemp -d)
cat >"${UIP_BIN}/gcloud" <<STUB
#!/usr/bin/env bash
if [[ " \$* " == *" instances describe "* ]]; then jq '.status = "TERMINATED"' "${PWD}/${FIXTURES}/vm-netguru.json"; exit 0; fi
if [[ " \$* " == *" addresses describe "* ]]; then echo 203.0.113.100; exit 0; fi
echo "\$*" >>"${UIP_BIN}/mutations"
STUB
chmod +x "${UIP_BIN}/gcloud"
expect_fail "update-ip refuses a stopped VM" env CONFIRM=1 PATH="${UIP_BIN}:${PATH}" gcp/update-ip.sh
expect_eq   "update-ip changes nothing on a stopped VM" "$(cat "${UIP_BIN}/mutations" 2>/dev/null)" ""
rm -rf "$UIP_BIN"

# make test-upstream / gcp/tests/upstream.sh: verifies live GPG key -> InRelease -> Packages -> .deb SHA256/size
# and runs the test suite against unpacked stable + testing binaries without root or system changes.
expect_ok   "make help lists test-upstream" \
  bash -c 'make help | grep -q "test-upstream"'
# shellcheck disable=SC2016
expect_ok   "make test-upstream runs shellcheck and gcp/tests/upstream.sh" \
  bash -c 'out=$(make -n test-upstream) && grep -qF "shellcheck" <<<"$out" && grep -qF "gcp/tests/upstream.sh" <<<"$out"'
expect_fail "upstream runner rejects defunct sing-box-beta"  gcp/tests/upstream.sh sing-box-beta
expect_fail "upstream runner rejects unknown flags"          gcp/tests/upstream.sh --unknown

UP_TMP=$(mktemp -d)
UP_GH="${UP_TMP}/gnupg"
mkdir -m 700 "$UP_GH"
gpg --homedir "$UP_GH" --batch --passphrase "" --pinentry-mode loopback --quiet \
  --quick-generate-key "upstream-test@example.com" ed25519 sign never 2>/dev/null
UP_FPR=$(gpg --homedir "$UP_GH" --batch --with-colons --list-keys 2>/dev/null |
  awk -F: '$1 == "pub" { want = 1; next } want && $1 == "fpr" { print $10; exit }')
gpg --homedir "$UP_GH" --batch --armor --export "$UP_FPR" >"${UP_TMP}/gpg.key" 2>/dev/null

mkdir -p "${UP_TMP}/repo/files"
make_fake_deb() {
  local ver=$1 out=$2 d
  d=$(mktemp -d "${UP_TMP}/deb.XXXXXX")
  mkdir -p "${d}/root/usr/bin" "${d}/ctrl"
  printf '#!/usr/bin/env bash\necho "sing-box version %s"\n' "$ver" >"${d}/root/usr/bin/sing-box"
  chmod 755 "${d}/root/usr/bin/sing-box"
  printf 'Package: sing-box\nVersion: %s\nArchitecture: amd64\n' "$ver" >"${d}/ctrl/control"
  printf '2.0\n' >"${d}/debian-binary"
  tar -C "${d}/ctrl" -czf "${d}/control.tar.gz" .
  tar -C "${d}/root" -czf "${d}/data.tar.gz" .
  (cd "$d" && ar rcs "$out" debian-binary control.tar.gz data.tar.gz >/dev/null 2>&1)
  rm -rf "$d"
}
make_fake_deb "1.14.99"          "${UP_TMP}/repo/files/sb.deb"
make_fake_deb "1.15.0-alpha.99"  "${UP_TMP}/repo/files/sbt.deb"
SB_DEB_SHA=$(sha256sum "${UP_TMP}/repo/files/sb.deb" | awk '{print $1}')
SB_DEB_SZ=$(wc -c <"${UP_TMP}/repo/files/sb.deb" | tr -d '[:space:]')
SBT_DEB_SHA=$(sha256sum "${UP_TMP}/repo/files/sbt.deb" | awk '{print $1}')
SBT_DEB_SZ=$(wc -c <"${UP_TMP}/repo/files/sbt.deb" | tr -d '[:space:]')

# Include older versions (pointing to missing files) to prove Debian tilde/version sorting picks the newest stanza.
cat >"${UP_TMP}/repo/Packages" <<EOF
Package: sing-box
Architecture: amd64
Version: 1.14.2
Filename: files/missing-old.deb
Size: 1
SHA256: $(printf 'a%.0s' {1..64})

Package: sing-box
Architecture: amd64
Version: 1.14.99
Filename: files/sb.deb
Size: ${SB_DEB_SZ}
SHA256: ${SB_DEB_SHA}

Package: sing-box-testing
Architecture: amd64
Version: 1.15.0~alpha.9
Filename: files/missing-alpha9.deb
Size: 1
SHA256: $(printf 'b%.0s' {1..64})

Package: sing-box-testing
Architecture: amd64
Version: 1.15.0~alpha.99
Filename: files/sbt.deb
Size: ${SBT_DEB_SZ}
SHA256: ${SBT_DEB_SHA}
EOF
PKG_SHA=$(sha256sum "${UP_TMP}/repo/Packages" | awk '{print $1}')
PKG_SZ=$(wc -c <"${UP_TMP}/repo/Packages" | tr -d '[:space:]')
printf 'Origin: test\nSHA256:\n %s %s Packages\n' "$PKG_SHA" "$PKG_SZ" >"${UP_TMP}/Release"
gpg --homedir "$UP_GH" --batch --quiet --output "${UP_TMP}/repo/InRelease" --clearsign "${UP_TMP}/Release" 2>/dev/null
gpgconf --homedir "$UP_GH" --kill all 2>/dev/null || true

cat >"${UP_TMP}/record.sh" <<'EOF'
#!/usr/bin/env bash
sing-box version >>"${UP_LOG}"
EOF
chmod +x "${UP_TMP}/record.sh"

# shellcheck disable=SC2034,SC2329 # globals read by sourced upstream_main
up_run() {
  local fpr=$1 repo_dir=$2; shift 2
  (
    NETGURU_SOURCE_ONLY=1
    # shellcheck disable=SC1091
    . gcp/tests/upstream.sh
    SINGBOX_GPG_FINGERPRINT=$fpr
    SAGERNET_GPG_URL="file://${UP_TMP}/gpg.key"
    SAGERNET_APT_URL="file://${repo_dir}"
    UPSTREAM_ARCH="amd64"
    UPSTREAM_TEST_CMD="${UP_TMP}/record.sh"
    export UP_LOG="${UP_TMP}/ran"
    upstream_main "$@"
  )
}
: >"${UP_TMP}/ran"
expect_ok   "upstream runner verifies signed repo and runs both newest stable and testing binaries" \
  up_run "$UP_FPR" "${UP_TMP}/repo"
expect_eq   "upstream runner prepends unpacked stable then testing sing-box to PATH" \
  "$(tr '\n' '|' <"${UP_TMP}/ran")" "sing-box version 1.14.99|sing-box version 1.15.0-alpha.99|"
# Without dpkg-deb (Linux distributions that are not Debian-based) the runner unpacks with ar and tar.
AR_BIN=$(mktemp -d)
for tool in ar tar gzip grep head mkdir rm; do ln -s "$(command -v "$tool")" "$AR_BIN/"; done
# shellcheck disable=SC2016
expect_ok   "upstream runner unpacks a package with ar and tar when dpkg-deb is missing" \
  bash -c 'NETGURU_SOURCE_ONLY=1; . gcp/tests/upstream.sh; PATH=$1; extract_deb "$2/repo/files/sb.deb" "$2/unpacked"; [[ -x "$2/unpacked/usr/bin/sing-box" ]]' _ "$AR_BIN" "$UP_TMP"
rm -rf "$AR_BIN"

: >"${UP_TMP}/ran"
expect_fail "upstream runner rejects wrong pinned GPG fingerprint" \
  up_run "$(printf '0%.0s' {1..40})" "${UP_TMP}/repo"
expect_eq   "wrong GPG fingerprint never invokes test command" "$(cat "${UP_TMP}/ran")" ""

cp -r "${UP_TMP}/repo" "${UP_TMP}/repo-unsigned"
cp "${UP_TMP}/Release" "${UP_TMP}/repo-unsigned/InRelease"
expect_fail "upstream runner rejects unsigned InRelease" \
  up_run "$UP_FPR" "${UP_TMP}/repo-unsigned"

cp -r "${UP_TMP}/repo" "${UP_TMP}/repo-bad-inrel"
sed -i 's/Origin: test/Origin: evil/' "${UP_TMP}/repo-bad-inrel/InRelease"
expect_fail "upstream runner rejects tampered InRelease" \
  up_run "$UP_FPR" "${UP_TMP}/repo-bad-inrel"

cp -r "${UP_TMP}/repo" "${UP_TMP}/repo-bad-deb"
printf 'x' >>"${UP_TMP}/repo-bad-deb/files/sb.deb"
expect_fail "upstream runner rejects tampered .deb archive" \
  up_run "$UP_FPR" "${UP_TMP}/repo-bad-deb" sing-box
rm -rf "$UP_TMP"
