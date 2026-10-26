#!/usr/bin/env bash
#
# check-recipe.sh — check the shared recipe that both runs use. Read-only; it never runs goose.
#   1. There is exactly one recipe file.
#   2. The recipe names no vendor or model, and demo.env pins an exact model.
#   3. temperature is 0, or the line is removed with a comment saying why.
#   4. A prompt is present.
#   5. The only tool endpoint is agentgateway, with no built-in that bypasses it.
# It uses yq when installed and falls back to grep otherwise.

set -uo pipefail   # not -e, so every check runs and every failure is reported

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

RECIPE="${REPO_ROOT}/${RECIPE}"
AGENT_DIR="$(dirname "$RECIPE")"
# The one allowed MCP extension.
GATEWAY_EXT_NAME="${GATEWAY_EXT_NAME:-agentgateway}"
# Servers that belong behind the gateway, and goose built-ins that would bypass it.
DIRECT_SERVER_NAMES="${DIRECT_SERVER_NAMES:-fetch filesystem http_post http-post fs developer computercontroller}"

FAILED=0
log()  { printf '%s\n' "$*"; }
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILED=1; }

if [ ! -f "$RECIPE" ]; then
  fail "recipe not found: ${RECIPE} (set RECIPE in demo.env)"
  exit 1
fi

HAVE_YQ=0
command -v yq >/dev/null 2>&1 && HAVE_YQ=1

log "=== goose recipe determinism check ==="
log "Recipe: ${RECIPE}   (yq available: ${HAVE_YQ})"
log "----------------------------------------"

# --- Check 1: exactly one recipe file -----------------------------------------------
RECIPE_COUNT=0
for f in "${AGENT_DIR}"/*.yaml "${AGENT_DIR}"/*.yml; do
  [ -f "$f" ] || continue
  if grep -qE '^[[:space:]]*prompt:|^[[:space:]]*instructions:' "$f" 2>/dev/null; then
    RECIPE_COUNT=$((RECIPE_COUNT + 1))
  fi
done
if [ "$RECIPE_COUNT" -eq 1 ]; then
  pass "exactly one recipe file in ${AGENT_DIR}/ — no second recipe to diverge"
else
  fail "found ${RECIPE_COUNT} recipe-like files in ${AGENT_DIR}/ — there must be exactly ONE"
  grep -lE '^[[:space:]]*prompt:|^[[:space:]]*instructions:' "${AGENT_DIR}"/*.y*ml 2>/dev/null | sed 's/^/      /'
fi

# --- Check 2: no vendor or model in the recipe; an exact model in demo.env ---------------
if grep -qE '^[[:space:]]*goose_(provider|model):' "$RECIPE"; then
  fail "recipe pins goose_provider/goose_model — remove them; the vendor is chosen via MODEL_VENDOR (demo.env) and the Job's GOOSE_PROVIDER/GOOSE_MODEL env"
else
  pass "recipe does not hard-code a provider/model (vendor-neutral; chosen via MODEL_VENDOR)"
fi
if [ -z "${MODEL_ID:-}" ] || printf '%s' "$MODEL_ID" | grep -q 'PLACEHOLDER'; then
  fail "active model (MODEL_ID for vendor '${MODEL_VENDOR:-?}') is empty or a PLACEHOLDER — set a model slug in demo.env"
elif printf '%s' "$MODEL_ID" | grep -qiE 'latest|^auto$'; then
  fail "active model '${MODEL_ID}' is a floating alias — pin an exact slug in demo.env"
else
  pass "active model is pinned ('${MODEL_ID}' for vendor '${MODEL_VENDOR}')"
fi

# --- Check 3: temperature 0, or absent with an explanatory comment ---------------
if grep -qE '^[[:space:]]*temperature:[[:space:]]*0(\.0+)?[[:space:]]*(#.*)?$' "$RECIPE"; then
  pass "temperature pinned to 0 (deterministic)"
elif grep -qE '^[[:space:]]*temperature:' "$RECIPE"; then
  TVAL="$(grep -E '^[[:space:]]*temperature:' "$RECIPE" | head -1 | sed -E 's/.*temperature:[[:space:]]*//')"
  fail "temperature is '${TVAL}', not 0 — set 0 for determinism (or remove it if the provider 400s)"
elif grep -qiE '#.*temperature' "$RECIPE"; then
  pass "temperature intentionally absent (comment explains the provider-400 removal)"
else
  fail "temperature neither 0 nor documented-absent — set 'temperature: 0', or remove it WITH a comment explaining why"
fi

# --- Check 4: a prompt is present ----------------------------------------------------
if grep -qE '^[[:space:]]*prompt:' "$RECIPE"; then
  pass "prompt present (headless mode will run non-interactively)"
else
  fail "no 'prompt:' field — headless 'goose run --recipe' needs it, and it is the fixed task for BOTH runs"
fi

# --- Check 5: the gateway is the only tool endpoint ----------------------------------
if grep -qE "name:[[:space:]]*[\"']?${GATEWAY_EXT_NAME}[\"']?" "$RECIPE"; then
  pass "gateway extension '${GATEWAY_EXT_NAME}' is present"
else
  fail "no extension named '${GATEWAY_EXT_NAME}' — the single MCP endpoint must be the gateway"
fi

DIRECT_HIT=0
for n in $DIRECT_SERVER_NAMES; do
  # Flag a server only when it is an extension name.
  if grep -qE "name:[[:space:]]*[\"']?${n}[\"']?" "$RECIPE"; then
    [ "$DIRECT_HIT" -eq 0 ] && fail "direct MCP server / built-in extension(s) found — these bypass the gateway:"
    printf '      direct extension name: %s\n' "$n"
    DIRECT_HIT=1
  fi
done
[ "$DIRECT_HIT" -eq 0 ] && pass "no direct MCP server or built-in extensions (gateway not bypassed)"

log "----------------------------------------"
if [ "$FAILED" -eq 0 ]; then
  log "ALL CHECKS PASSED — recipe honors the determinism / byte-identical contract."
  exit 0
else
  log "ONE OR MORE CHECKS FAILED — fix the FAIL lines before using the recipe for either run."
  exit 1
fi
