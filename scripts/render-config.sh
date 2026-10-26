#!/usr/bin/env bash
#
# render-config.sh — fill this machine's values into the three config templates and write
# the copies that get applied, in RENDERED_DIR:
#
#   cluster/coredns-custom.yaml                  the attacker IPs
#   controls/falco/rules-agent.yaml              the vendor docs IP
#   controls/cilium/goose-baseline-egress.yaml   your model vendor's API host
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
cd "$REPO_ROOT"

require_attacker_ips
require_set MODEL_API_FQDN
OUT="${REPO_ROOT}/${RENDERED_DIR}"
mkdir -p "$OUT"

render() {  # render TEMPLATE
  local src="$1" dst
  dst="${OUT}/$(basename "$1")"
  grep -qE '__(VENDOR_DOCS_IP|COLLECTOR_IP|MODEL_API_FQDN)__' "$src" \
    || { printf 'FATAL %s has no known placeholder — is it still a template?\n' "$src" >&2; exit 1; }
  # Fill in placeholders on non-comment lines only.
  sed -e "/^[[:space:]]*#/!s/__VENDOR_DOCS_IP__/${VENDOR_DOCS_IP}/g" \
      -e "/^[[:space:]]*#/!s/__COLLECTOR_IP__/${COLLECTOR_IP}/g" \
      -e "/^[[:space:]]*#/!s/__MODEL_API_FQDN__/${MODEL_API_FQDN}/g" "$src" > "${dst}.tmp"
  # No placeholder may remain outside a comment.
  if grep -vE '^[[:space:]]*#' "${dst}.tmp" | grep -qE '__[A-Z_]+__'; then
    rm -f "${dst}.tmp"
    printf 'FATAL %s still contains an unfilled placeholder after rendering\n' "$src" >&2; exit 1
  fi
  mv "${dst}.tmp" "$dst"
  printf '>> rendered %s -> %s\n' "$src" "${RENDERED_DIR}/$(basename "$dst")"
}

render cluster/coredns-custom.yaml
render controls/falco/rules-agent.yaml
render controls/cilium/goose-baseline-egress.yaml
printf '>> attacker IPs on %s (%s): %s=%s  %s=%s\n' \
  "$KIND_DOCKER_NETWORK" "$KIND_SUBNET" "$DOCS_HOST" "$VENDOR_DOCS_IP" "$COLLECTOR_HOST" "$COLLECTOR_IP"
printf '>> model vendor: %s  provider=%s  host=%s  model=%s\n' \
  "$MODEL_VENDOR" "$MODEL_PROVIDER" "$MODEL_API_FQDN" "$MODEL_ID"
