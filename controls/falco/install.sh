#!/usr/bin/env bash
#
# install.sh — install Falco on its modern eBPF probe, plus falcosidekick, with the demo's
# rules. It then confirms Falco is running those rules. It is safe to re-run.

set -euo pipefail

# shellcheck source=../scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../scripts/lib/common.sh"

# --- Pinned versions: chart 9.2.0 installs Falco 0.45.0 and falcosidekick 2.32.0 -----------
FALCO_CHART_VERSION=9.2.0
FALCO_CHART_REPO=https://falcosecurity.github.io/charts
FALCO_IMAGE_REPO=falcosecurity/falco
FALCO_IMAGE_TAG=0.45.0@sha256:788f1129c542171813083d4afc61b16730a47dde8c23d9c39370acef996349b6
SIDEKICK_IMAGE_REPO=falcosecurity/falcosidekick
SIDEKICK_IMAGE_TAG=2.32.0@sha256:1976da72151850aae4436f33a5ed94bdef469f42a9b61c182b4feeb5441fb081
# rules-agent.yaml is a template, so install the rendered copy.
bash "$REPO_ROOT/scripts/render-config.sh" >/dev/null
RULES_FILE="$REPO_ROOT/$RENDERED_DIR/rules-agent.yaml"
# Check that demo.env names falcosidekick the way the chart does.
RELEASE="$FALCO_DS"
[ "$FALCO_SIDEKICK_DEPLOY" = "${RELEASE}-falcosidekick" ] \
  || die "FALCO_SIDEKICK_DEPLOY (${FALCO_SIDEKICK_DEPLOY}) != chart name ${RELEASE}-falcosidekick — fix demo.env"

log() { printf '>> %s\n' "$*"; }
die() { printf 'FATAL %s\n' "$*" >&2; exit 1; }

require_set SHELLTEST_IMAGE

# --- BTF check: on your machine and inside the kind node -----------------------------------
[ -r /sys/kernel/btf/vmlinux ] \
  || die "BTF missing on this machine (/sys/kernel/btf/vmlinux) — the modern eBPF probe cannot load. Run scripts/00-verify-kernel.sh."
docker exec "$KIND_NODE_CONTAINER" test -r /sys/kernel/btf/vmlinux \
  || die "BTF not visible inside '${KIND_NODE_CONTAINER}' (/sys/kernel/btf/vmlinux) — Falco's pod would not see it either"
log "BTF present on this machine and inside ${KIND_NODE_CONTAINER} (kernel $(uname -r))"

kc cluster-info >/dev/null 2>&1 || die "cluster '${KUBE_CONTEXT}' not reachable — create it first"

# --- Check the rules match demo.env -------------------------------------------------------
drift() { grep -qF -- "$1" "$RULES_FILE" || die "rules-agent.yaml drifted from demo.env: missing '$1' ($2)"; }
drift "items: [${DECOY_CRED_PATH}]"                                  DECOY_CRED_PATH
drift "k8s.ns.name = \"${DEMO_NS}\""                                 DEMO_NS
drift "k8s.pod.label[${ROLE_LABEL_KEY}] = \"${ROLE_FS}\""            "ROLE_LABEL_KEY/ROLE_FS"
drift "k8s.pod.label[${ROLE_LABEL_KEY}] in (\"${ROLE_FETCH}\", \"${ROLE_HTTP_POST}\")" "ROLE_FETCH/ROLE_HTTP_POST"
drift "k8s.pod.label[${ROLE_LABEL_KEY}] = \"${ROLE_FETCH}\""         "ROLE_FETCH (expected egress)"
drift "    ${FALCO_CRED_MARKER} "                                    FALCO_CRED_MARKER
drift "    ${FALCO_EXFIL_MARKER} "                                   FALCO_EXFIL_MARKER
drift "'\"${VENDOR_DOCS_IP}:${DOCS_PORT}\"'"                        "VENDOR_DOCS_IP:DOCS_PORT"
log "rules-agent.yaml matches demo.env (path, role labels, markers, docs IP)"

# --- Pull the images into the node by digest -----------------------------------------------
for img in "docker.io/${FALCO_IMAGE_REPO}:${FALCO_IMAGE_TAG}" \
           "docker.io/${SIDEKICK_IMAGE_REPO}:${SIDEKICK_IMAGE_TAG}" \
           "$SHELLTEST_IMAGE"; do
  log "pre-pulling ${img} into ${KIND_NODE_CONTAINER}"
  docker exec "$KIND_NODE_CONTAINER" crictl pull "$img" >/dev/null || die "could not pre-pull ${img}"
done

# --- Install ------------------------------------------------------------------------------
log "helm upgrade --install ${RELEASE} ${FALCO_CHART_VERSION} (Falco modern eBPF + falcosidekick)"
helm upgrade --install "$RELEASE" falco \
  --repo "$FALCO_CHART_REPO" --version "$FALCO_CHART_VERSION" \
  --kube-context "$KUBE_CONTEXT" --namespace "$FALCO_NS" --create-namespace \
  --set-file "customRules.rules-agent\.yaml=${RULES_FILE}" \
  --values - >/dev/null <<VALUES
image:
  registry: docker.io
  repository: ${FALCO_IMAGE_REPO}
  tag: "${FALCO_IMAGE_TAG}"
  pullPolicy: IfNotPresent
tty: true
driver:
  enabled: true
  kind: modern_ebpf
  modernEbpf:
    leastPrivileged: false
    # Larger event buffers (16 MiB per CPU).
    bufSizePreset: 5
    cpusForEachBuffer: 1
collectors:
  enabled: true
  containerEngine:
    enabled: true
    engines:
      docker: {enabled: false}
      podman: {enabled: false}
      containerd: {enabled: false}
      cri:
        enabled: true
        sockets: ["/run/containerd/containerd.sock"]
      lxc: {enabled: false}
      libvirt_lxc: {enabled: false}
      bpm: {enabled: false}
  kubernetes:
    enabled: false
falcoctl:
  artifact:
    install: {enabled: false}
    follow: {enabled: false}
falcosidekick:
  enabled: true
  replicaCount: 1
  image:
    registry: docker.io
    repository: ${SIDEKICK_IMAGE_REPO}
    tag: "${SIDEKICK_IMAGE_TAG}"
    pullPolicy: IfNotPresent
  config:
    debug: true
  webui:
    enabled: false
falco:
  # Log any dropped events.
  syscall_event_drops:
    threshold: 0.1
    actions:
      - log
    rate: 0.03333
    max_burst: 1
  rules:
    - disable:
        rule: "*"
    - enable:
        tag: demo
VALUES

# --- Wait until ready ---------------------------------------------------------------------
log "waiting: rollout of ds/${FALCO_DS} and deploy/${FALCO_SIDEKICK_DEPLOY}"
kc -n "$FALCO_NS" rollout status daemonset/"$FALCO_DS" --timeout="$TIMEOUT" >/dev/null \
  || { kc -n "$FALCO_NS" logs -l "$FALCO_SELECTOR" -c falco --tail=30 2>&1 || true
       die "Falco DaemonSet did not roll out within ${TIMEOUT} (BTF? kernel/probe compatibility? see log above)"; }
kc -n "$FALCO_NS" rollout status deployment/"$FALCO_SIDEKICK_DEPLOY" --timeout="$TIMEOUT" >/dev/null \
  || die "falcosidekick did not become Available within ${TIMEOUT}"

# Confirm the probe opened and the rules loaded.
CHECK_FALCO=1 bash "$REPO_ROOT/cluster/readiness-check.sh" --falco-only \
  || die "Falco is rolled out but not verifiably detecting (see FAIL lines above)"

log "Falco ${FALCO_IMAGE_TAG%%@*} (chart ${FALCO_CHART_VERSION}) on modern eBPF, rules-agent.yaml loaded, falcosidekick up"
log "next: bash scripts/smoke-test-falco.sh (proves AGENT_CRED_READ actually fires)"
