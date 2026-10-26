#!/usr/bin/env bash
# wire-registry-to-kind.sh — confirm the registry is NOT connected to the cluster. Only
# ToolHive on your machine uses it. Read-only.
set -uo pipefail
# shellcheck source=../scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/lib/common.sh"

FAILED=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILED=1; }

echo ">> registry wiring: intentionally NONE (only ToolHive on this machine uses it)"

nets="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$REGISTRY_NAME" 2>/dev/null || true)"
if [ -z "$nets" ]; then
  fail "registry container '${REGISTRY_NAME}' not found — run registry/run-registry.sh first"
elif printf ' %s ' "$nets" | grep -q " ${KIND_DOCKER_NETWORK} "; then
  fail "registry is attached to Docker network '${KIND_DOCKER_NETWORK}' — detach it (docker network disconnect ${KIND_DOCKER_NETWORK} ${REGISTRY_NAME}); it can steal the node's IP after a reboot"
elif [ "${nets% }" != "$REGISTRY_NETWORK" ]; then
  fail "registry is on '${nets% }', expected only its own '${REGISTRY_NETWORK}' (e.g. the default bridge lets any container push to it)"
else
  pass "registry not on the '${KIND_DOCKER_NETWORK}' network; only on its own '${REGISTRY_NETWORK}'"
fi

if images="$(kc get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null)"; then
  hits="$(printf '%s\n' "$images" | grep -E "(^|/)(${REGISTRY//./\\.}|127\.0\.0\.1:${REGISTRY_PORT}|${REGISTRY_NAME}(:[0-9]+)?)/" | sort -u || true)"
  if [ -n "$hits" ]; then
    fail "pod image(s) reference the local registry, which the cluster cannot reach: ${hits//$'\n'/, }"
  else
    pass "no pod in the cluster pulls from the local registry"
  fi
else
  fail "cannot list pods in context ${KUBE_CONTEXT} — is the cluster up?"
fi

exit "$FAILED"
