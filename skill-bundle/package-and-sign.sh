#!/usr/bin/env bash
# package-and-sign.sh — package the skill with ToolHive, push it to the local registry,
# and sign it by digest with your key. `make setup` runs it.
#
# Signing modes (TLOG_MODE in demo.env):
#   none  (default) Sign offline.
#   rekor (optional) Also record the signature in the public Rekor log. It restores a saved
#         signature instead of signing again, and needs RESIGN=1 to sign a second time.
set -euo pipefail
set +x   # belt and braces: never trace this script, whatever the caller did
# shellcheck source=../scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/lib/common.sh"
# shellcheck source=lib.sh
source "${REPO_ROOT}/skill-bundle/lib.sh"

sb_require_tools cosign oras thv curl python3
sb_cosign_guard
sb_registry_up
[ -s "$COSIGN_PUB" ] || sb_die "public key not found at ${COSIGN_PUB} — run: make setup"
case "$TLOG_MODE" in rekor|none) : ;; *) sb_die "TLOG_MODE must be rekor or none (got '${TLOG_MODE}')" ;; esac

trap sb_thv_down EXIT
sb_thv_up

LIVE_TAG_REF="${LIVE_REPO}:${SKILL_TAG}"
echo ">> packaging ${SKILL_DIR} with ToolHive (thv skill build) as ${LIVE_TAG_REF}"
# Build locally first.
DIGEST="$(sb_thv_build "${REPO_ROOT}/${SKILL_DIR}" "$LIVE_TAG_REF")" || sb_die "thv skill build failed"
echo "   built digest ${DIGEST} (local build store; registry not touched yet)"
SIGNED_REF="${LIVE_REPO}@${DIGEST}"
SIG_TAG="$(sb_sig_tag "$DIGEST")"

PREV="$(sb_recorded_digest || true)"
if [ -n "$PREV" ] && [ "$PREV" != "$DIGEST" ]; then
  echo "!! the packaged skill changed: recorded ${PREV}, now ${DIGEST}"
  echo "   (SKILL.md edited, or a different thv version packaged it)."
fi

# --- 1. Decide what to do, before touching the registry ------------------------------------
# PLAN is have (already signed), restore (rekor mode: put back a saved signature), or sign.
PLAN=sign
if sb_resolve "${LIVE_REPO}:${SIG_TAG}" >/dev/null; then
  if [ "$TLOG_MODE" = "rekor" ] && [ ! -s "$SB_REKOR_PUB" ]; then
    b="$(sb_rekor_bundle "$LIVE_REPO" "$DIGEST" || true)"
    [ -n "$b" ] && sb_pin_rekor_key "$b"
  fi
  if sb_cosign_verify "$SIGNED_REF" >/dev/null; then
    PLAN=have
  else
    # A signature exists, but not from your key.
    sb_cosign_verify "$SIGNED_REF" | tail -3 >&2 || true
    sb_die "a signature exists on ${SIGNED_REF} but does NOT verify with ${COSIGN_PUB} — investigate; not signing over it"
  fi
elif [ "$TLOG_MODE" = "rekor" ] && [ -f "${SB_BACKUP}/index.json" ] \
     && oras resolve --oci-layout "${SB_BACKUP}:${SIG_TAG}" >/dev/null 2>&1; then
  PLAN=restore
fi

if [ "$PLAN" = "sign" ] && [ "$TLOG_MODE" = "rekor" ]; then
  # Rekor mode only: signing again needs RESIGN=1.
  evidence=""
  if [ -n "$PREV" ] && [ -s "$SB_REKOR_PUB" ]; then evidence="${evidence} bundle.digest=${PREV:0:19}…;"; fi
  if [ -f "${SB_BACKUP}/index.json" ] && [ -n "$(oras repo tags --oci-layout "$SB_BACKUP" 2>/dev/null | grep -E '^sha256-.*\.sig$')" ]; then
    evidence="${evidence} saved signature(s) in ${SIGSTORE_RUNTIME_DIR};"
  fi
  if [ -n "$(oras repo tags "${ORAS_TLS[@]}" "$LIVE_REPO" 2>/dev/null | grep -E '^sha256-.*\.sig$')" ]; then
    evidence="${evidence} signature tag(s) in ${SKILL_REPO};"
  fi
  n="$(sb_rekor_entries_for_key || true)"
  if [ -n "$n" ] && [ "$n" -gt 0 ]; then evidence="${evidence} ${n} Rekor entr(y/ies) under cosign.pub;"; fi
  if [ -n "$evidence" ] && [ "${RESIGN:-0}" != "1" ]; then
    echo "!! ${DIGEST} is not signed, but this project has signed before:${evidence}" >&2
    sb_die "refusing to create a SECOND permanent Rekor entry without RESIGN=1. The live tag was NOT touched. Re-run: RESIGN=1 $0"
  fi
fi
if [ "$PLAN" = "sign" ]; then
  [ -s "$COSIGN_KEY" ] || sb_die "private key not found at ${COSIGN_KEY} — run: make setup (live tag NOT touched)"
  if [ -z "${COSIGN_PASSWORD_FILE:-}" ] && [ -z "${COSIGN_PASSWORD+x}" ] && [ ! -t 0 ]; then
    sb_die "no terminal for the password prompt — run interactively, or set COSIGN_PASSWORD_FILE (0600, outside the repo). Live tag NOT touched."
  fi
fi

# --- 2. Push --------------------------------------------------------------------------------
CUR="$(sb_resolve "$LIVE_TAG_REF" || true)"
if [ "$CUR" = "$DIGEST" ]; then
  echo ">> registry already holds ${LIVE_TAG_REF} -> ${DIGEST}; not re-pushing"
else
  if [ -n "$CUR" ]; then
    echo "!! ${LIVE_TAG_REF} pointed at ${CUR}, not the packaged ${DIGEST}."
    echo "   Re-pointing the tag at the reviewed content (consumers install by digest regardless)."
  fi
  echo ">> pushing to ${LIVE_TAG_REF} (pushed unsigned; the signature is attached next, D8)"
  thvc skill push "$LIVE_TAG_REF" --no-sign >/dev/null
fi
# Best effort; ToolHive v0.54 cannot remove builds whose tag contains '/'.
thvc skill builds remove "$LIVE_TAG_REF" >/dev/null 2>&1 || true
GOT="$(sb_resolve "$LIVE_TAG_REF" || true)"
[ "$GOT" = "$DIGEST" ] || sb_die "after push ${LIVE_TAG_REF} resolves to '${GOT}', not the built ${DIGEST}"
TYPE="$(oras manifest fetch "${ORAS_TLS[@]}" "$SIGNED_REF" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("artifactType",""))')"
[ "$TYPE" = "$ARTIFACT_TYPE" ] || sb_die "pushed artifactType '${TYPE}' != expected '${ARTIFACT_TYPE}' (ToolHive format changed?)"

backup_signature() {
  # Rekor mode: save a copy of the signature.
  mkdir -p "$SB_SIGSTORE_DIR"
  oras cp --from-plain-http=false --from-ca-file "$SB_CA_CRT" \
    "${LIVE_REPO}:${SIG_TAG}" --to-oci-layout "${SB_BACKUP}:${SIG_TAG}" >/dev/null
}

# --- 3. Sign or restore ----------------------------------------------------------------------
case "$PLAN" in
have)
  echo ">> already signed: ${SIGNED_REF} has a valid signature from ${COSIGN_PUB} — not re-signing" ;;
restore)
  echo ">> registry has no signature for ${DIGEST}; restoring the saved one (no re-sign, no new Rekor entry)"
  oras cp --from-oci-layout "${SB_BACKUP}:${SIG_TAG}" --to-plain-http=false --to-ca-file "$SB_CA_CRT" \
    "${LIVE_REPO}:${SIG_TAG}" >/dev/null
  if [ "$TLOG_MODE" = "rekor" ] && [ ! -s "$SB_REKOR_PUB" ]; then sb_pin_rekor_key "$(sb_rekor_bundle "$LIVE_REPO" "$DIGEST" || true)"; fi
  sb_cosign_verify "$SIGNED_REF" >/dev/null || sb_die "restored signature does not verify with ${COSIGN_PUB}" ;;
sign)
  if [ "$TLOG_MODE" = "rekor" ]; then
    TLOG_FLAG=--tlog-upload=true
    echo ">> signing ${SIGNED_REF} ONCE with ${COSIGN_KEY}; uploading to the PUBLIC Rekor log (${REKOR_URL})"
    echo "   NOTE: cosign runs with --yes, which auto-accepts its Sigstore terms-of-use / public-log"
    echo "   attestation prompt. The entry is permanent and public (public key, artifact hash,"
    echo "   signature, timestamp; no name or email). Ctrl-C now if you do not agree."
  else
    TLOG_FLAG=--tlog-upload=false
    echo ">> signing ${SIGNED_REF} with ${COSIGN_KEY}, offline (no public log entry)"
  fi
  # --yes accepts cosign's prompts; in rekor mode the script prints a notice first.
  SIGN=(cosign sign --key "$COSIGN_KEY" "$TLOG_FLAG" --yes --recursive=false
        --new-bundle-format=false --use-signing-config=false "$SIGNED_REF")
  if [ -n "${COSIGN_PASSWORD_FILE:-}" ]; then
    pwf="$COSIGN_PASSWORD_FILE"
    [ -f "$pwf" ] || sb_die "COSIGN_PASSWORD_FILE does not exist"
    case "$(cd "$(dirname "$pwf")" && pwd)/" in "${REPO_ROOT}/"*) sb_die "COSIGN_PASSWORD_FILE must live OUTSIDE the repo" ;; esac
    [ "$(stat -c '%a' "$pwf")" = "600" ] || sb_die "COSIGN_PASSWORD_FILE must be mode 0600"
    # Passed to cosign's environment only.
    COSIGN_PASSWORD="$(cat "$pwf")" "${SIGN[@]}"
  elif [ -n "${COSIGN_PASSWORD+x}" ]; then
    "${SIGN[@]}"                    # caller chose to export it; cosign reads it
  else
    echo "   cosign will prompt for the key password (input hidden)"
    "${SIGN[@]}"                    # cosign prompts on the terminal itself (TTY checked above)
  fi
  if [ "$TLOG_MODE" = "rekor" ]; then
    b="$(sb_rekor_bundle "$LIVE_REPO" "$DIGEST" || true)"
    [ -n "$b" ] || sb_die "signed, but no Rekor bundle is attached — was the upload skipped?"
    sb_pin_rekor_key "$b"
  fi
  out="$(sb_cosign_verify "$SIGNED_REF")" || { printf '%s\n' "$out" | tail -3 >&2; sb_die "fresh signature does not verify offline"; } ;;
esac

# Signing must not change the artifact the tag points to.
[ "$(sb_resolve "$LIVE_TAG_REF")" = "$DIGEST" ] || sb_die "the live tag moved during signing"
if [ "$TLOG_MODE" = "rekor" ]; then backup_signature; fi
printf '%s\n' "$DIGEST" > "$DIGEST_FILE"

if [ "$TLOG_MODE" = "rekor" ]; then
  sb_rekor_bundle "$LIVE_REPO" "$DIGEST" | python3 -c '
import json, sys
p = json.load(sys.stdin)["Payload"]
print("   Rekor log index %s (integrated %s)" % (p["logIndex"], p["integratedTime"]))
print("   browse: %s/?logIndex=%s" % (sys.argv[1], p["logIndex"]))
' "$REKOR_SEARCH_URL"
fi
echo "PASS  ${SKILL_NAME} packaged (ToolHive format), signed by digest, recorded in ${SKILL_DIGEST_FILE}: ${DIGEST}"
