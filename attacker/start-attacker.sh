#!/usr/bin/env bash
#
# start-attacker.sh — run the vendor docs server and the collector as local containers on
# the kind network, each at a fixed IP. Neither publishes a port on your machine or makes
# outbound connections.

# shellcheck disable=SC2034
set -euo pipefail

# shellcheck source=../scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/lib/common.sh"

log() { printf '>> %s\n' "$*"; }
die() { printf 'FATAL %s\n' "$*" >&2; exit 1; }

[ "$#" -eq 0 ] || die "usage: $0   (takes no arguments)"

# This label marks containers this demo created, so it never replaces or deletes anyone else's.
OWNER_KEY=app.kubernetes.io/part-of
OWNER_VALUE=agents-assist-attackers

require_attacker_ips
require_set ATTACKER_VENDOR_DOCS_IMAGE
require_set ATTACKER_COLLECTOR_IMAGE

# --- Consistency checks, before changing anything --------------------------------
# The readiness check looks for the containers listed in DOCKER_CONTAINERS.
for name in "$VENDOR_DOCS_CONTAINER" "$COLLECTOR_CONTAINER"; do
  case " $DOCKER_CONTAINERS " in
    *" $name "*) ;;
    *) die "container '${name}' is not listed in DOCKER_CONTAINERS (${DOCKER_CONTAINERS}) in demo.env" ;;
  esac
done

# Check that the CoreDNS template has both names.
COREDNS_FILE="$REPO_ROOT/cluster/coredns-custom.yaml"
for pair in "${DOCS_HOST} __VENDOR_DOCS_IP__" "${COLLECTOR_HOST} __COLLECTOR_IP__"; do
  host="${pair% *}"; ip="${pair#* }"
  host_rx="$(printf '%s' "$host" | sed 's/\./\\./g')"
  grep -qF "answer \"${host}. 60 IN A ${ip}\"" "$COREDNS_FILE" \
    || die "cluster/coredns-custom.yaml lacks the A answer '${host} -> ${ip}' (placeholder) — it must match demo.env"
  grep -qF "match \"^${host_rx}\\.\$\"" "$COREDNS_FILE" \
    || die "cluster/coredns-custom.yaml lacks the A-record match regex for '${host}' (match \"^${host_rx}\\.\$\") — the answer line would never fire"
done

docker network inspect "$KIND_DOCKER_NETWORK" >/dev/null 2>&1 \
  || die "Docker network '${KIND_DOCKER_NETWORK}' not found — create the kind cluster first"

# The IPs must be inside the network's range.
SUBNET="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "$KIND_DOCKER_NETWORK" \
  | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/' | head -n1)"
[ -n "$SUBNET" ] || die "no IPv4 subnet on Docker network '${KIND_DOCKER_NETWORK}'"
python3 - "$SUBNET" "$VENDOR_DOCS_IP" "$COLLECTOR_IP" <<'PY' || die "attacker IPs ${VENDOR_DOCS_IP}/${COLLECTOR_IP} are not inside the kind network's range ${SUBNET} — unset any VENDOR_DOCS_IP/COLLECTOR_IP you exported and re-run"
import ipaddress, sys
net = ipaddress.ip_network(sys.argv[1])
sys.exit(0 if all(ipaddress.ip_address(a) in net for a in sys.argv[2:]) else 1)
PY

# --- Images -----------------------------------------------------------------------
log "building vendor-docs image ${ATTACKER_VENDOR_DOCS_IMAGE}"
docker build -q -t "$ATTACKER_VENDOR_DOCS_IMAGE" "$REPO_ROOT/attacker/vendor-docs" >/dev/null
log "building collector image ${ATTACKER_COLLECTOR_IMAGE}"
docker build -q -t "$ATTACKER_COLLECTOR_IMAGE" "$REPO_ROOT/attacker/collector" >/dev/null

# Print an image's local ID: resolve_image_id REF
resolve_image_id() {
  docker image inspect -f '{{.Id}}' "$1" 2>/dev/null || die "image '$1' is not local — the build above failed"
}

# Each container's settings: its image and image ID, extra `docker run` flags (*_EXTRA),
# and a command (*_CMD, empty to use the image's own).
VENDOR_IMAGE="$ATTACKER_VENDOR_DOCS_IMAGE"; VENDOR_ID="$(resolve_image_id "$VENDOR_IMAGE")"
# nginx needs exactly these four capabilities to start as root and drop to its worker user.
VENDOR_EXTRA=(--cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID --cap-add NET_BIND_SERVICE)
VENDOR_CMD=()

COLLECTOR_IMAGE="$ATTACKER_COLLECTOR_IMAGE"; COLLECTOR_ID="$(resolve_image_id "$COLLECTOR_IMAGE")"
# The collector runs as a non-root user and needs no capabilities at all.
COLLECTOR_EXTRA=(--cap-drop ALL)
COLLECTOR_CMD=()

# Start a container, or leave it alone if it is already up to date. Refuse one this demo
# did not create.
# Usage: ensure_container NAME IP ROLE IMAGE_REF EXPECTED_ID EXTRA_ARRAY_NAME CMD_ARRAY_NAME
ensure_container() {
  local name="$1" ip="$2" role="$3" image_ref="$4" expected_id="$5"
  local -n _extra="$6" _cmd="$7"   # nameref the per-container EXTRA/CMD arrays

  if docker inspect "$name" >/dev/null 2>&1; then
    local owner cur_id cur_ip running
    owner="$(docker inspect -f "{{index .Config.Labels \"${OWNER_KEY}\"}}" "$name")"
    [ "$owner" = "$OWNER_VALUE" ] \
      || die "a container named '${name}' exists but was not created by this demo (another project's?) — stop or remove it first"
    # Compare image IDs, not tags.
    cur_id="$(docker inspect -f '{{.Image}}' "$name")"
    cur_ip="$(docker inspect -f "{{with index .NetworkSettings.Networks \"${KIND_DOCKER_NETWORK}\"}}{{.IPAMConfig.IPv4Address}}{{end}}" "$name" 2>/dev/null || true)"
    running="$(docker inspect -f '{{.State.Running}}' "$name")"
    if [ "$cur_id" = "$expected_id" ] && [ "$cur_ip" = "$ip" ]; then
      if [ "$running" = "true" ]; then
        log "${name}: up to date (${ip})"
      else
        log "${name}: starting existing container"
        docker start "$name" >/dev/null
      fi
      return 0
    fi
    log "${name}: drifted (ip ${cur_ip:-none}, or image changed) — replacing our own container"
    docker rm -f "$name" >/dev/null
  fi

  log "${name}: starting at ${ip} on '${KIND_DOCKER_NETWORK}'"
  # --ip sets the fixed address; no port is published.
  docker run -d --name "$name" --hostname "$name" \
    --network "$KIND_DOCKER_NETWORK" --ip "$ip" \
    --restart unless-stopped \
    --security-opt no-new-privileges \
    --label "${OWNER_KEY}=${OWNER_VALUE}" --label "demo.attacker-role=${role}" \
    "${_extra[@]}" \
    "$image_ref" \
    ${_cmd[@]+"${_cmd[@]}"} \
    >/dev/null
}

# Wait until a URL answers 200, optionally with expected text: wait_url NAME URL [TEXT]
wait_url() {
  local name="$1" url="$2" expect="${3:-}" body
  if ! body="$(curl -fsS --noproxy "*" --retry 20 --retry-connrefused --retry-delay 1 --max-time 3 "$url" 2>&1)"; then
    docker logs --tail 20 "$name" >&2 || true
    die "${name} not answering at ${url}: ${body}"
  fi
  if [ -n "$expect" ] && ! printf '%s' "$body" | grep -qF "$expect"; then
    die "${name} at ${url} answered unexpected body (wanted substring '${expect}') — IP mapping wrong?"
  fi
  [ -n "$body" ] || die "${name} at ${url} returned an empty body"
  log "${name}: answering at ${url}"
}

ensure_container "$VENDOR_DOCS_CONTAINER" "$VENDOR_DOCS_IP" vendor-docs \
  "$VENDOR_IMAGE" "$VENDOR_ID" VENDOR_EXTRA VENDOR_CMD
ensure_container "$COLLECTOR_CONTAINER" "$COLLECTOR_IP" collector \
  "$COLLECTOR_IMAGE" "$COLLECTOR_ID" COLLECTOR_EXTRA COLLECTOR_CMD

# Both vendor docs files must answer.
wait_url "$VENDOR_DOCS_CONTAINER" "http://${VENDOR_DOCS_IP}:${DOCS_PORT}/llms.txt"
wait_url "$VENDOR_DOCS_CONTAINER" "http://${VENDOR_DOCS_IP}:${DOCS_PORT}/"
wait_url "$COLLECTOR_CONTAINER" "http://${COLLECTOR_IP}:${COLLECTOR_PORT}/" "collector up"
log "attacker hosts up: ${DOCS_HOST}=${VENDOR_DOCS_IP}  ${COLLECTOR_HOST}=${COLLECTOR_IP}"
