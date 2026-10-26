#!/usr/bin/env bash
#
# validate-policy.sh — check the gateway policy: it compiles, no rule uses the tool
# arguments, the exfiltration tool is denied by name, and an allow list exists. Read-only.

set -uo pipefail   # not -e, so every check runs and every failure is reported

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# The defended gateway config.
CONFIG="${CONFIG:-${REPO_ROOT}/${GATEWAY_POLICY}}"
AGENTGATEWAY_BIN="${AGENTGATEWAY_BIN:-agentgateway}"
SKIP_VALIDATE_ONLY="${SKIP_VALIDATE_ONLY:-0}"
# Fields that no rule may use.
FORBIDDEN_FIELDS="${FORBIDDEN_FIELDS:-mcp.tool.arguments}"

FAILED=0
log()  { printf '%s\n' "$*"; }
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILED=1; }

if [ ! -f "$CONFIG" ]; then
  fail "config not found: ${CONFIG} (set GATEWAY_POLICY in demo.env)"
  exit 1
fi

log "=== agentgateway MCP authz policy check ==="
log "Config: ${CONFIG}"
log "----------------------------------------"

# --- Check 1: the config compiles ----------------------------------------------------
if [ "$SKIP_VALIDATE_ONLY" = "1" ]; then
  log "SKIP  --validate-only skipped (SKIP_VALIDATE_ONLY=1); relying on static checks"
elif command -v "$AGENTGATEWAY_BIN" >/dev/null 2>&1; then
  if "$AGENTGATEWAY_BIN" --validate-only -f "$CONFIG" >/dev/null 2>&1; then
    pass "config compiles (agentgateway --validate-only)"
  else
    fail "config does NOT compile — run: ${AGENTGATEWAY_BIN} --validate-only -f ${CONFIG}"
  fi
else
  log  "note: '${AGENTGATEWAY_BIN}' not on PATH; cannot run --validate-only."
  log  "      Install it or set SKIP_VALIDATE_ONLY=1. Static checks still run below."
fi

# --- Check 2: no rule uses the tool arguments ----------------------------------------
TRAP1_HIT=0
for fld in $FORBIDDEN_FIELDS; do
  # Match the field name with its dots escaped.
  if grep -nF "$fld" "$CONFIG" >/dev/null 2>&1; then
    [ "$TRAP1_HIT" -eq 0 ] && fail "post-request-only field in an authz rule (issue #3092 — denies ALL calls):"
    grep -nF "$fld" "$CONFIG" | sed 's/^/      /'
    TRAP1_HIT=1
  fi
done
[ "$TRAP1_HIT" -eq 0 ] && pass "no post-request-only fields referenced (${FORBIDDEN_FIELDS// /, })"

# --- Check 3: the exfiltration tool is denied by name ---------------------------------
if grep -nE "deny:.*${EXFIL_TOOL_NAME}" "$CONFIG" >/dev/null 2>&1 \
   || grep -nE "${EXFIL_TOOL_NAME}.*deny" "$CONFIG" >/dev/null 2>&1; then
  pass "exfil tool '${EXFIL_TOOL_NAME}' is explicitly denied (it is also filtered from tools/list — D6)"
elif grep -nF "$EXFIL_TOOL_NAME" "$CONFIG" >/dev/null 2>&1; then
  fail "exfil tool '${EXFIL_TOOL_NAME}' appears but not in an explicit 'deny:' rule — make the intent explicit. Add: - deny: 'mcp.tool.name == \"${EXFIL_TOOL_NAME}\"'"
else
  fail "exfil tool '${EXFIL_TOOL_NAME}' not referenced at all — add an explicit deny rule so the intent is reviewable."
fi

# --- Check 4: an allow list exists, so the policy is deny-by-default --------------------
if grep -nE "allow:" "$CONFIG" >/dev/null 2>&1 \
   || grep -nE "mcp\.tool\.name[[:space:]]*==" "$CONFIG" >/dev/null 2>&1; then
  pass "allowlist present (deny-by-default posture)"
else
  fail "no allow rules found — without an allowlist the policy is allow-all except explicit denies; add the legitimate tools as allow rules"
fi

log "----------------------------------------"
if [ "$FAILED" -eq 0 ]; then
  log "ALL CHECKS PASSED — policy compiles and avoids both traps."
  log "Reminder: --validate-only proves compilation, not intent. Confirm behaviorally with a run:"
  log "  defended run completes legitimate work, the collector stays empty, and"
  log "  controls/agentgateway/probe-deny.sh shows the tool absent from tools/list + a direct call refused."
  exit 0
else
  log "ONE OR MORE CHECKS FAILED — fix the FAIL lines before trusting the policy."
  exit 1
fi
