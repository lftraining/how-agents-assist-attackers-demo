#!/usr/bin/env bash
#
# apply-policy.sh --open | --defended — switch the gateway's mode and restart it.
#
#   --defended  loads mcp-authz-policy.yaml as is: the tool servers plus the policy.
#   --open      loads the same file without its policy block, so anything is allowed.
#
# The config is validated before it is applied.
set -euo pipefail

# shellcheck source=../../scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"

MODE="${1:-}"
case "$MODE" in
  --open|--defended) ;;
  *) echo "usage: $0 --open | --defended" >&2; exit 2 ;;
esac

require_set GATEWAY_POLICY
require_set GATEWAY_CONFIGMAP
require_set GATEWAY_DEPLOY
POLICY="${REPO_ROOT}/${GATEWAY_POLICY}"
[ -f "$POLICY" ] || { echo "FATAL gateway policy not found: $POLICY" >&2; exit 1; }

AGENTGATEWAY_BIN="${AGENTGATEWAY_BIN:-agentgateway}"
RENDERED="$(mktemp)"
trap 'rm -f "$RENDERED"' EXIT

# Build the config for the chosen mode.
if [ "$MODE" = "--defended" ]; then
  cp "$POLICY" "$RENDERED"
  echo ">> apply-policy: DEFENDED — deny-by-default authz from ${GATEWAY_POLICY}"
else
  # Remove the policy block, which allows every tool.
  yq 'del(.mcp.policies)' "$POLICY" > "$RENDERED"
  echo ">> apply-policy: OPEN — targets only (policy block stripped from ${GATEWAY_POLICY})"
fi

# Stop if the config does not compile.
if command -v "$AGENTGATEWAY_BIN" >/dev/null 2>&1; then
  if ! "$AGENTGATEWAY_BIN" --validate-only -f "$RENDERED" >/dev/null 2>&1; then
    echo "FATAL rendered config does not validate — not applying:" >&2
    "$AGENTGATEWAY_BIN" --validate-only -f "$RENDERED" >&2 || true
    exit 1
  fi
  echo "   config validated (agentgateway --validate-only)"
else
  echo "   note: '$AGENTGATEWAY_BIN' not on PATH; skipping --validate-only (install it to gate here)"
fi

# Replace the gateway's ConfigMap.
kc -n "$DEMO_NS" create configmap "$GATEWAY_CONFIGMAP" \
  --from-file=config.yaml="$RENDERED" \
  --dry-run=client -o yaml \
| kc label --local -f - -o yaml app=agentgateway \
| kc apply -f -

# Stamp the config's hash on the pod template, which restarts the gateway when it changes.
HASH="$(sha256sum "$RENDERED" | cut -c1-16)"
if kc -n "$DEMO_NS" get deploy "$GATEWAY_DEPLOY" >/dev/null 2>&1; then
  kc -n "$DEMO_NS" patch deploy "$GATEWAY_DEPLOY" --type merge \
    -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"agentgateway.demo/config-hash\":\"${HASH}\"}}}}}"
  kc -n "$DEMO_NS" rollout status deploy/"$GATEWAY_DEPLOY" --timeout="${TIMEOUT}"
else
  echo "   note: Deployment ${GATEWAY_DEPLOY} not present yet; ConfigMap set. Apply deploy.yaml to create it."
fi
echo ">> apply-policy: done (${MODE#--})."
