#!/usr/bin/env bash
#
# verify-goose-sandbox.sh — prove the goose fence, from a throwaway pod that Cilium treats
# like goose.
#
#   Allowed  DNS, the gateway, and the model API (skipped with ASSUME_OFFLINE=1).
#   Blocked  the Kubernetes API, the kubelet, the Docker host's resolver, the collector, the
#            vendor docs, a pod on the gateway's port without the gateway label, CoreDNS on
#            a non-DNS port, and the model host on port 80.
#
# Each blocked target is first reached from an unrestricted pod. Use CHECK_AGENT=0 before
# the gateway exists.

set -uo pipefail   # not -e, so every probe runs and every failure is reported

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_set NETTEST_IMAGE
ASSUME_OFFLINE="${ASSUME_OFFLINE:-0}"
CONTROL_POD="${DNS_PROBE_POD:-dns-probe}"
POD_READY_TIMEOUT="${POD_READY_TIMEOUT:-60s}"
# Short, so a blocked connection fails fast.
PROBE_TIMEOUT="${PROBE_TIMEOUT:-3}"
# Check the rendered copy, not the template.
POLICY_FILE="$REPO_ROOT/$RENDERED_DIR/goose-baseline-egress.yaml"
[ -f "$POLICY_FILE" ] || POLICY_FILE="$REPO_ROOT/$GOOSE_BASELINE_POLICY"

PROBE_POD="goose-sandbox-probe-$$"
LISTENER_POD="sandbox-listener-$$"
FAILED=0
log()   { printf '%s\n' "$*"; }
pass()  { printf 'PASS     %s\n' "$*"; }
fail()  { printf 'FAIL     %s\n' "$*"; FAILED=1; }
skip()  { printf 'SKIP     %s\n' "$*"; }
vacuous() { printf 'VACUOUS  %s\n' "$*"; FAILED=1; }

# shellcheck disable=SC2329  # invoked via trap
cleanup() {
  kc -n "$AGENT_NS" delete pod "$PROBE_POD" --ignore-not-found --wait=false >/dev/null 2>&1
  kc -n "$DEMO_NS" delete pod "$LISTENER_POD" --ignore-not-found --wait=false >/dev/null 2>&1
  return 0
}
trap cleanup EXIT

in_probe()   { kc -n "$AGENT_NS" exec "$PROBE_POD" -- "$@"; }
# shellcheck disable=SC2329  # invoked indirectly as tcp_ok's first argument
in_control() { kc -n "$DEMO_NS" exec "$CONTROL_POD" -- "$@"; }
# Test a TCP connection: tcp_ok in_probe|in_control HOST PORT
tcp_ok() { "$1" timeout "$((PROBE_TIMEOUT + 1))" nc -z -w "$PROBE_TIMEOUT" "$2" "$3" >/dev/null 2>&1; }
# Test DNS to one server. dig exits 0 on any reply and 9 on no reply.
dns_ok() { "$1" dig +time="$PROBE_TIMEOUT" +tries=1 @"$2" localhost >/dev/null 2>&1; }

log "=== goose sandbox fence check (${GOOSE_BASELINE_POLICY}) ==="

# --- Preconditions ----------------------------------------------------------------
if kc get -f "$POLICY_FILE" >/dev/null 2>&1; then
  pass "baseline policy applied ($(kc get -f "$POLICY_FILE" -o name | tr '\n' ' '))"
else
  fail "baseline policy from ${GOOSE_BASELINE_POLICY} NOT applied — kubectl apply -f it (make up does)"
fi
if ! kc -n "$DEMO_NS" wait --for=condition=Ready "pod/${CONTROL_POD}" --timeout="$POD_READY_TIMEOUT" >/dev/null 2>&1; then
  fail "control pod ${DEMO_NS}/${CONTROL_POD} not Ready — without it no blocked check can be proven"
  exit 1
fi

# A listener on the gateway's port, without the gateway label.
kc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${LISTENER_POD}
  namespace: ${DEMO_NS}
  labels: { app.kubernetes.io/component: sandbox-probe-listener }
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 0
  automountServiceAccountToken: false
  containers:
    - name: listener
      image: ${NETTEST_IMAGE}
      imagePullPolicy: IfNotPresent
      command: ["socat", "TCP-LISTEN:${GATEWAY_CONTAINER_PORT},fork,reuseaddr", "SYSTEM:echo listener-ok"]
      readinessProbe:
        tcpSocket: { port: ${GATEWAY_CONTAINER_PORT} }
        periodSeconds: 1
EOF
# Delete the pod at once when done.
kc -n "$AGENT_NS" run "$PROBE_POD" --image="$NETTEST_IMAGE" --image-pull-policy=IfNotPresent \
  --overrides='{"apiVersion":"v1","spec":{"terminationGracePeriodSeconds":0}}' \
  --labels="$GOOSE_LABEL" --restart=Never --command -- sleep 3600 >/dev/null   # keepalive, not a wait
for p in "$AGENT_NS/$PROBE_POD" "$DEMO_NS/$LISTENER_POD"; do
  if ! kc -n "${p%%/*}" wait --for=condition=Ready "pod/${p#*/}" --timeout="$POD_READY_TIMEOUT" >/dev/null 2>&1; then
    fail "pod ${p} not Ready within ${POD_READY_TIMEOUT} (image not pre-loaded?)"; exit 1
  fi
done

# Ask Cilium whether the policy is active on the probe pod.
EP_ID="$(kc -n "$AGENT_NS" get cep "$PROBE_POD" -o jsonpath='{.status.id}' 2>/dev/null)"
ENFORCED="$(kc -n "$CILIUM_NS" exec ds/cilium -c cilium-agent -- cilium-dbg endpoint get "$EP_ID" -o json 2>/dev/null \
  | jq -r '.[0].status.policy.realized["policy-enabled"] // empty' 2>/dev/null)"
case "$ENFORCED" in
  egress|both) pass "Cilium enforces egress on the probe endpoint (id ${EP_ID}, policy-enabled=${ENFORCED})" ;;
  *) fail "Cilium is NOT enforcing egress on the probe endpoint (id ${EP_ID:-?}, policy-enabled=${ENFORCED:-?})" ;;
esac

NODE_IP="$(kc get node "$KIND_NODE_CONTAINER" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')"
DOCKER_GW="$(docker network inspect -f '{{range .IPAM.Config}}{{.Gateway}} {{end}}' "$KIND_DOCKER_NETWORK" \
  | tr ' ' '\n' | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -n1)"
LISTENER_IP="$(kc -n "$DEMO_NS" get pod "$LISTENER_POD" -o jsonpath='{.status.podIP}')"
# shellcheck disable=SC2153  # COREDNS_NS comes from demo.env
COREDNS_IP="$(kc -n "$COREDNS_NS" get pods -l k8s-app=kube-dns -o jsonpath='{.items[0].status.podIP}')"

# --- ALLOWED ----------------------------------------------------------------------
log "---------------- allowed ----------------"
for n in kubernetes.default.svc.cluster.local "$MODEL_API_FQDN" "$DOCS_HOST" "$COLLECTOR_HOST"; do
  # All four names must resolve.
  if in_probe timeout 2 getent hosts "$n" >/dev/null 2>&1; then
    pass "DNS resolves ${n}"
  else
    fail "DNS does NOT resolve ${n} — DNS allow rule to kube-dns missing/broken (DEMO-GUIDE.md A2: DNS allow rule)"
  fi
done

if [ "$CHECK_AGENT" != "1" ]; then
  skip "gateway reachable (CHECK_AGENT=0)"
else
  GW_HOST="${GATEWAY_SERVICE}.${DEMO_NS}.svc.cluster.local"
  if tcp_ok in_probe "$GW_HOST" "$GATEWAY_SERVICE_PORT"; then
    pass "gateway reachable (${GW_HOST}:${GATEWAY_SERVICE_PORT} -> pods ${GATEWAY_POD_LABEL}:${GATEWAY_CONTAINER_PORT})"
  else
    fail "gateway NOT reachable (${GW_HOST}:${GATEWAY_SERVICE_PORT}) — check GATEWAY_POD_LABEL / GATEWAY_CONTAINER_PORT in the policy"
  fi
fi

if [ "$ASSUME_OFFLINE" = "1" ]; then
  skip "model API reachable (ASSUME_OFFLINE=1)"
else
  # Any HTTP status proves the connection got through. No key is sent.
  code="$(in_probe curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "${MODEL_BASE_URL}/models" 2>/dev/null)"
  if [ -n "$code" ] && [ "$code" != "000" ]; then
    pass "model API reachable (${MODEL_BASE_URL}/models -> HTTP ${code})"
  else
    fail "model API NOT reachable (${MODEL_BASE_URL}) — toFQDNs rule or DNS match wrong (or no internet: ASSUME_OFFLINE=1)"
  fi
fi

# --- BLOCKED (each first proven reachable from the unrestricted pod) -----------------
log "---------------- blocked (control = ${DEMO_NS}/${CONTROL_POD}, unrestricted) ----------------"
# Check that a TCP target is blocked: blocked_tcp DESCRIPTION HOST PORT
blocked_tcp() {
  local what="$1" host="$2" port="$3"
  if [ -z "$host" ]; then fail "${what}: target address could not be determined"; return; fi
  if ! tcp_ok in_control "$host" "$port"; then
    vacuous "${what} (${host}:${port}) — not reachable even from the control pod; nothing listens, so 'blocked' proves nothing"
  elif tcp_ok in_probe "$host" "$port"; then
    fail "${what} (${host}:${port}) REACHABLE from goose — the fence leaks"
  else
    pass "${what} (${host}:${port}) blocked  [control: reachable]"
  fi
}
blocked_tcp "Kubernetes API"                         kubernetes.default.svc.cluster.local 443
blocked_tcp "kubelet on the node"                    "$NODE_IP" 10250
blocked_tcp "Docker host gateway resolver (tcp)"     "$DOCKER_GW" 53
if ! dns_ok in_control "$DOCKER_GW"; then
  vacuous "Docker host gateway resolver (udp DNS @${DOCKER_GW}) — control gets no reply either"
elif dns_ok in_probe "$DOCKER_GW"; then
  fail "Docker host gateway resolver (udp DNS @${DOCKER_GW}) ANSWERS goose — DNS can bypass Cilium's DNS proxy"
else
  pass "Docker host gateway resolver (udp DNS @${DOCKER_GW}) blocked  [control: answered]"
fi
blocked_tcp "attacker collector"                     "$COLLECTOR_HOST" "$COLLECTOR_PORT"
blocked_tcp "vendor docs, direct (only mcp-fetch may)" "$DOCS_HOST" "$DOCS_PORT"
blocked_tcp "pod in ${DEMO_NS} on the gateway port, wrong label" "$LISTENER_IP" "$GATEWAY_CONTAINER_PORT"
blocked_tcp "CoreDNS pod on a non-DNS port (metrics)" "$COREDNS_IP" 9153
if [ "$ASSUME_OFFLINE" = "1" ]; then
  skip "model host on :80 blocked (ASSUME_OFFLINE=1)"
else
  blocked_tcp "model host on :80 (only 443 allowed)" "$MODEL_API_FQDN" 80
fi

# --- Evidence: Hubble's verdict for each flow (information only) ------------------------
# Allowed paths show FORWARDED, and each blocked target shows DROPPED.
log "---------------- hubble: flows from ${AGENT_NS}/${PROBE_POD} (count verdict destination) ----------------"
kc -n "$CILIUM_NS" exec ds/cilium -c cilium-agent -- \
  hubble observe --from-pod "${AGENT_NS}/${PROBE_POD}" --last 2000 -o json 2>/dev/null \
  | jq -r 'select(.flow != null and (.flow.is_reply // false) == false and (.flow.l7 == null))
      | .flow as $f
      | ($f.l4 | if .TCP then "tcp/\(.TCP.destination_port)" elif .UDP then "udp/\(.UDP.destination_port)" else "other" end) as $p
      | (if $f.destination.pod_name then "\($f.destination.namespace)/\($f.destination.pod_name)"
         else ($f.IP.destination + (if ($f.destination_names // []) | length > 0 then " (" + ($f.destination_names | join(",")) + ")" else "" end)) end) as $d
      | "\($f.verdict)\t\($d) \($p)\t\($f.drop_reason_desc // "")"' 2>/dev/null \
  | sort | uniq -c | sort -k2,2 -k1,1rn \
  || log "(hubble observe unavailable — not a check failure)"

log "----------------------------------------"
if [ "$FAILED" -eq 0 ]; then
  log "GOOSE SANDBOX OK — fence allows only DNS, gateway, model API; every blocked target proven live and refused."
  exit 0
else
  log "GOOSE SANDBOX NOT OK — fix before running the agent (FAIL = leak or broken allow; VACUOUS = test target not live)."
  exit 1
fi
