#!/usr/bin/env bash
#
# reset.sh — return to the clean starting state (`make reset`, ./5-reset, and ./2-attack run
# it). It removes the gateway policy, the Cilium egress policy, the collector's log, and the
# finished goose Job. It keeps the goose fence, the model-key Secret, and the verified skill.
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
cd "$REPO_ROOT"

require_set COLLECTOR_CONTAINER
require_attacker_ips
require_set COLLECTOR_PORT
require_set AGENT_NS
require_set GOOSE_JOB_NAME

log() { printf '>> reset: %s\n' "$*"; }

# --- 1. Gateway back to OPEN ------------------------------------------------------
log "switching the gateway back to OPEN (removing deny-by-default authz)"
bash controls/agentgateway/apply-policy.sh --open

# --- 2. Remove the Cilium egress policy -------------------------------------------
# The goose fence is a separate policy and stays in place.
EGRESS_POLICY="controls/cilium/egress-policy.yaml"
log "removing the demo egress policy (${EGRESS_POLICY}) if applied"
kc delete -f "$EGRESS_POLICY" --ignore-not-found

# --- 3. Clear the collector by recreating its container ---------------------------
log "recreating the collector container for an empty log"
if [ "$(docker inspect -f '{{index .Config.Labels "app.kubernetes.io/part-of"}}' "$COLLECTOR_CONTAINER" 2>/dev/null)" = "agents-assist-attackers" ]; then
  docker rm -f "$COLLECTOR_CONTAINER" >/dev/null
fi
bash attacker/start-attacker.sh

# Wait until the new collector answers.
log "waiting for the collector to accept connections"
deadline=$(( $(date +%s) + 30 ))
until curl -fsS --connect-timeout 2 --max-time 3 \
        -o /dev/null "http://${COLLECTOR_IP}:${COLLECTOR_PORT}/" 2>/dev/null; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    printf 'FATAL reset: collector did not become reachable at %s:%s within 30s\n' \
      "$COLLECTOR_IP" "$COLLECTOR_PORT" >&2
    exit 1
  fi
  sleep 1   # poll interval inside the bounded deadline loop
done
log "collector is up with an empty log"

# --- 4. Delete the finished goose Job ---------------------------------------------
log "deleting any finished goose Job so the next run's log starts clean"
kc -n "$AGENT_NS" delete job "$GOOSE_JOB_NAME" --ignore-not-found --wait=true >/dev/null 2>&1 || true

log "done — clean PRE-ATTACK state (gateway OPEN, egress removed, collector empty)."
log "kept: baseline goose fence, model-key Secret, verified skill, .runtime/sigstore."
