#!/usr/bin/env bash
#
# cilium-install.sh — install Cilium and Hubble as the cluster's network plugin, replacing
# kube-proxy, and wait for Cilium's own health check (not just for pods to start). It is
# safe to re-run.

set -euo pipefail

# shellcheck source=../scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/lib/common.sh"

# Cilium 1.19 supports Kubernetes 1.32, the version of the kind node.
CILIUM_VERSION=1.19.8
CILIUM_CHART_REPO=https://helm.cilium.io
# Hubble's flow history size. It must be 2^n-1, at most 65535.
HUBBLE_FLOW_BUFFER=65535

log() { printf '>> %s\n' "$*"; }
die() { printf 'FATAL %s\n' "$*" >&2; exit 1; }

kc cluster-info >/dev/null 2>&1 || die "cluster '${KUBE_CONTEXT}' not reachable — create it first"

# Cilium replaces kube-proxy, so kube-proxy must not be running.
if kc -n kube-system get daemonset kube-proxy >/dev/null 2>&1; then
  die "kube-proxy DaemonSet present — kind-config.yaml must set kubeProxyMode: none"
fi

# The node must be on exactly one Docker network.
NODE_NETS="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$KIND_NODE_CONTAINER")"
[ "$NODE_NETS" = "${KIND_DOCKER_NETWORK} " ] \
  || die "'${KIND_NODE_CONTAINER}' is on Docker networks [${NODE_NETS% }] — it must be on '${KIND_DOCKER_NETWORK}' only"

log "helm upgrade --install cilium ${CILIUM_VERSION} (kube-proxy replacement + Hubble)"
helm upgrade --install cilium cilium \
  --repo "$CILIUM_CHART_REPO" --version "$CILIUM_VERSION" \
  --kube-context "$KUBE_CONTEXT" --namespace "$CILIUM_NS" \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost="$KIND_NODE_CONTAINER" \
  --set k8sServicePort=6443 \
  --set ipam.mode=kubernetes \
  --set operator.replicas=1 \
  --set dnsProxy.dnsRejectResponseCode=nameError \
  --set rollOutCiliumPods=true \
  --set image.pullPolicy=IfNotPresent \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set-string hubble.eventBufferCapacity="$HUBBLE_FLOW_BUFFER" \
  --set hubble.ui.enabled=false \
  >/dev/null

# --- Wait until ready ---------------------------------------------------------------
log "waiting: rollout of ds/cilium and ds/cilium-envoy"
kc -n "$CILIUM_NS" rollout status daemonset/cilium --timeout="$TIMEOUT" >/dev/null \
  || die "Cilium agent DaemonSet did not roll out within ${TIMEOUT}"
kc -n "$CILIUM_NS" rollout status daemonset/cilium-envoy --timeout="$TIMEOUT" >/dev/null \
  || die "cilium-envoy DaemonSet did not roll out within ${TIMEOUT}"
log "waiting: cilium status --wait (agent, operator, envoy, Hubble relay)"
cilium status --context "$KUBE_CONTEXT" --wait --wait-duration "$TIMEOUT" >/dev/null \
  || { cilium status --context "$KUBE_CONTEXT" || true; die "Cilium not healthy within ${TIMEOUT}"; }

log "waiting: nodes Ready (the CNI is what makes them Ready)"
kc wait --for=condition=Ready nodes --all --timeout="$TIMEOUT" >/dev/null \
  || { kc get nodes -o wide || true; die "nodes not Ready within ${TIMEOUT}"; }

log "waiting: CoreDNS rollout (it cannot start without a CNI)"
kc -n "$COREDNS_NS" rollout status deployment/coredns --timeout="$TIMEOUT" >/dev/null \
  || die "CoreDNS not Available within ${TIMEOUT}"

# Confirm each setting from the running agent.
AGENT_STATUS="$(kc -n "$CILIUM_NS" exec ds/cilium -c cilium-agent -- cilium-dbg status 2>/dev/null)" \
  || die "could not query cilium-dbg status from the agent"
KPR_LINE="$(printf '%s\n' "$AGENT_STATUS" | grep -E '^KubeProxyReplacement:' || true)"
case "$KPR_LINE" in
  *True*) log "agent reports ${KPR_LINE}" ;;
  *) die "kube-proxy replacement not active: '${KPR_LINE:-<missing>}'" ;;
esac

REJECT="$(printf '%s\n' "$(kc -n "$CILIUM_NS" exec ds/cilium -c cilium-agent -- cilium-dbg config --all 2>/dev/null)" \
  | awk -F': *' '/^FQDNRejectResponse/ {gsub(/ /, "", $2); print $2}')"
[ "$REJECT" = "nameError" ] || die "running Cilium agent FQDNRejectResponse='${REJECT:-<unknown>}', want nameError (agent not restarted?)"
log "agent reports FQDNRejectResponse=${REJECT}"

HUBBLE_MAX="$(printf '%s\n' "$AGENT_STATUS" | sed -n 's|.*Current/Max Flows: [0-9,]*/\([0-9,]*\).*|\1|p' | tr -d ,)"
[ "$HUBBLE_MAX" = "$HUBBLE_FLOW_BUFFER" ] \
  || die "running agent's Hubble flow buffer is '${HUBBLE_MAX:-<unknown>}', want ${HUBBLE_FLOW_BUFFER} (agent not restarted?)"
log "agent reports Hubble flow buffer max=${HUBBLE_MAX}"

# Pull the test image into the node by digest.
require_set NETTEST_IMAGE
log "pre-pulling ${NETTEST_IMAGE} into ${KIND_NODE_CONTAINER}"
docker exec "$KIND_NODE_CONTAINER" crictl pull "$NETTEST_IMAGE" >/dev/null

# Start the DNS probe pod for the readiness check, after confirming it matches demo.env.
PROBE_FILE="$REPO_ROOT/cluster/dns-probe.yaml"
grep -qF "image: ${NETTEST_IMAGE}" "$PROBE_FILE" || die "cluster/dns-probe.yaml image != NETTEST_IMAGE in demo.env"
grep -qE "^[[:space:]]+namespace: ${DEMO_NS}\$" "$PROBE_FILE" || die "cluster/dns-probe.yaml namespace != DEMO_NS in demo.env"
kc get namespace "$DEMO_NS" >/dev/null 2>&1 || die "namespace ${DEMO_NS} missing — apply cluster/namespaces.yaml first"
log "applying DNS probe pod (cluster/dns-probe.yaml) and waiting for Ready"
kc apply -f "$PROBE_FILE" >/dev/null
kc -n "$DEMO_NS" wait --for=condition=Ready pod/dns-probe --timeout="$TIMEOUT" >/dev/null \
  || die "dns-probe pod not Ready within ${TIMEOUT}"

log "Cilium ${CILIUM_VERSION} healthy, kube-proxy replacement active, Hubble relay up"
