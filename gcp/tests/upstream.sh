#!/usr/bin/env bash
# Verify SagerNet's live GPG key and signed apt index, unpack the newest sing-box (stable) and sing-box-testing
# packages into a temporary directory without root or system changes, and run the unit test suite against each.
# Usage: gcp/tests/upstream.sh [sing-box|sing-box-testing ...]
set -euo pipefail

_UPSTREAM_SOURCE_ONLY=${NETGURU_SOURCE_ONLY:-}
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
. "${REPO_ROOT}/gcp/lib.sh"

# Import extract_pinned_gpg_key from remote-install.sh without running its main().
# shellcheck disable=SC2034
NETGURU_SOURCE_ONLY=1
# shellcheck source=../services/sing-box/remote-install.sh
. "${REPO_ROOT}/gcp/services/sing-box/remote-install.sh"

u_log() { echo "[upstream] $*" >&2; }
u_die() { echo "[upstream] ERROR: $*" >&2; exit 1; }

deb_arch() {
  if [[ -n "${UPSTREAM_ARCH:-}" ]]; then
    echo "${UPSTREAM_ARCH}"
    return
  fi
  case "$(uname -s)/$(uname -m)" in
    Linux/x86_64 | Linux/amd64) echo amd64 ;;
    Linux/aarch64 | Linux/arm64) echo arm64 ;;
    *) u_die "make test-upstream requires Linux x86_64 or arm64 (got $(uname -s)/$(uname -m))" ;;
  esac
}

verify_inrelease() {
  local keyring=$1 inrelease=$2 out_release=$3 gh rc=0
  gh=$(mktemp -d)
  chmod 700 "$gh"
  gpg --homedir "$gh" --batch --quiet --import "$keyring" 2>/dev/null ||
    { rm -rf "$gh"; u_die "gpg failed to import verified keyring"; }
  gpg --homedir "$gh" --batch --quiet --status-fd 2 --output "$out_release" --decrypt "$inrelease" \
    2>"${gh}/status" || rc=$?
  gpgconf --homedir "$gh" --kill all 2>/dev/null || true
  if ((rc != 0)) || [[ ! -s "$out_release" ]] ||
    ! LC_ALL=C awk -v fpr="${SINGBOX_GPG_FINGERPRINT}" \
      '$1 == "[GNUPG:]" && $2 == "VALIDSIG" && $NF == fpr { ok = 1 } END { exit !ok }' "${gh}/status"; then
    rm -rf "$gh"
    u_die "InRelease signature verification failed against pinned ${SINGBOX_GPG_FINGERPRINT}"
  fi
  rm -rf "$gh"
}

release_entry_digest() {
  local target=$1
  tr -d '\r' | awk -v target="$target" '
    /^SHA256:[[:space:]]*$/ { in_sha = 1; next }
    /^[^[:space:]]/         { in_sha = 0 }
    in_sha && NF == 3 && $3 == target { print $1, $2; exit }
  '
}

verify_file_digest() {
  local file=$1 want_sha=$2 want_size=$3 label=$4 got_size got_sha
  got_size=$(wc -c <"$file" | tr -d '[:space:]')
  [[ "$got_size" == "$want_size" ]] || u_die "${label} size ${got_size} != signed ${want_size}"
  got_sha=$(sha256sum "$file" | awk '{print $1}')
  [[ "$got_sha" == "$want_sha" ]] || u_die "${label} sha256 ${got_sha} != signed ${want_sha}"
}

newest_package_entry() {
  local want_pkg=$1 want_arch=$2
  tr -d '\r' | awk -v want_pkg="$want_pkg" -v want_arch="$want_arch" '
    BEGIN { RS = ""; FS = "\n" }
    {
      pkg = ""; arch = ""; ver = ""; file = ""; sha = ""; size = ""
      for (i = 1; i <= NF; i++) {
        line = $i
        if (line ~ /^Package:[[:space:]]*/)           { sub(/^Package:[[:space:]]*/, "", line); pkg = line }
        else if (line ~ /^Architecture:[[:space:]]*/) { sub(/^Architecture:[[:space:]]*/, "", line); arch = line }
        else if (line ~ /^Version:[[:space:]]*/)      { sub(/^Version:[[:space:]]*/, "", line); ver = line }
        else if (line ~ /^Filename:[[:space:]]*/)     { sub(/^Filename:[[:space:]]*/, "", line); file = line }
        else if (line ~ /^SHA256:[[:space:]]*/)       { sub(/^SHA256:[[:space:]]*/, "", line); sha = line }
        else if (line ~ /^Size:[[:space:]]*/)         { sub(/^Size:[[:space:]]*/, "", line); size = line }
      }
      if (pkg == want_pkg && arch == want_arch && ver != "" && file != "" && sha != "" && size != "") {
        printf "%s\t%s\t%s\t%s\n", ver, file, sha, size
      }
    }
  ' | LC_ALL=C sort -t $'\t' -k1,1V | tail -n1
}

extract_deb() {
  local deb=$1 dst=$2 data_tar
  mkdir -p "$dst"
  if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb -x "$deb" "$dst"
  elif command -v ar >/dev/null 2>&1; then
    data_tar=$(ar t "$deb" | grep -E '^data\.tar(\.[a-z0-9]+)?$' | head -n1)
    [[ -n "$data_tar" ]] || u_die "no data.tar member in ${deb}"
    ar p "$deb" "$data_tar" | tar -C "$dst" -xf -
  else
    u_die "need dpkg-deb or ar to unpack ${deb}"
  fi
}

upstream_main() {
  local pkgs=() arg
  if (($# == 0)); then
    pkgs=(sing-box sing-box-testing)
  else
    for arg in "$@"; do
      case "$arg" in
        sing-box | sing-box-testing) pkgs+=("$arg") ;;
        *) u_die "usage: gcp/tests/upstream.sh [sing-box|sing-box-testing ...] (got '${arg}')" ;;
      esac
    done
  fi

  require_gpg_fpr SINGBOX_GPG_FINGERPRINT "${SINGBOX_GPG_FINGERPRINT}"
  local gpg_url="${SAGERNET_GPG_URL:-https://sing-box.app/gpg.key}"
  local apt_url="${SAGERNET_APT_URL:-https://deb.sagernet.org}"
  local test_cmd="${UPSTREAM_TEST_CMD:-${REPO_ROOT}/gcp/tests/run.sh}"
  local arch
  arch=$(deb_arch)

  (
    local work
    work=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$work'" EXIT

    u_log "verifying live SagerNet signing key (${gpg_url})"
    curl -fsSL --retry 3 --max-time 30 "$gpg_url" -o "${work}/gpg.key"
    extract_pinned_gpg_key "${work}/gpg.key" "${SINGBOX_GPG_FINGERPRINT}" "${work}/sagernet.gpg"

    u_log "verifying signed apt index (${apt_url}/InRelease)"
    curl -fsSL --retry 3 --max-time 30 "${apt_url}/InRelease" -o "${work}/InRelease"
    verify_inrelease "${work}/sagernet.gpg" "${work}/InRelease" "${work}/Release"

    local pkg_sha="" pkg_size=""
    read -r pkg_sha pkg_size < <(release_entry_digest "Packages" <"${work}/Release") || true
    [[ -n "$pkg_sha" && "$pkg_size" =~ ^[0-9]+$ ]] || u_die "signed InRelease has no SHA256 entry for Packages"
    require_sha256 PACKAGES_SHA256 "$pkg_sha"

    curl -fsSL --compressed --retry 3 --max-time 60 "${apt_url}/Packages" -o "${work}/Packages"
    verify_file_digest "${work}/Packages" "$pkg_sha" "$pkg_size" "Packages"

    local pkg entry ver rel_path deb_sha deb_size deb dst
    for pkg in "${pkgs[@]}"; do
      entry=$(newest_package_entry "$pkg" "$arch" <"${work}/Packages")
      [[ -n "$entry" ]] || u_die "no ${pkg} (${arch}) entry found in signed Packages"
      IFS=$'\t' read -r ver rel_path deb_sha deb_size <<<"$entry"
      [[ "$rel_path" =~ ^[A-Za-z0-9._/+~-]+$ && "$rel_path" != /* && "$rel_path" != *..* ]] ||
        u_die "unsafe Filename '${rel_path}' for ${pkg}"
      require_sha256 DEB_SHA256 "$deb_sha"
      [[ "$deb_size" =~ ^[0-9]+$ ]] || u_die "invalid Size '${deb_size}' for ${pkg}"

      deb="${work}/${pkg}.deb"
      dst="${work}/root-${pkg}"
      u_log "fetching and verifying ${pkg} ${ver} (${arch})"
      curl -fsSL --retry 3 --max-time 120 "${apt_url}/${rel_path}" -o "$deb"
      verify_file_digest "$deb" "$deb_sha" "$deb_size" "${pkg} (${ver})"
      extract_deb "$deb" "$dst"
      [[ -x "${dst}/usr/bin/sing-box" ]] || u_die "unpacked ${pkg} has no executable usr/bin/sing-box"
      u_log "running tests with ${pkg} ${ver}: $("${dst}/usr/bin/sing-box" version | head -n1)"
      (
        export PATH="${dst}/usr/bin:${PATH}"
        "$test_cmd"
      )
      rm -rf "$deb" "$dst"
    done
  )
}

[[ -n "${_UPSTREAM_SOURCE_ONLY}" ]] || upstream_main "$@"
