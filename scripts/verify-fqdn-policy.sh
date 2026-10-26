#!/usr/bin/env bash
#
# verify-fqdn-policy.sh — prove the Cilium egress policy works for each tool role. Run it
# after `make defend`.
#
#   fetch       DNS works, the vendor docs host is reachable, and the collector and the
#               internet are blocked.
#   http-post   DNS works, and the collector and the internet are blocked.
#
# To test one role: ROLES=fetch bash scripts/verify-fqdn-policy.sh

set -uo pipefail   # not -e, so every probe runs and every failure is reported

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

ROLES="${ROLES:-${ROLE_FETCH} ${ROLE_HTTP_POST}}"
# A name that always exists, to prove DNS works.
DNS_PROBE_NAME="${DNS_PROBE_NAME:-kubernetes.default.svc.cluster.local}"
POD_READY_TIMEOUT="${POD_READY_TIMEOUT:-60s}"
# Short, so a blocked connection fails fast.
PROBE_TIMEOUT="${PROBE_TIMEOUT:-5}"
# A public address that no tool role may reach.
INTERNET_PROBE_IP="${INTERNET_PROBE_IP:-1.1.1.1}"
INTERNET_PROBE_PORT="${INTERNET_PROBE_PORT:-443}"

# The test image must be pinned by digest and already on the node.
require_set NETTEST_IMAGE

FAILED=0
CURRENT_POD=""
log()  { printf '%s\n' "$*"; }
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILED=1; }

cleanup() {
  # Always remove the test pod, even on error.
  [ -n "$CURRENT_POD" ] && kc delete pod "$CURRENT_POD" -n "$DEMO_NS" --ignore-not-found --wait=false >/dev/null 2>&1
  return 0
}
trap cleanup EXIT

in_pod() { kc exec "$CURRENT_POD" -n "$DEMO_NS" -- "$@"; }
can_connect() { in_pod timeout "$PROBE_TIMEOUT" nc -z -w "$PROBE_TIMEOUT" "$1" "$2" >/dev/null 2>&1; }

start_pod() {
  local role="$1"
  CURRENT_POD="fqdn-test-${role}-$$"
  log "Creating test pod '$CURRENT_POD' in ns/${DEMO_NS} with ${ROLE_LABEL_KEY}=${role}..."
  # Delete the pod at once when done.
  kc run "$CURRENT_POD" -n "$DEMO_NS" --image="$NETTEST_IMAGE" --overrides='{"apiVersion":"v1","spec":{"terminationGracePeriodSeconds":0}}' \
    --labels="${ROLE_LABEL_KEY}=${role}" --restart=Never --command -- sleep 3600 >/dev/null
  # Wait until the pod is ready.
  if ! kc wait --for=condition=Ready "pod/$CURRENT_POD" -n "$DEMO_NS" --timeout="$POD_READY_TIMEOUT" >/dev/null 2>&1; then
    fail "test pod for role '${role}' not Ready within ${POD_READY_TIMEOUT} (image not pre-loaded?)"
    return 1
  fi
}

stop_pod() { cleanup; CURRENT_POD=""; }

check_role() {
  local role="$1"
  log "---------------- role: ${role} ----------------"
  start_pod "$role" || return

  if in_pod getent hosts "$DNS_PROBE_NAME" >/dev/null 2>&1; then
    pass "[${role}] DNS resolves ($DNS_PROBE_NAME)"
  else
    fail "[${role}] DNS does NOT resolve — DNS allow rule to kube-dns missing or merged (DEMO-GUIDE.md A2: DNS allow rule; separate entries)"
  fi

  if [ "$role" = "$ROLE_FETCH" ]; then
    if can_connect "$DOCS_HOST" "$DOCS_PORT"; then
      pass "[${role}] docs host reachable (${DOCS_HOST}:${DOCS_PORT}) — legitimate path allowed"
    else
      fail "[${role}] docs host NOT reachable — toFQDNs allow missing/merged, or name not in rules.dns (DEMO-GUIDE.md A2: separate entries; rules.dns)"
    fi
  fi

  # The collector's name must resolve first.
  if ! in_pod getent hosts "$COLLECTOR_HOST" >/dev/null 2>&1; then
    fail "[${role}] collector name does NOT resolve, so 'blocked' would be meaningless — either the CoreDNS entry is missing, or the policy's rules.dns lacks the resolve-only collector entry (DEMO-GUIDE.md ("How the controls work"))"
  # The collector is not on the allowlist, so a failed connection passes.
  elif can_connect "$COLLECTOR_HOST" "$COLLECTOR_PORT"; then
    fail "[${role}] collector REACHABLE (${COLLECTOR_HOST}:${COLLECTOR_PORT}) — a stray allow rule permits it"
  else
    pass "[${role}] collector blocked (${COLLECTOR_HOST}:${COLLECTOR_PORT})"
  fi

  # The internet must be blocked for every role.
  if can_connect "$INTERNET_PROBE_IP" "$INTERNET_PROBE_PORT"; then
    fail "[${role}] PUBLIC INTERNET reachable (${INTERNET_PROBE_IP}:${INTERNET_PROBE_PORT}) — egress allowlist too broad; a tool pod could exfiltrate off the machine"
  else
    pass "[${role}] public internet blocked (${INTERNET_PROBE_IP}:${INTERNET_PROBE_PORT})"
  fi
  stop_pod
}

for r in $ROLES; do check_role "$r"; done

log "----------------------------------------"
if [ "$FAILED" -eq 0 ]; then
  log "ALL CHECKS PASSED — FQDN egress policy is working."
  exit 0
else
  log "ONE OR MORE CHECKS FAILED — fix the FAIL lines and re-run (DEMO-GUIDE.md ("How the controls work") covers the Cilium traps)."
  exit 1
fi
