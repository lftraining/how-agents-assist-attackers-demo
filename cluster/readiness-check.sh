#!/usr/bin/env bash
#
# readiness-check.sh — check that the cluster and every demo component are actually
# ready. It exits 0 when everything passes and prints a FAIL line for each check that
# does not. It never sleeps in place of a real check.

# No `-e`, so every check runs and every failure is reported.
set -uo pipefail

# shellcheck source=../scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/lib/common.sh"

FAILED=0

log()  { printf '%s\n' "$*"; }
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILED=1; }

# Re-run a command until it succeeds or the time is up: retry_within 180s CMD...
# RETRY_NOTE records when it needed more than one attempt.
retry_within() {
  local secs="${1%s}"; shift
  local deadline=$((SECONDS + secs)) n=0
  RETRY_NOTE=""
  while :; do
    n=$((n + 1))
    if "$@" >/dev/null 2>&1; then
      [ "$n" -gt 1 ] && RETRY_NOTE=", after ${n} attempts"
      return 0
    fi
    [ "$SECONDS" -ge "$deadline" ] && return 1
    sleep 1   # poll interval between bounded attempts, not a timer
  done
}

# --- Falco: running and detecting --------------------------------------------------------
# For each Falco pod, check the live process, the eBPF probe, and the loaded rules; then
# check falcosidekick.
FALCO_SIDEKICK_DEPLOY="${FALCO_SIDEKICK_DEPLOY:-${FALCO_DS}-falcosidekick}"
FALCO_RULES_FILE="${FALCO_RULES_FILE:-$REPO_ROOT/$RENDERED_DIR/rules-agent.yaml}"
# Check one Falco pod. With "report", print a FAIL line for each failed check.
falco_pod_ok() {
  local p="$1" report="${2:-}" plog rc=0
  _f() { rc=1; if [ -n "$report" ]; then fail "${p}: $*"; fi; }
  kc get --raw "/api/v1/namespaces/${FALCO_NS}/pods/${p#pod/}:8765/proxy/healthz" 2>/dev/null | grep -q '"ok"' \
    || _f "live Falco process does not answer /healthz on :8765"
  plog="$(kc -n "$FALCO_NS" logs "$p" -c falco --tail=-1 2>/dev/null)"
  grep -qF "Opening 'syscall' source with modern BPF probe" <<<"$plog" \
    || _f "log does not show the modern BPF probe opening (driver fallback? or startup log rotated — restart the pod)"
  grep -qF "/etc/falco/rules.d/rules-agent.yaml | schema validation: ok" <<<"$plog" \
    || _f "rules-agent.yaml not reported loaded (schema ok) in the Falco log"
  # Falco 0.45 logs rule warnings as "Ok, with warnings" and errors as LOAD_ERR_*.
  if grep -qE 'rules-agent\.yaml: Ok, with warnings|LOAD_ERR' <<<"$plog"; then
    _f "Falco reported a rules load error/warning — kubectl -n ${FALCO_NS} logs ${p} -c falco"
  fi
  [ "$(kc -n "$FALCO_NS" exec "$p" -c falco -- cat /etc/falco/rules.d/rules-agent.yaml 2>/dev/null)" = "$(cat "$FALCO_RULES_FILE")" ] \
    || _f "running rules-agent.yaml differs from ${RENDERED_DIR}/rules-agent.yaml — re-run controls/falco/install.sh"
  return "$rc"
}
check_falco() {
  if ! kc -n "$FALCO_NS" rollout status daemonset/"$FALCO_DS" --timeout="$TIMEOUT" >/dev/null 2>&1; then
    fail "Falco DaemonSet '${FALCO_DS}' NOT ready in ns/${FALCO_NS} (check BTF, namespace, DS name)"
    return
  fi
  pass "Falco DaemonSet ready on all nodes"
  local pods p ok=1
  # Skip pods that are shutting down.
  pods="$(kc -n "$FALCO_NS" get pods -l "$FALCO_SELECTOR" --field-selector=status.phase=Running \
            -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.deletionTimestamp}{"\n"}{end}' 2>/dev/null \
          | awk 'NF == 1 {print "pod/" $1}')"
  if [ -z "$pods" ]; then fail "no Running Falco pods match '${FALCO_SELECTOR}' in ns/${FALCO_NS}"; return; fi
  for p in $pods; do
    # Retry while the pod settles after a restart.
    if retry_within "$TIMEOUT" falco_pod_ok "$p"; then :; else falco_pod_ok "$p" report; ok=0; fi
  done
  [ "$ok" -eq 1 ] && pass "Falco on modern eBPF with the current rules-agent.yaml loaded, no load errors"
  if kc -n "$FALCO_NS" rollout status deployment/"$FALCO_SIDEKICK_DEPLOY" --timeout="$TIMEOUT" >/dev/null 2>&1 \
     && kc get --raw "/api/v1/namespaces/${FALCO_NS}/services/http:${FALCO_SIDEKICK_DEPLOY}:2801/proxy/healthz" 2>/dev/null | grep -q '"ok"'; then
    pass "falcosidekick Available and healthy"
  else
    fail "falcosidekick '${FALCO_SIDEKICK_DEPLOY}' not Available/healthy in ns/${FALCO_NS}"
  fi
}

# --falco-only runs just the Falco checks (used by controls/falco/install.sh).
if [ "${1:-}" = "--falco-only" ]; then
  log "=== Falco readiness check ==="
  if ! kc cluster-info >/dev/null 2>&1; then fail "cluster NOT reachable"; exit 1; fi
  check_falco
  if [ "$FAILED" -eq 0 ]; then log "READY — Falco detecting."; exit 0; fi
  log "NOT READY — Falco checks failed."; exit 1
fi

log "=== Demo readiness check ==="
log "Context: ${KUBE_CONTEXT:-<current>}  Timeout per check: ${TIMEOUT}"
log "----------------------------------------"

# --- Check 1: cluster reachable (nothing else can pass without it) ---------------
if kc cluster-info >/dev/null 2>&1; then
  pass "cluster reachable"
else
  fail "cluster NOT reachable (wrong KUBE_CONTEXT, or 'make up' not run yet?)"
  log  "----------------------------------------"
  log  "Cannot continue without a reachable cluster. NOT READY."
  exit 1
fi

# --- Check 2: all nodes Ready ----------------------------------------------------
if kc wait --for=condition=Ready nodes --all --timeout="$TIMEOUT" >/dev/null 2>&1; then
  pass "all nodes Ready"
else
  fail "one or more nodes NOT Ready within ${TIMEOUT}"
  kc get nodes 2>/dev/null || true   # diagnostics only
fi

# --- Check 3: Cilium healthy (falls back to the DaemonSet without the cilium CLI) --
if command -v cilium >/dev/null 2>&1; then
  if cilium status --context "$KUBE_CONTEXT" --wait --wait-duration "$TIMEOUT" >/dev/null 2>&1; then
    pass "Cilium healthy (cilium status --wait)"
  else
    fail "Cilium NOT healthy — run 'cilium status --verbose' to see which component"
  fi
else
  log  "note: cilium CLI not found; falling back to DaemonSet rollout check"
  if kc -n "$CILIUM_NS" rollout status daemonset/cilium --timeout="$TIMEOUT" >/dev/null 2>&1; then
    pass "Cilium DaemonSet rolled out (install cilium CLI for a deeper check)"
  else
    fail "Cilium DaemonSet NOT ready in ns/${CILIUM_NS}"
  fi
fi

# --- Check 4: CoreDNS Available --------------------------------------------------
if kc -n "$COREDNS_NS" rollout status deployment/coredns --timeout="$TIMEOUT" >/dev/null 2>&1; then
  pass "CoreDNS Available"
else
  fail "CoreDNS NOT Available in ns/${COREDNS_NS} (check COREDNS_NS in demo.env)"
fi

# --- Check 4b: the demo names resolve, as a workload resolves them ------------------
DNS_PROBE_POD="${DNS_PROBE_POD:-dns-probe}"
if ! kc -n "$DEMO_NS" wait --for=condition=Ready "pod/${DNS_PROBE_POD}" --timeout="$TIMEOUT" >/dev/null 2>&1; then
  fail "DNS probe pod '${DNS_PROBE_POD}' not Ready in ns/${DEMO_NS} (cilium-install.sh applies cluster/dns-probe.yaml)"
else
  # Each lookup must finish within 1.5 seconds; retry for up to TIMEOUT.
  for host in "$DOCS_HOST" "$COLLECTOR_HOST"; do
    if retry_within "$TIMEOUT" kc -n "$DEMO_NS" exec "$DNS_PROBE_POD" -- timeout 1.5 getent hosts "$host"; then
      pass "${host} resolves via libc within 1.5 s (dns-probe${RETRY_NOTE})"
    else
      fail "${host} does NOT resolve via libc within 1.5 s (retried for ${TIMEOUT}) — check coredns-custom.yaml demo-zone templates + localdomain block"
    fi
  done
  if retry_within "$TIMEOUT" sh -c "kubectl ${KCTX[*]} -n '$DEMO_NS' exec '$DNS_PROBE_POD' -- dig +time=2 +tries=1 probe.localdomain 2>/dev/null | grep -q 'status: NXDOMAIN'"; then
    pass "probe.localdomain answered NXDOMAIN in-cluster (search-suffix stall mitigation active${RETRY_NOTE})"
  else
    fail "probe.localdomain not answered NXDOMAIN (retried for ${TIMEOUT}) — localdomain block missing; lookups will stall on the host resolver"
  fi
fi
if kc -n "$COREDNS_NS" get configmap coredns -o jsonpath='{.data.Corefile}' 2>/dev/null | grep -q 'localdomain:53'; then
  pass "live coredns ConfigMap contains the localdomain:53 block"
else
  fail "live coredns ConfigMap lacks localdomain:53 — re-apply cluster/coredns-custom.yaml and restart CoreDNS"
fi

# --- Check 5: Falco running and detecting (skip with CHECK_FALCO=0) -----------------
if [ "${CHECK_FALCO}" != "1" ]; then
  log "SKIP  Falco (CHECK_FALCO=0)"
else
  check_falco
fi

# --- Checks 6-7: agentgateway + MCP servers (skip with CHECK_AGENT=0) ---------------
if [ "${CHECK_AGENT}" != "1" ]; then
  log "SKIP  agentgateway + MCP servers (CHECK_AGENT=0)"
else
  if kc -n "$DEMO_NS" rollout status deployment/"$GATEWAY_DEPLOY" --timeout="$TIMEOUT" >/dev/null 2>&1; then
    pass "agentgateway Available"
  else
    fail "agentgateway '${GATEWAY_DEPLOY}' NOT Available in ns/${DEMO_NS} (check DEMO_NS/GATEWAY_DEPLOY in demo.env)"
  fi
  for d in $MCP_DEPLOYS; do
    if kc -n "$DEMO_NS" rollout status deployment/"$d" --timeout="$TIMEOUT" >/dev/null 2>&1; then
      pass "MCP server '${d}' Available"
    else
      fail "MCP server '${d}' NOT Available in ns/${DEMO_NS} (check DEMO_NS/MCP_DEPLOYS in demo.env)"
    fi
  done
fi

# --- Check 7b: the goose fence enforces (skip with CHECK_SANDBOX=0) -----------------
# Runs scripts/verify-goose-sandbox.sh, which takes about 30 seconds.
if [ "${CHECK_SANDBOX:-1}" != "1" ]; then
  log "SKIP  goose sandbox fence (CHECK_SANDBOX=0)"
elif SANDBOX_OUT="$(bash "$REPO_ROOT/scripts/verify-goose-sandbox.sh" 2>&1)"; then
  pass "goose sandbox fence enforced (scripts/verify-goose-sandbox.sh)"
else
  fail "goose sandbox fence check FAILED — details:"
  printf '%s\n' "$SANDBOX_OUT" | grep -E '^(FAIL|VACUOUS) ' | sed 's/^/      /'
fi

# --- Check 8: attacker containers up (on by default) ---------------------------------
if [ "$CHECK_DOCKER_CONTAINERS" = "1" ]; then
  for c in $DOCKER_CONTAINERS; do
    state="$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || echo "missing")"
    if [ "$state" = "true" ]; then
      pass "container '${c}' running"
    else
      fail "container '${c}' not running (state: ${state})"
    fi
  done
fi

log "----------------------------------------"
if [ "$FAILED" -eq 0 ]; then
  log "READY — all checks passed. Safe to proceed."
  exit 0
else
  log "NOT READY — one or more checks failed. Do not proceed; fix the FAIL lines and re-run."
  exit 1
fi
