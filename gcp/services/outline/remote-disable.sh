#!/usr/bin/env bash
# VM-side (root): stop Outline while OUTLINE_ENABLED=false (run by make infra). /opt/outline (keys, API secret,
# certificates) is kept, so turning Outline back on adopts the same keys. Idempotent; without Docker or shadowbox
# there is nothing to do.
set -euo pipefail

die() { echo "[outline] ERROR: $*" >&2; exit 1; }
log() { echo "[outline] $*" >&2; }

have_docker() { command -v docker >/dev/null; }

main() {
  if ! have_docker; then
    log "turned off: Docker not installed, nothing to stop"
    return 0
  fi
  docker info >/dev/null 2>&1 || die "Docker is installed but not running: cannot make sure shadowbox stays stopped"
  if docker inspect watchtower >/dev/null 2>&1; then
    log "removing watchtower (it holds the Docker socket and has nothing left to update)"
    docker rm -f watchtower >/dev/null
  fi
  if ! docker inspect shadowbox >/dev/null 2>&1; then
    log "turned off: no shadowbox container"
    return 0
  fi
  # The installer's restart=always would bring a stopped container back at the next Docker or VM restart.
  docker update --restart=no shadowbox >/dev/null
  if [[ "$(docker inspect -f '{{.State.Running}}' shadowbox)" == true ]]; then
    log "turned off: stopping shadowbox (keys kept in /opt/outline)"
    docker stop shadowbox >/dev/null
  else
    log "turned off: shadowbox already stopped"
  fi
}

[[ -n "${NETGURU_SOURCE_ONLY:-}" ]] || main
