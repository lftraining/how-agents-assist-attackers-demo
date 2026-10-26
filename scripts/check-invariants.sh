#!/usr/bin/env bash
#
# check-invariants.sh — audit the demo's rules (`make review`). It reports each one as PASS
# or UNVERIFIED, grades findings BLOCKER, MAJOR, or NIT with file and line, and ends with a
# READY or NOT-READY verdict. It is read-only, and a missing file is a BLOCKER.
#
# Rules that only a live run can prove are listed as UNVERIFIED, with the command that
# proves each one; the script never guesses PASS for them. It exits 0 when there is no BLOCKER.

set -uo pipefail   # not -e, so every check runs and every finding is reported

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

cd "$REPO_ROOT" || { echo "FAIL  cannot cd to REPO_ROOT='$REPO_ROOT'"; exit 1; }

AGENT_DIR="$(dirname "$RECIPE")"
ATTACKER_DIR="attacker"
DECOY_FILE="${ATTACKER_DIR}/decoy-creds/credentials"
EGRESS_POLICY="controls/cilium/egress-policy.yaml"
INSTALL_SCRIPT="scripts/01-install-tools.sh"
GOOSE_JOB="${GOOSE_JOB_MANIFEST}"
MAKEFILE="Makefile"

BLOCKERS=0; MAJORS=0; NITS=0
log()    { printf '%s\n' "$*"; }
ok()     { printf 'PASS       %s\n' "$*"; }
unver()  { printf 'UNVERIFIED %s\n' "$*"; }
blocker(){ printf 'BLOCKER    %s\n' "$*"; BLOCKERS=$((BLOCKERS+1)); }
major()  { printf 'MAJOR      %s\n' "$*"; MAJORS=$((MAJORS+1)); }
nit()    { printf 'NIT        %s\n' "$*"; NITS=$((NITS+1)); }

# True if the file exists; otherwise record a BLOCKER: present <file>
present() { [ -f "$1" ] && return 0; blocker "missing file: $1"; return 1; }

# The whole host must match.
is_local_host() { printf '%s' "$1" | grep -qE "^${ALLOWED_HOST_PATTERN}\$"; }

# The "forbidden mention" scans check code and config only, not Markdown.
DOC_EXCL=(--exclude-dir=.git --exclude='*.md' --exclude="$(basename "$0")")
# The secrets scan covers every file except .git.
SECRET_EXCL=(--exclude-dir=.git)

log "=== Demo invariant audit (read-only) ==="
log "Repo root: $(pwd)"
log "----------------------------------------"

# --- INV 1: no real secrets anywhere (BLOCKER) -----------------------------------
#   ALWAYS_PATTERNS     Private keys and API tokens, forbidden in every file.
#   AWS_DECOY_PATTERNS  AWS key shapes, allowed only in the decoy and its ConfigMap.
ALWAYS_PATTERNS='-----BEGIN [A-Z ]*PRIVATE KEY-----|sk-ant-[A-Za-z0-9_-]{20,}|sk-or-v1-[A-Za-z0-9]{32,}|sk-[A-Za-z0-9]{32,}|ghp_[A-Za-z0-9]{36}|gho_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{40,}|xox[baprs]-[A-Za-z0-9-]{10,}'
AWS_DECOY_PATTERNS='AKIA[0-9A-Z]{16}|aws_secret_access_key[[:space:]]*=[[:space:]]*[A-Za-z0-9/+]{40}'
DECOY_AWS_EXCL=(--exclude=credentials --exclude=00-mcp-fs-decoy-configmap.yaml)
HIST_EXCL=(':(exclude)attacker/decoy-creds/credentials' ':(exclude)agent/mcp-servers/k8s/00-mcp-fs-decoy-configmap.yaml')
if grep -rnE "${SECRET_EXCL[@]}" -e "$ALWAYS_PATTERNS" . >/dev/null 2>&1 \
   || grep -rnE "${SECRET_EXCL[@]}" "${DECOY_AWS_EXCL[@]}" -e "$AWS_DECOY_PATTERNS" . >/dev/null 2>&1; then
  blocker "real-looking secret(s) found in the repo:"
  grep -rnE "${SECRET_EXCL[@]}" -e "$ALWAYS_PATTERNS" . | sed 's/^/           /'
  grep -rnE "${SECRET_EXCL[@]}" "${DECOY_AWS_EXCL[@]}" -e "$AWS_DECOY_PATTERNS" . | sed 's/^/           /'
else
  ok "no real-looking secrets/keys/tokens anywhere in the working tree (decoy exempt per D14)"
fi
if git rev-parse --git-dir >/dev/null 2>&1 && [ -n "$(git rev-list --all 2>/dev/null | head -1)" ]; then
  if git log --all -p 2>/dev/null | grep -qE -e "$ALWAYS_PATTERNS" \
     || git log --all -p -- . "${HIST_EXCL[@]}" 2>/dev/null | grep -qE -e "$AWS_DECOY_PATTERNS"; then
    blocker "real-looking secret(s) in git HISTORY — rewrite history before any push"
  else
    ok "no real-looking secrets in git history (decoy paths exempt per D14)"
  fi
else
  unver "git history not scanned (no commits yet)"
fi

# --- INV 2: the decoy exists and its README says it is synthetic (BLOCKER) --------
DECOY_README="$(dirname "$DECOY_FILE")/README.md"
if present "$DECOY_FILE"; then
  if [ ! -f "$DECOY_README" ]; then
    blocker "decoy provenance missing: ${DECOY_README} must document the decoy as synthetic/invented (D14)"
  elif ! grep -qiE 'synthetic|invented|not a real' "$DECOY_README"; then
    blocker "decoy provenance ${DECOY_README} does not assert the credential is synthetic/invented (D14)"
  else
    ok "decoy present and documented synthetic in decoy-creds/README.md (not agent-visible)"
  fi
fi

# --- INV 3: collector / all attacker destinations local-only (BLOCKER) ----------
NONLOCAL=0
URL_HITS="$(grep -rnoE 'https?://[A-Za-z0-9._:-]+' "$ATTACKER_DIR" 2>/dev/null || true)"
if [ -n "$URL_HITS" ]; then
  while IFS= read -r line; do
    url="${line##*:http}"; url="http${url}"
    host="${url#http://}"; host="${host#https://}"; host="${host%%/*}"; host="${host%%:*}"
    if ! is_local_host "$host"; then
      [ "$NONLOCAL" -eq 0 ] && blocker "non-local URL(s) in attacker content:"
      printf '           %s\n' "$line"; NONLOCAL=1
    fi
  done <<< "$URL_HITS"
fi
[ "$NONLOCAL" -eq 0 ] && ok "attacker content has no non-local URLs (run scripts/check-inert.sh for the full guardrail)"

# --- INV 4: no Kyverno / admission webhook (BLOCKER) -----------------------------
KYV_RE='kyverno|ValidatingWebhookConfiguration|admissionregistration'
if grep -rniE "${DOC_EXCL[@]}" "$KYV_RE" controls cluster agent "$MAKEFILE" >/dev/null 2>&1; then
  blocker "Kyverno/admission-webhook reference in deployment config (it was cut):"
  grep -rniE "${DOC_EXCL[@]}" "$KYV_RE" controls cluster agent "$MAKEFILE" | sed 's/^/           /'
else
  ok "no Kyverno / admission-webhook in deployment config"
fi

# --- INV 5: Cilium replaces the default CNI (BLOCKER) ----------------------------
if present "$KIND_CONFIG"; then
  if grep -qE 'disableDefaultCNI:[[:space:]]*true' "$KIND_CONFIG"; then
    ok "kind-config sets disableDefaultCNI: true (Cilium is the CNI)"
  else
    blocker "${KIND_CONFIG} does not set 'disableDefaultCNI: true'"
  fi
fi

# --- INV 6: Cilium egress keeps a DNS allow rule; selects by role, not app (BLOCKER)
if present "$EGRESS_POLICY"; then
  if grep -qE 'kube-dns' "$EGRESS_POLICY" && grep -qE 'dns:' "$EGRESS_POLICY"; then
    ok "egress policy includes a DNS allow rule to CoreDNS/kube-dns"
  else
    blocker "${EGRESS_POLICY} missing a DNS allow rule — FQDN policy will be inert"
  fi
  if grep -qE "${ROLE_LABEL_KEY}" "$EGRESS_POLICY"; then
    ok "egress policy selects pods by the '${ROLE_LABEL_KEY}' role label"
  else
    major "${EGRESS_POLICY} does not select by '${ROLE_LABEL_KEY}' — policies must use the role label"
  fi
fi

# --- INV 7: exactly one recipe; gateway not bypassed (BLOCKER) -------------------
RCOUNT=0
for f in "${AGENT_DIR}"/*.yaml "${AGENT_DIR}"/*.yml; do
  [ -f "$f" ] || continue
  grep -qE '^[[:space:]]*prompt:|^[[:space:]]*instructions:' "$f" 2>/dev/null && RCOUNT=$((RCOUNT+1))
done
if present "$RECIPE"; then
  if [ "$RCOUNT" -eq 1 ]; then
    ok "exactly one recipe file in ${AGENT_DIR}/ (byte-identical runs)"
  else
    blocker "found ${RCOUNT} recipe-like files in ${AGENT_DIR}/ — must be exactly ONE"
  fi
  if bash scripts/check-recipe.sh >/dev/null 2>&1; then
    ok "recipe passes scripts/check-recipe.sh (pinned, temp 0, single gateway endpoint, no built-ins)"
  else
    blocker "recipe fails scripts/check-recipe.sh — run it for details"
  fi
fi

# --- INV 8: gateway policy: explicit http_post deny; no mcp.tool.arguments (BLOCKER)
if present "$GATEWAY_POLICY"; then
  if grep -qF 'mcp.tool.arguments' "$GATEWAY_POLICY"; then
    blocker "gateway policy references mcp.tool.arguments — denies ALL calls (agentgateway issue #3092)"
  else
    ok "gateway policy references no post-request-only field"
  fi
  if grep -qE "deny:.*${EXFIL_TOOL_NAME}|${EXFIL_TOOL_NAME}.*deny" "$GATEWAY_POLICY"; then
    ok "gateway explicitly denies '${EXFIL_TOOL_NAME}' (also filtered from tools/list — D6)"
  else
    blocker "gateway does not explicitly deny '${EXFIL_TOOL_NAME}'"
  fi
fi

# --- INV 9: cosign pinned to 2.6.x (BLOCKER) -------------------------------------
if present "$INSTALL_SCRIPT"; then
  PIN_LINE="$(grep -E '^[[:space:]]*COSIGN_VERSION=' "$INSTALL_SCRIPT" | head -1 || true)"
  if printf '%s' "$PIN_LINE" | grep -qE "COSIGN_VERSION=[\"']?v?${COSIGN_REQUIRED_LINE//./\\.}\.[0-9]+"; then
    ok "cosign pinned to the ${COSIGN_REQUIRED_LINE}.x line (${PIN_LINE## })"
  elif [ -n "$PIN_LINE" ]; then
    blocker "cosign pin is not ${COSIGN_REQUIRED_LINE}.x: '${PIN_LINE}'"
  else
    blocker "no COSIGN_VERSION= pin in ${INSTALL_SCRIPT}"
  fi
fi

# --- INV 10: no floating tags / latest (MAJOR) -----------------------------------
FLOAT_RE=':latest([^A-Za-z0-9.-]|$)|[A-Za-z0-9]-latest'
if grep -rnE "${DOC_EXCL[@]}" "$FLOAT_RE" . >/dev/null 2>&1; then
  major "floating tag(s) found (pin exact versions/digests):"
  grep -rnE "${DOC_EXCL[@]}" "$FLOAT_RE" . | sed 's/^/           /'
else
  ok "no :latest / *-latest floating tags in scanned files"
fi

# --- INV 11: readiness, not sleeps (MAJOR, review) -------------------------------
# A short poll inside a bounded loop is fine; its line says "poll".
SLEEP_HITS="$(grep -rnE "${DOC_EXCL[@]}" '(^|[^a-z])sleep[[:space:]]+[0-9]' \
     "$MAKEFILE" cluster registry controls agent scripts/reset.sh scripts/run-boundary.sh 2>/dev/null | grep -viE 'poll|# ok' || true)"
if [ -n "$SLEEP_HITS" ]; then
  major "sleep used as a wait — confirm each is a real readiness gate, not a timer:"
  printf '%s\n' "$SLEEP_HITS" | sed 's/^/           /'
else
  ok "no bare 'sleep' waits in Makefile/cluster/registry/controls/agent + reset/run-boundary scripts"
fi

# --- INV 12: CVEs mirrored honestly (MAJOR) --------------------------------------
if grep -niE 'CVE-[^ ]*MAL-2026-11069|MAL-2026-11069[^ ]*CVE|CVE.{0,12}tool.description.poison' DEMO-GUIDE.md README.md 2>/dev/null | grep -qiE 'CVE'; then
  major "MAL-/Microsoft item may be mislabeled as a CVE — check DEMO-GUIDE.md ('Why this is realistic')"
else
  ok "no obvious MAL-/disclosure-as-CVE mislabeling in DEMO-GUIDE.md / README.md"
fi

# --- INV 13: the demo's make targets exist (MAJOR) --------------------------------
MISS=""
for t in setup images up attack defend rerun reset down; do
  grep -qE "^${t}:" "$MAKEFILE" 2>/dev/null || MISS="${MISS} ${t}"
done
if [ -n "$MISS" ]; then major "Makefile missing target(s):${MISS}"
else ok "Makefile has setup/images/up/attack/defend/rerun/reset/down targets"; fi
for s in 1-setup 2-attack 3-defend 4-rerun 5-reset; do
  [ -x "$s" ] || major "numbered script ${s} missing or not executable"
done

# --- INV 14: goose pod hardening; key only via the runtime Secret (BLOCKER) -----
if present "$GOOSE_JOB"; then
  # Accept either secretRef (used now) or secretKeyRef.
  for pat in 'automountServiceAccountToken:[[:space:]]*false' 'runAsNonRoot:[[:space:]]*true' \
             'readOnlyRootFilesystem:[[:space:]]*true' 'RuntimeDefault' 'imagePullPolicy:[[:space:]]*Never' \
             'secretKeyRef|secretRef' 'GOOSE_DISABLE_KEYRING' "${MODEL_KEY_SECRET}"; do
    grep -qE -- "$pat" "$GOOSE_JOB" || blocker "${GOOSE_JOB} lacks '${pat}' — goose pod hardening (DEMO-GUIDE.md D1)"
  done
  if grep -qE 'drop:' "$GOOSE_JOB" && grep -qE -- '-[[:space:]]*"?ALL"?' "$GOOSE_JOB"; then
    ok "goose Job drops ALL capabilities"
  else
    blocker "${GOOSE_JOB} does not drop ALL capabilities"
  fi
  if grep -nE ':latest' "$GOOSE_JOB" >/dev/null 2>&1; then
    blocker "${GOOSE_JOB} uses a :latest image"
  fi
fi
# The key must never be added with --from-literal.
FROM_LITERAL="$(grep -rnE --exclude-dir=.git \
  --exclude='*.md' --exclude="$(basename "$0")" -- '--from-literal' . 2>/dev/null \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
if [ -n "$FROM_LITERAL" ]; then
  blocker "--from-literal used outside comments — create the model-key Secret with --from-file only:"
  printf '%s\n' "$FROM_LITERAL" | sed 's/^/           /'
else
  ok "no --from-literal Secret creation in code"
fi

# --- INV 15: tampered skill is inert and differs from the signed skill (BLOCKER) --
TAMPERED="${SKILL_TAMPERED_FILE}"; GOOD="${SKILL_DIR}/${SKILL_FILE}"
if present "$TAMPERED" && present "$GOOD"; then
  if cmp -s "$TAMPERED" "$GOOD"; then
    blocker "tampered skill is IDENTICAL to the signed skill — the tamper test would show nothing"
  elif ! bash scripts/check-inert.sh >/dev/null 2>&1; then
    blocker "attacker content fails scripts/check-inert.sh — run it for details"
  elif grep -qE 'https?://' "$TAMPERED" && grep -oE 'https?://[A-Za-z0-9._:-]+' "$TAMPERED" \
         | sed -E 's#https?://##; s#[:/].*##' | grep -qvE "^${ALLOWED_HOST_PATTERN}\$"; then
    blocker "tampered skill names a non-local host"
  else
    ok "tampered skill differs from the signed skill and names only local hosts"
  fi
fi

# --- INV 16: the always-on goose fence (BLOCKER) ---------------------------------
if present "$GOOSE_BASELINE_POLICY"; then
  for pat in "app: goose-agent" "namespace: ${AGENT_NS}" "kube-dns" "dns:" "toFQDNs" "__MODEL_API_FQDN__"; do
    grep -qF -- "$pat" "$GOOSE_BASELINE_POLICY" \
      || blocker "${GOOSE_BASELINE_POLICY} lacks '${pat}' — the goose fence is incomplete"
  done
  if awk '/^defend:/{f=1;next} /^[a-zA-Z0-9_-]+:/{f=0} f' "$MAKEFILE" | grep -qF 'GOOSE_BASELINE_POLICY'; then
    blocker "make defend touches the baseline goose fence — it must stay always-on"
  else
    ok "goose baseline fence present (selector, ns, DNS rule, model FQDN) and not part of make defend"
  fi
fi

# --- Rules only a live run can prove (never guessed as PASS) ------------------------
log "----------------------------------------"
unver "attack is genuine (real goose run, not scripted) — confirm with ./2-attack"
unver "legitimate task completes on run two (deliverable files present) — confirm with ./4-rerun"
unver "gateway probe shows ${EXFIL_TOOL_NAME} absent from tools/list AND a direct call refused — run controls/agentgateway/probe-deny.sh (make defend does)"
unver "Falco fires on the credential read (run one; run two only if the agent still reads it) — run scripts/smoke-test-falco.sh"
unver "ToolHive refuses the tampered skill — run skill-bundle/verify.sh tamper (make defend does)"
unver "exactly one model-api-key Secret, in ns agent only — run scripts/check-model-secret.sh"
unver "goose fence holds (DNS/gateway/model reachable; K8s API, kubelet, host, attacker hosts, other ns blocked) — run scripts/verify-goose-sandbox.sh"

log "----------------------------------------"
log "Findings: ${BLOCKERS} BLOCKER, ${MAJORS} MAJOR, ${NITS} NIT"
if [ "$BLOCKERS" -eq 0 ]; then
  if [ "$MAJORS" -gt 0 ]; then
    log "VERDICT: READY — no blockers, but fix the ${MAJORS} MAJOR item(s), and confirm the UNVERIFIED items with a live run."
  else
    log "VERDICT: READY — no blockers. Confirm the UNVERIFIED items with a live run."
  fi
  exit 0
else
  log "VERDICT: NOT-READY — ${BLOCKERS} blocker(s) must be fixed."
  exit 1
fi
