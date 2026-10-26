#!/usr/bin/env bash
#
# smoke-test-falco.sh — prove the AGENT_CRED_READ rule fires. A throwaway pod with the
# mcp-fs role label reads a synthetic file at the decoy's path, and the script watches
# Falco's log for the alert.

set -uo pipefail   # not -e, so cleanup and the verdict always run

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

POD_READY_TIMEOUT="${POD_READY_TIMEOUT:-60s}"
ALERT_WAIT_SECONDS="${ALERT_WAIT_SECONDS:-10}"   # Falco usually alerts within 2 seconds

require_set SHELLTEST_IMAGE

POD_NAME="falco-smoke-test-$$"
log()  { printf '%s\n' "$*"; }
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; }

cleanup() { kc delete pod "$POD_NAME" -n "$DEMO_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Look only at Falco log lines written after this point.
SINCE_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log "Creating test pod '$POD_NAME' in ns/${DEMO_NS} with ${ROLE_LABEL_KEY}=${ROLE_FS}..."
# Delete the pod at once when done.
kc run "$POD_NAME" -n "$DEMO_NS" --image="$SHELLTEST_IMAGE" --overrides='{"apiVersion":"v1","spec":{"terminationGracePeriodSeconds":0}}' \
  --labels="${ROLE_LABEL_KEY}=${ROLE_FS}" --restart=Never --command -- sleep 3600 >/dev/null 2>&1

if ! kc wait --for=condition=Ready "pod/$POD_NAME" -n "$DEMO_NS" --timeout="$POD_READY_TIMEOUT" >/dev/null 2>&1; then
  fail "test pod not Ready within $POD_READY_TIMEOUT (image not pre-loaded? node not Ready?)"
  log  "Cannot trigger the rule without a Ready pod. NOT VERIFIED."
  exit 1
fi

# Write a synthetic file at the watched path, then read it; the rule matches the read.
log "Writing a synthetic decoy at ${DECOY_CRED_PATH} and reading it to trigger the rule..."
kc exec "$POD_NAME" -n "$DEMO_NS" -- sh -c \
  "mkdir -p \"\$(dirname '${DECOY_CRED_PATH}')\" && \
   printf '[default]\naws_access_key_id=AKIA-${FAKE_CRED_MARKER}\n' > '${DECOY_CRED_PATH}' && \
   cat '${DECOY_CRED_PATH}' >/dev/null" >/dev/null 2>&1

log "Watching Falco logs in ns/${FALCO_NS} for '${FALCO_CRED_MARKER}' from pod ${POD_NAME} (up to ${ALERT_WAIT_SECONDS}s)..."
FOUND=0
for _ in $(seq 1 "$ALERT_WAIT_SECONDS"); do
  if kc logs -n "$FALCO_NS" -l "$FALCO_SELECTOR" --since-time="$SINCE_TS" --tail=-1 2>/dev/null \
       | grep -F "$FALCO_CRED_MARKER" | grep -F "pod=${POD_NAME}" >/dev/null; then
    # Match this pod's alert only.
    FOUND=1
    break
  fi
  sleep 1   # polling the log for an event, NOT substituting for a readiness check
done

log "----------------------------------------"
if [ "$FOUND" -eq 1 ]; then
  pass "Falco fired '${FALCO_CRED_MARKER}' on the decoy credential read — detection works."
  exit 0
else
  fail "No '${FALCO_CRED_MARKER}' in Falco logs within ${ALERT_WAIT_SECONDS}s."
  log  "Likely causes, in order:"
  log  "  1. Rule not loaded — check 'kubectl logs -n ${FALCO_NS} -l ${FALCO_SELECTOR}' for parse errors."
  log  "  2. Workload scoping missed — pod labels not reaching Falco (container plugin / CRI, DEMO-GUIDE.md D12), or ${ROLE_LABEL_KEY} label mismatch."
  log  "  3. DECOY_CRED_PATH (demo.env) does not match agent_decoy_cred_paths in rules-agent.yaml."
  log  "  4. BTF missing — Falco on the kernel-module driver may not be detecting opens."
  log  "NOT VERIFIED — fix the cause above and re-run (DEMO-GUIDE.md ("How the controls work") covers the Falco traps)."
  exit 1
fi
