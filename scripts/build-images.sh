#!/usr/bin/env bash
#
# build-images.sh — build the goose and MCP server images, pull agentgateway by digest, and
# load all five into the kind node. `make up` runs it, and `make images` runs it alone.
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
cd "$REPO_ROOT"

log() { printf '>> %s\n' "$*"; }
die() { printf 'FATAL %s\n' "$*" >&2; exit 1; }

for t in docker kind; do
  command -v "$t" >/dev/null 2>&1 || die "'$t' not found on PATH (run scripts/01-install-tools.sh)"
done
kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME" \
  || die "kind cluster '${CLUSTER_NAME}' does not exist — create it first (make up does)"

# Check that each manifest's image tag matches demo.env.
check_manifest() {  # check_manifest FILE IMAGE
  grep -qE "^[[:space:]]*image:[[:space:]]*${2//./\\.}([[:space:]]|$)" "$1" \
    || die "$1 does not reference image '$2' (demo.env) — keep them in sync"
}
check_manifest "$GOOSE_JOB_MANIFEST"                       "$GOOSE_IMAGE"
check_manifest "$MCP_MANIFESTS/10-mcp-fs.yaml"             "$MCP_FS_IMAGE"
check_manifest "$MCP_MANIFESTS/20-mcp-fetch.yaml"          "$MCP_FETCH_IMAGE"
check_manifest "$MCP_MANIFESTS/30-mcp-http-post.yaml"      "$MCP_HTTP_POST_IMAGE"
check_manifest controls/agentgateway/deploy.yaml           "$GATEWAY_IMAGE"

# --- Build the four local images ------------------------------------------------------
build() {  # build IMAGE CONTEXT_DIR
  log "building $1 from $2/"
  docker build -q -t "$1" "$2" >/dev/null || die "docker build failed for $1 (context $2)"
}
build "$GOOSE_IMAGE"         agent/goose-image
build "$MCP_FS_IMAGE"        agent/mcp-servers/fs-server
build "$MCP_FETCH_IMAGE"     agent/mcp-servers/fetch-server
build "$MCP_HTTP_POST_IMAGE" agent/mcp-servers/http-post-server

# --- agentgateway: pull by digest --------------------------------------------------------
GW_REPO="${GATEWAY_IMAGE%:*}"
gw_has_digest() {
  docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$GATEWAY_IMAGE" 2>/dev/null \
    | grep -qxF "${GW_REPO}@${GATEWAY_IMAGE_DIGEST}"
}
if gw_has_digest; then
  log "$GATEWAY_IMAGE already present at ${GATEWAY_IMAGE_DIGEST:0:19}…"
else
  log "pulling ${GW_REPO}@${GATEWAY_IMAGE_DIGEST} and tagging it $GATEWAY_IMAGE"
  docker pull -q "${GW_REPO}@${GATEWAY_IMAGE_DIGEST}" >/dev/null
  docker tag "${GW_REPO}@${GATEWAY_IMAGE_DIGEST}" "$GATEWAY_IMAGE"
  gw_has_digest || die "$GATEWAY_IMAGE does not resolve to the pinned digest after pull"
fi

# --- Load all five into the kind node --------------------------------------------------
IMAGES=("$GOOSE_IMAGE" "$MCP_FS_IMAGE" "$MCP_FETCH_IMAGE" "$MCP_HTTP_POST_IMAGE" "$GATEWAY_IMAGE")
for img in "${IMAGES[@]}"; do
  log "loading $img into ${KIND_NODE_CONTAINER}"
  kind load docker-image --name "$CLUSTER_NAME" "$img" >/dev/null
done

# Confirm each image on the node has the same ID as the local one.
fail=0
for img in "${IMAGES[@]}"; do
  local_id="$(docker image inspect -f '{{.Id}}' "$img")"
  node_id="$(docker exec "$KIND_NODE_CONTAINER" crictl inspecti -o go-template --template '{{.status.id}}' "$img" 2>/dev/null || true)"
  if [ "$node_id" = "$local_id" ]; then
    printf 'PASS  %s on the node (%s)\n' "$img" "${local_id:7:12}"
  else
    printf 'FAIL  %s not on the node, or a different build (local %s, node %s)\n' \
      "$img" "${local_id:7:12}" "${node_id:-none}"
    fail=1
  fi
done
[ "$fail" -eq 0 ] || die "one or more images did not load into ${KIND_NODE_CONTAINER}"
log "all images built and loaded; pods will never pull at run time"
