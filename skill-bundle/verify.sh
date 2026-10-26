#!/usr/bin/env bash
#
# verify.sh — show the skill's verify-before-load step working.
#
#   check   (read-only; `make defend` runs it) The tag still points at the signed digest,
#           cosign verifies the signature offline, and the installed skill matches it.
#   tamper  (`make defend`) A tampered copy, carrying the genuine signature, is published
#           to a scratch repository. cosign and ToolHive must both refuse it.
#   full    (`make verify`) check, tamper, and offline. The real offline proof needs
#           ASSUME_OFFLINE=1 and no internet connection.
#   rekor   (`make verify-rekor`, rekor mode only) The public Rekor log holds exactly
#           this signature, under your key.

set -uo pipefail   # not -e: run every check and report every result

# shellcheck source=../scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/lib/common.sh"
# shellcheck source=lib.sh
source "${REPO_ROOT}/skill-bundle/lib.sh"

MODE="${1:-check}"
ASSUME_OFFLINE="${ASSUME_OFFLINE:-0}"

FAILED=0
log()  { printf '%s\n' "$*"; }
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILED=1; }
show() { sed 's/^/        | /'; }   # indent a tool's own words under the verdict

case "$MODE" in check|tamper|full|rekor) : ;; *) log "usage: $0 [check|tamper|full|rekor]"; exit 2 ;; esac

sb_cosign_guard                  # exits on a non-2.6.x cosign
sb_require_tools cosign oras curl python3
case "$MODE" in tamper|full) sb_require_tools thv git ;; esac
sb_registry_up
[ -s "$COSIGN_PUB" ] || { fail "public key not found at ${COSIGN_PUB}"; exit 1; }
EXPECTED="$(sb_recorded_digest || true)"
TMPS=()
cleanup() { sb_thv_down; [ "${#TMPS[@]}" -gt 0 ] && rm -rf "${TMPS[@]}"; return 0; }
trap cleanup EXIT

# Show cosign's summary of what it checked, without the JSON payload.
cosign_reasons() { grep -E '^(Verification for|  - |Error:)' | grep -v '^error during' ; }

# --- check: digest, signature, and installed copy (read-only) --------------------------
run_check() {
  log "--- check: the skill goose loads is the one that was signed"
  if [ -z "$EXPECTED" ]; then
    fail "no recorded digest at ${SKILL_DIGEST_FILE} — run: make setup"
    return
  fi
  local live out installed lockd
  live="$(sb_resolve "${LIVE_REPO}:${SKILL_TAG}" || true)"
  if [ -z "$live" ]; then
    fail "cannot resolve ${LIVE_REPO}:${SKILL_TAG} (bundle not pushed?)"
  elif [ "$live" = "$EXPECTED" ]; then
    pass "live tag ${SKILL_REPO}:${SKILL_TAG} still points at the signed digest ${EXPECTED}"
  else
    fail "live tag MOVED: ${SKILL_REPO}:${SKILL_TAG} -> ${live}, signed ${EXPECTED} — treat as tampered; do not load"
  fi
  # Always use the digest, never the tag.
  if out="$(sb_cosign_verify "${LIVE_REPO}@${EXPECTED}")"; then
    pass "cosign: signature on ${SKILL_REPO}@${EXPECTED:0:19}... verifies against cosign.pub (no network used)"
    printf '%s\n' "$out" | cosign_reasons | show
  else
    fail "cosign: signature does NOT verify for the recorded digest"
    printf '%s\n' "$out" | tail -3 | show
  fi
  installed="${GOOSE_PROJECT_ABS}/.claude/skills/${SKILL_NAME}/${SKILL_FILE}"
  if [ ! -s "$installed" ]; then
    fail "no installed skill at ${GOOSE_PROJECT_DIR}/.claude/skills/${SKILL_NAME}/ — run skill-bundle/install-skill.sh"
    return
  fi
  if cmp -s "$installed" <(sb_artifact_skill_md "$LIVE_REPO" "$EXPECTED"); then
    pass "installed skill (${GOOSE_PROJECT_DIR}/.claude/skills/${SKILL_NAME}/) is byte-identical to the signed artifact"
  else
    fail "installed skill differs from the signed artifact — re-run skill-bundle/install-skill.sh"
  fi
  lockd="$(sb_lock_digest "$GOOSE_PROJECT_ABS")"
  if [ "$lockd" = "$EXPECTED" ]; then
    pass "ToolHive lock file pins ${SKILL_NAME} to the signed digest (signed, not an unsigned exception)"
  else
    fail "ToolHive lock file records '${lockd:-nothing}', expected ${EXPECTED}"
  fi
  # ToolHive must have pinned your key.
  if [ "$(sb_lock_pubkey "$GOOSE_PROJECT_ABS")" = "$(grep -v -- '-----' "$COSIGN_PUB" | tr -d '[:space:]')" ]; then
    pass "ToolHive pinned exactly our cosign.pub as this skill's trust anchor"
  else
    fail "ToolHive's pinned public key is NOT our cosign.pub"
  fi
}

# --- tamper: scratch repository only ------------------------------------------------------
# Hash every file in the live skills folder, to prove the tamper attempt changed nothing.
skills_fingerprint() {
  (cd "$GOOSE_PROJECT_ABS" 2>/dev/null && find .claude -type f -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum) | sha256sum
}

run_tamper() {
  log "--- tamper: an attacker-modified copy of the skill is published"
  local src="${REPO_ROOT}/${SKILL_TAMPERED_FILE}" td out rc proj before after
  # Guards.
  if [ "$SKILL_TAMPER_REPO" = "$SKILL_REPO" ]; then fail "SKILL_TAMPER_REPO equals SKILL_REPO — refusing to touch the live repo"; return; fi
  if [ "${SKILL_TAMPER_REPO##*/}" != "$SKILL_NAME" ]; then fail "SKILL_TAMPER_REPO must end in /${SKILL_NAME} (ToolHive name rule) or the refusal would not be about the signature"; return; fi
  if [ ! -f "$src" ]; then fail "tampered skill not found: ${SKILL_TAMPERED_FILE}"; return; fi
  if [ -z "$EXPECTED" ]; then fail "no recorded digest — sign the good skill first (make setup)"; return; fi
  # First, the same key must accept the genuine skill.
  if ! sb_cosign_verify "${LIVE_REPO}@${EXPECTED}" >/dev/null; then
    fail "control: the GENUINE skill does not verify with ${COSIGN_PUB} — a refusal would prove nothing"; return
  fi
  log "      control: the genuine skill verifies with this key"
  log "      what the attacker changed (good -> tampered):"
  diff <(grep -v '^\s*$' "${REPO_ROOT}/${SKILL_DIR}/${SKILL_FILE}") <(grep -v '^\s*$' "$src") \
    | grep -E '^[<>] .*registry=' | sed 's/^</        - /; s/^>/        + /'
  if [ ! -s "${GOOSE_PROJECT_ABS}/.claude/skills/${SKILL_NAME}/${SKILL_FILE}" ]; then
    fail "no installed skill at ${GOOSE_PROJECT_DIR}/.claude/skills/${SKILL_NAME}/ — run skill-bundle/install-skill.sh first (the tamper test must show it untouched)"
    return
  fi
  before="$(skills_fingerprint)"

  sb_thv_up
  # Package it exactly like the real skill.
  td="$(sb_thv_build "$src" "${TAMPER_REPO}:${SKILL_TAG}")" || { fail "thv skill build failed for the tampered skill"; return; }
  if [ "$td" = "$EXPECTED" ]; then
    thvc skill builds remove "${TAMPER_REPO}:${SKILL_TAG}" >/dev/null 2>&1 || true
    fail "tampered skill has the SAME digest as the signed one — nothing was tampered"; return
  fi
  if ! thvc skill push "${TAMPER_REPO}:${SKILL_TAG}" --no-sign >/dev/null; then
    fail "could not push the tampered skill to the scratch repo"; return
  fi
  thvc skill builds remove "${TAMPER_REPO}:${SKILL_TAG}" >/dev/null 2>&1 || true
  log "      published to SCRATCH repo ${SKILL_TAMPER_REPO}@${td:0:19}... (live repo untouched)"
  # Copy the publisher's real signature onto the tampered copy.
  if oras cp "${ORAS_CP_TLS[@]}" "${LIVE_REPO}:$(sb_sig_tag "$EXPECTED")" \
       "${TAMPER_REPO}:$(sb_sig_tag "$td")" >/dev/null 2>&1; then
    log "      and copied the publisher's genuine signature onto it"
  else
    fail "could not copy the genuine signature onto the tampered digest (is the good skill signed?)"; return
  fi

  out="$(sb_cosign_verify "${TAMPER_REPO}@${td}")"; rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "cosign VERIFIED the tampered skill — the signature gate is not working"
  elif printf '%s' "$out" | grep -qiE 'digest in claim'; then
    pass "cosign REJECTS the tampered skill: the signature does not cover these bytes"
    printf '%s\n' "$out" | grep -m1 -E '^Error:' | show
  else
    fail "cosign failed, but NOT for a signature reason — check registry/key: ${out:0:200}"
  fi

  proj="$(mktemp -d)"; TMPS+=("$proj")
  git init -q "$proj"
  # Install into a throwaway folder.
  out="$(thvc skill install "${TAMPER_REPO}@${td}" --scope project --project-root "$proj" \
           --clients claude-code --public-key "$COSIGN_PUB" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "ToolHive INSTALLED the tampered skill — verify-before-load is not enforcing"
  elif [ -n "$(find "$proj" -name "$SKILL_FILE" -not -path '*/.git/*' 2>/dev/null)" ]; then
    fail "ToolHive reported failure but a ${SKILL_FILE} landed in the project — check the install path"
  elif printf '%s' "$out" | grep -qiE 'signature does not bind|signature covers'; then
    pass "ToolHive REFUSES to install the tampered skill (signature does not bind); nothing installed"
    printf '%s\n' "$out" | sed 's/^Error: failed to install skill: //' | fold -s -w 96 | show
  else
    fail "ToolHive refused, but NOT for a signature reason — check registry/key/format: ${out:0:200}"
  fi
  after="$(skills_fingerprint)"
  if [ "$before" = "$after" ]; then
    pass "the agent's skills dir (${GOOSE_PROJECT_DIR}/.claude/skills/) is unchanged"
  else
    fail "the agent's skills dir CHANGED during the tamper test"
  fi
}

# --- offline: the same verification without the internet --------------------------------
# Send outside HTTPS to a dead proxy, with a time limit.
# shellcheck disable=SC2054  # the commas are inside NO_PROXY values, not separators
BLACKHOLE=(timeout 60 env HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9
           https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9
           NO_PROXY=localhost,127.0.0.1 no_proxy=localhost,127.0.0.1)

run_offline() {
  log "--- offline: verification does not depend on the network"
  [ -n "$EXPECTED" ] || { fail "no recorded digest"; return; }
  local ref="${LIVE_REPO}@${EXPECTED}" out proj rc
  # A quick check that cosign does not reach for the internet.
  SB_WRAP=("${BLACKHOLE[@]}")
  out="$(sb_cosign_verify "$ref")"; rc=$?
  # shellcheck disable=SC2034  # SB_WRAP is read by sb_cosign_verify (lib.sh)
  SB_WRAP=()
  if [ "$rc" -eq 0 ]; then
    pass "pre-check (external HTTPS black-holed): cosign verifies with no Rekor/TUF access"
  else
    fail "pre-check: cosign needed the network — check TLOG_MODE (and, in rekor mode, the pinned Rekor key)"
    printf '%s\n' "$out" | tail -3 | show
  fi
  if [ "$ASSUME_OFFLINE" != "1" ]; then
    log "SKIP  real offline proof — disconnect this machine from the internet and re-run with ASSUME_OFFLINE=1"
    return
  fi
  # Check the ASSUME_OFFLINE=1 claim.
  if curl -s -m 5 -o /dev/null "$REKOR_URL" 2>/dev/null; then
    fail "ASSUME_OFFLINE=1 but ${REKOR_URL} is reachable — the external network is UP; disconnect it first"
    return
  fi
  log "      external network confirmed down (${REKOR_URL} unreachable)"
  SB_WRAP=(timeout 60)
  out="$(sb_cosign_verify "$ref")"; rc=$?
  # shellcheck disable=SC2034  # SB_WRAP is read by sb_cosign_verify (lib.sh)
  SB_WRAP=()
  if [ "$rc" -eq 0 ]; then
    if [ "$TLOG_MODE" = "rekor" ]; then
      pass "OFFLINE: cosign verifies the signature and its stored Rekor inclusion proof"
    else
      pass "OFFLINE: cosign verifies the signature against cosign.pub"
    fi
  else
    fail "OFFLINE: cosign verify failed or hung — check the 2.6.x pin, flags and TLOG_MODE"
    printf '%s\n' "$out" | tail -3 | show
  fi
  proj="$(mktemp -d)"; TMPS+=("$proj"); git init -q "$proj"
  sb_thv_up
  if out="$(thvc skill install "$ref" --scope project \
             --project-root "$proj" --clients claude-code --public-key "$COSIGN_PUB" 2>&1)" \
     && cmp -s "${proj}/.claude/skills/${SKILL_NAME}/${SKILL_FILE}" "${REPO_ROOT}/${SKILL_DIR}/${SKILL_FILE}"; then
    pass "OFFLINE: ToolHive verifies and installs the signed skill (the make-up gate works without internet)"
  else
    fail "OFFLINE: ToolHive could not verify/install the signed skill"
    printf '%s\n' "$out" | tail -3 | show
  fi
}

# --- rekor: the public log holds exactly this signature (needs internet) ------------------
run_rekor() {
  log "--- rekor: the signature is recorded in the public transparency log"
  [ -n "$EXPECTED" ] || { fail "no recorded digest — run: make setup"; return; }
  if [ "$TLOG_MODE" = "none" ]; then fail "TLOG_MODE=none (the default): this signature was made offline — there is no public entry to show. See the advanced signing exercise for rekor mode."; return; fi
  local bundle entry rc out
  bundle="$(sb_rekor_bundle "$LIVE_REPO" "$EXPECTED" || true)"
  [ -n "$bundle" ] || { fail "no Rekor bundle attached to the signature"; return; }
  entry="$(printf '%s' "$bundle" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Payload"]["logIndex"])')"
  # Exit codes: 0 match, 3 unreachable, anything else a mismatch.
  out="$(curl -fsS -m 15 "${REKOR_URL}/api/v1/log/entries?logIndex=${entry}" 2>/dev/null \
    | python3 -c '
import base64, json, sys
try:
    live = json.load(sys.stdin)
except Exception:
    sys.exit(3)
bundle = json.loads(sys.argv[1])["Payload"]
pub = open(sys.argv[2]).read().strip()
(uuid, e), = live.items()
body = json.loads(base64.b64decode(e["body"]))
logged_pub = base64.b64decode(body["spec"]["signature"]["publicKey"]["content"]).decode().strip()
ok = (e["body"] == bundle["body"] and e["logID"] == bundle["logID"]
      and e["integratedTime"] == bundle["integratedTime"])
print("uuid %s  logIndex %s  integratedTime %s" % (uuid, e["logIndex"], e["integratedTime"]))
if not ok:
    print("live entry differs from the bundle stored with the signature"); sys.exit(1)
if logged_pub != pub:
    print("entry is logged under a DIFFERENT public key than cosign.pub"); sys.exit(2)
' "$bundle" "$COSIGN_PUB")"; rc=$?
  case "$rc" in
    0) pass "public Rekor log holds exactly this signature, logged under our cosign.pub"
       printf '%s\n' "$out" | show
       log "        browse: ${REKOR_SEARCH_URL}/?logIndex=${entry}" ;;
    3) fail "Rekor unreachable (no internet?) — the offline proof still works: verify.sh check" ;;
    *) fail "Rekor entry does NOT match: ${out}" ;;
  esac
  # One signature makes one public entry.
  local n; n="$(sb_rekor_entries_for_key || true)"
  if [ "$n" = "1" ]; then
    pass "Rekor indexes exactly 1 entry under our cosign.pub (signed once)"
  elif [ -n "$n" ]; then
    log "NOTE  Rekor indexes ${n} entries under our cosign.pub — expected 1 unless RESIGN=1 was used deliberately"
  fi
  # Finally, cosign's own online verification.
  if out="$(cosign verify --key "$COSIGN_PUB" "${LIVE_REPO}@${EXPECTED}" 2>&1)"; then
    pass "cosign online verify (live trust root) passes"
  else
    fail "cosign online verify failed"; printf '%s\n' "$out" | tail -2 | show
  fi
}

log "=== skill-bundle verify (mode: ${MODE}) ==="
case "$MODE" in
  check)   run_check ;;
  tamper)  run_tamper ;;
  full)    run_check; run_tamper; run_offline ;;
  rekor)   run_rekor ;;
esac

log "----------------------------------------"
if [ "$FAILED" -eq 0 ]; then
  log "ALL CHECKS PASSED (${MODE})."
  exit 0
else
  log "ONE OR MORE CHECKS FAILED (${MODE}) — do not load the bundle; fix the FAIL lines (cosign's own reason is shown under each)."
  exit 1
fi
