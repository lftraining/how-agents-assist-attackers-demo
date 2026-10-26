#!/usr/bin/env bash
#
# student-setup.sh — prepare the skill's supply chain: check the tools, create a throwaway
# signing key if there is none, start the local registry, and sign the skill. `make setup`
# and `make up` both run it, and a second run changes nothing.
set -euo pipefail
set +x   # never trace a script that handles a key

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
cd "$REPO_ROOT"

log() { printf '>> %s\n' "$*"; }
die() { printf 'FATAL %s\n' "$*" >&2; exit 1; }

# --- 1. Tools ------------------------------------------------------------------------
missing=""
for t in docker kind kubectl helm cilium cosign oras thv yq jq openssl curl git python3; do
  command -v "$t" >/dev/null 2>&1 || missing="${missing} ${t}"
done
[ -z "$missing" ] || die "missing tools:${missing} — run scripts/01-install-tools.sh and check ~/.local/bin is on PATH"
case "$(cosign version 2>/dev/null | grep -m1 GitVersion)" in
  *"v${COSIGN_REQUIRED_LINE}."*) : ;;
  *) die "cosign must be on the ${COSIGN_REQUIRED_LINE}.x line (3.x can hang offline) — run scripts/01-install-tools.sh" ;;
esac
log "tools present (cosign ${COSIGN_REQUIRED_LINE}.x)"

# --- 2. Throwaway signing key ----------------------------------------------------------
umask 077
mkdir -p "$DEMO_SECRETS_DIR"
chmod 0700 "$DEMO_SECRETS_DIR"
if [ -s "$COSIGN_KEY" ] && [ -s "$COSIGN_PUB" ]; then
  log "signing key already present in ${DEMO_SECRETS_DIR}/ (kept)"
elif [ -e "$COSIGN_KEY" ] || [ -e "$COSIGN_PUB" ]; then
  die "only half a key pair in ${DEMO_SECRETS_DIR}/ — remove cosign.key and cosign.pub there, then re-run"
else
  log "creating a throwaway cosign key pair in ${DEMO_SECRETS_DIR}/ (no password)"
  # An empty COSIGN_PASSWORD skips cosign's prompt.
  ( cd "$DEMO_SECRETS_DIR" && COSIGN_PASSWORD="" cosign generate-key-pair --output-key-prefix cosign >/dev/null 2>&1 ) \
    || die "cosign generate-key-pair failed"
  chmod 0600 "$COSIGN_KEY"
  chmod 0644 "$COSIGN_PUB"
fi

# --- 3. Registry -----------------------------------------------------------------------
bash registry/run-registry.sh

# --- 4. Package and sign -----------------------------------------------------------------
if [ "$TLOG_MODE" = "none" ] && [ -z "${COSIGN_PASSWORD_FILE:-}" ]; then
  COSIGN_PASSWORD="${COSIGN_PASSWORD-}" bash skill-bundle/package-and-sign.sh
else
  bash skill-bundle/package-and-sign.sh
fi
log "setup complete — key in ${DEMO_SECRETS_DIR}/, skill signed (${TLOG_MODE} mode). Next: make up"
