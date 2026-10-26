#!/usr/bin/env bash
#
# run-task.sh — run the goose agent once. Both runs use it unchanged; only the controls
# differ between them. It deletes the previous Job, clears the workspace (keeping the
# decoy), rebuilds the recipe, skill, and vendor ConfigMaps, then runs the Job and streams
# its log.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/lib/common.sh"

require_set GOOSE_JOB_NAME
require_set GOOSE_JOB_MANIFEST
require_set DELIVERABLE_DIR
require_set FS_WORKSPACE
require_set DECOY_CRED_PATH
MANIFEST="${REPO_ROOT}/${GOOSE_JOB_MANIFEST}"
RECIPE_FILE="${REPO_ROOT}/${RECIPE}"
# The skill comes from ToolHive's verified install.
SKILL_SRC="${REPO_ROOT}/${GOOSE_PROJECT_DIR}/.claude/skills/${SKILL_NAME}/${SKILL_FILE}"
RECIPE_CM="goose-recipe"
SKILL_CM="goose-skill"
RUN_TIMEOUT="${RUN_TIMEOUT:-480s}"

# --- Preconditions ---------------------------------------------------------------
if ! kc -n "$AGENT_NS" get secret "$MODEL_KEY_SECRET" >/dev/null 2>&1; then
  echo "FATAL the model-key Secret '${MODEL_KEY_SECRET}' is missing in ns ${AGENT_NS}." >&2
  echo "      The USER must create it first (their terminal holds MODEL_KEY_FILE):" >&2
  echo "        make model-secret" >&2
  exit 1
fi
[ -f "$RECIPE_FILE" ] || { echo "FATAL recipe not found: $RECIPE_FILE" >&2; exit 1; }
if [ ! -f "$SKILL_SRC" ]; then
  echo "FATAL verified skill not found: $SKILL_SRC" >&2
  echo "      Run 'bash skill-bundle/install-skill.sh' (part of make up) first (D13)." >&2
  exit 1
fi

# --- 1. Delete the previous Job ----------------------------------------------------
echo ">> run-task: deleting any previous Job ${GOOSE_JOB_NAME} in ns ${AGENT_NS}"
kc -n "$AGENT_NS" delete job "$GOOSE_JOB_NAME" --ignore-not-found --wait=true

# --- 2. Clear the workspace, keeping only the decoy ----------------------------------
DECOY_REL="${DECOY_CRED_PATH#"${FS_WORKSPACE%/}"/}"   # .aws/credentials
DECOY_TOP="${DECOY_REL%%/*}"                          # .aws (the subPath mount's dir)
echo ">> run-task: wiping ${FS_WORKSPACE} inside mcp-fs (keeping only the decoy '${DECOY_TOP}')"
kc -n "$DEMO_NS" rollout status deploy/"$MCP_FS_DEPLOY" --timeout="$TIMEOUT"
FS_POD="$(kc -n "$DEMO_NS" get pod -l app="$MCP_FS_DEPLOY" -o jsonpath='{.items[0].metadata.name}')"
# Delete every top-level entry except the decoy's folder.
kc -n "$DEMO_NS" exec "$FS_POD" -- \
  find "$FS_WORKSPACE" -mindepth 1 -maxdepth 1 ! -name "$DECOY_TOP" -exec rm -rf {} +

# --- 3. Rebuild the recipe, skill, and goose-env ConfigMaps --------------------------
echo ">> run-task: (re)building ConfigMaps ${RECIPE_CM} (recipe), ${SKILL_CM} (verified skill), goose-env (provider/model)"
kc -n "$AGENT_NS" create configmap "$RECIPE_CM" \
  --from-file=recipe.yaml="$RECIPE_FILE" \
  --dry-run=client -o yaml | kc apply -f -
# The key must be SKILL.md, the file name goose expects.
kc -n "$AGENT_NS" create configmap "$SKILL_CM" \
  --from-file="${SKILL_FILE}=${SKILL_SRC}" \
  --dry-run=client -o yaml | kc apply -f -
# Your vendor's provider and model, which the Job reads as environment variables. The key is
# not here; it comes from its own Secret.
require_set MODEL_PROVIDER
require_set MODEL_ID
kc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: goose-env
  namespace: ${AGENT_NS}
data:
  GOOSE_PROVIDER: "${MODEL_PROVIDER}"
  GOOSE_MODEL: "${MODEL_ID}"
EOF

# --- 4. Run the Job and stream its log ---------------------------------------------------
echo ">> run-task: creating Job ${GOOSE_JOB_NAME}"
kc -n "$AGENT_NS" apply -f "$MANIFEST"

# Wait for the pod to start, then stream its log until it ends.
echo ">> run-task: streaming goose logs (follow) ..."
# A safety net: mask anything shaped like an OpenRouter key. No key should ever appear here.
kc -n "$AGENT_NS" logs -f job/"$GOOSE_JOB_NAME" --pod-running-timeout="$TIMEOUT" 2>/dev/null \
  | sed -E 's/sk-or-[A-Za-z0-9._-]+/sk-or-REDACTED/g' || true

# Wait for Complete or Failed, whichever comes first.
set +e
kc -n "$AGENT_NS" wait --for=condition=complete job/"$GOOSE_JOB_NAME" --timeout="$RUN_TIMEOUT" >/dev/null 2>&1 &
WAIT_OK=$!
kc -n "$AGENT_NS" wait --for=condition=failed   job/"$GOOSE_JOB_NAME" --timeout="$RUN_TIMEOUT" >/dev/null 2>&1 &
WAIT_FAIL=$!
wait -n "$WAIT_OK" "$WAIT_FAIL" 2>/dev/null
# Cancel the other wait.
kill "$WAIT_OK" "$WAIT_FAIL" 2>/dev/null
wait "$WAIT_OK" "$WAIT_FAIL" 2>/dev/null
set -e

COMPLETE="$(kc -n "$AGENT_NS" get job "$GOOSE_JOB_NAME" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null)"
if [ "$COMPLETE" = "True" ]; then
  echo ">> run-task: goose Job COMPLETED."
  exit 0
fi

# The Job failed or timed out: show the end of its log and its status.
echo ">> run-task: goose Job did NOT complete — pod log tail + status:" >&2
POD="$(kc -n "$AGENT_NS" get pod -l app=goose-agent --sort-by=.metadata.creationTimestamp \
         -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null)"
if [ -n "$POD" ]; then
  # The same safety-net mask as above.
  kc -n "$AGENT_NS" logs "$POD" --tail=40 2>/dev/null | sed -E 's/sk-or-[A-Za-z0-9._-]+/sk-or-REDACTED/g' >&2 || true
fi
kc -n "$AGENT_NS" get job "$GOOSE_JOB_NAME" -o wide >&2 || true
kc -n "$AGENT_NS" describe job "$GOOSE_JOB_NAME" 2>/dev/null | tail -12 >&2 || true
exit 1
