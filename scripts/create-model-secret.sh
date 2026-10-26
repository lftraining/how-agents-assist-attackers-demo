#!/usr/bin/env bash
#
# create-model-secret.sh — create or replace the model-key Secret from your key file. Run it
# yourself with `make model-secret`; `make up` runs it too. It never prints the key.

set -euo pipefail
set +x   # never trace a script that handles the key

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ">> auditing the key file (scripts/check-model-key.sh)..."
if ! bash "$SCRIPTS_DIR/check-model-key.sh"; then
  echo "FAIL  key file audit failed — fix the FAIL lines above, then re-run (make model-secret)." >&2
  exit 1
fi

kc get namespace "$AGENT_NS" >/dev/null 2>&1 \
  || { echo "FAIL  namespace '$AGENT_NS' does not exist — apply cluster/namespaces.yaml first." >&2; exit 1; }

echo ">> (re)creating Secret ${AGENT_NS}/${MODEL_KEY_SECRET} from \$MODEL_KEY_FILE (value not shown)..."
kc -n "$AGENT_NS" delete secret "$MODEL_KEY_SECRET" --ignore-not-found >/dev/null
kc -n "$AGENT_NS" create secret generic "$MODEL_KEY_SECRET" \
  --from-file="${MODEL_KEY_VAR}=${MODEL_KEY_FILE}" >/dev/null
kc -n "$AGENT_NS" label secret "$MODEL_KEY_SECRET" app.kubernetes.io/part-of=agents-assist-attackers >/dev/null

# Check the stored length without reading the value: base64 length is 4*ceil(n/3).
n="$(stat -c %s "$MODEL_KEY_FILE")"
want=$(( (n + 2) / 3 * 4 ))
got="$(kc -n "$AGENT_NS" get secret "$MODEL_KEY_SECRET" \
  -o go-template="{{with index .data \"${MODEL_KEY_VAR}\"}}{{len .}}{{end}}")"
if [ "$got" != "$want" ]; then
  echo "FAIL  stored ${MODEL_KEY_VAR} length ($got) does not match the key file ($want base64 chars)." >&2
  exit 1
fi
echo "PASS  Secret holds ${MODEL_KEY_VAR} with the key file's exact length (value not shown)"

bash "$SCRIPTS_DIR/check-model-secret.sh"
