#!/usr/bin/env bash
# install-skill.sh — install the skill with ToolHive, by digest, only if its signature
# verifies against your public key. `make up` runs it, and both runs load this skill.
set -euo pipefail
# shellcheck source=../scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/lib/common.sh"
# shellcheck source=lib.sh
source "${REPO_ROOT}/skill-bundle/lib.sh"

sb_require_tools thv oras git curl python3
sb_registry_up
[ -s "$COSIGN_PUB" ] || sb_die "public key not found at ${COSIGN_PUB}"
DIGEST="$(sb_recorded_digest || true)"
[ -n "$DIGEST" ] || sb_die "no recorded digest at ${SKILL_DIGEST_FILE} — run: make setup"

# A moved tag means someone re-pushed the skill, so install nothing.
LIVE="$(sb_resolve "${LIVE_REPO}:${SKILL_TAG}" || true)"
[ "$LIVE" = "$DIGEST" ] || sb_die "live tag ${LIVE_REPO}:${SKILL_TAG} -> '${LIVE}', but the signed digest is ${DIGEST} — treat as tampered"

mkdir -p "$GOOSE_PROJECT_ABS"
if [ ! -d "${GOOSE_PROJECT_ABS}/.git" ]; then
  git init -q "$GOOSE_PROJECT_ABS"
fi

trap sb_thv_down EXIT
sb_thv_up

# Start from nothing: remove this skill's folder and the lock file.
thvc skill uninstall "$SKILL_NAME" --scope project --project-root "$GOOSE_PROJECT_ABS" >/dev/null 2>&1 || true
rm -rf "${GOOSE_PROJECT_ABS}/.claude/skills/${SKILL_NAME}"
rm -f "${GOOSE_PROJECT_ABS}/toolhive.lock.yaml"

REF="${LIVE_REPO}@${DIGEST}"
echo ">> ToolHive verify-before-load: installing ${REF}"
echo "   into ${GOOSE_PROJECT_DIR}/.claude/skills/ (must verify against ${COSIGN_PUB})"
thvc skill install "$REF" --scope project --project-root "$GOOSE_PROJECT_ABS" \
  --clients claude-code --public-key "$COSIGN_PUB" --force

INSTALLED="${GOOSE_PROJECT_ABS}/.claude/skills/${SKILL_NAME}/${SKILL_FILE}"
[ -s "$INSTALLED" ] || sb_die "ToolHive reported success but ${INSTALLED} is missing"
# Compare the installed copy with the repo source.
cmp -s "$INSTALLED" "${REPO_ROOT}/${SKILL_DIR}/${SKILL_FILE}" \
  || sb_die "installed ${SKILL_FILE} differs from ${SKILL_DIR}/${SKILL_FILE} — re-run: make setup"
LOCKD="$(sb_lock_digest "$GOOSE_PROJECT_ABS")"
[ "$LOCKD" = "$DIGEST" ] || sb_die "lock file records '${LOCKD}', expected signed ${DIGEST}"
echo "PASS  ToolHive verified ${SKILL_NAME}@${DIGEST} against cosign.pub and installed it at ${GOOSE_PROJECT_DIR}/.claude/skills/${SKILL_NAME}/"
