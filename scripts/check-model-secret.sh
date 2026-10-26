#!/usr/bin/env bash
#
# check-model-secret.sh — audit the model-key Secret without reading the key. It checks that:
#   1. exactly one such Secret exists, in namespace agent;
#   2. it holds a non-empty key entry;
#   3. it has no last-applied-configuration annotation;
#   4. no other Secret looks like a model key; and
#   5. only goose pods use it, and none of them gets a ServiceAccount token.

set -uo pipefail   # not -e, so every problem is reported

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

FAILED=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILED=1; }

# 1. Exactly one, in the right namespace (names only).
mapfile -t HITS < <(kc get secrets -A --no-headers -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name 2>/dev/null \
  | awk -v n="$MODEL_KEY_SECRET" '$2==n {print $1"/"$2}')
if [ "${#HITS[@]}" -eq 1 ] && [ "${HITS[0]}" = "${AGENT_NS}/${MODEL_KEY_SECRET}" ]; then
  pass "exactly one ${MODEL_KEY_SECRET} Secret, in ns ${AGENT_NS}"
elif [ "${#HITS[@]}" -eq 0 ]; then
  fail "no ${MODEL_KEY_SECRET} Secret — the user creates it with: make model-secret"
else
  fail "${MODEL_KEY_SECRET} found at: ${HITS[*]} — it must exist ONLY in ns ${AGENT_NS}"
fi

if kc -n "$AGENT_NS" get secret "$MODEL_KEY_SECRET" >/dev/null 2>&1; then
  # 2. A non-empty entry, checked by length only.
  len="$(kc -n "$AGENT_NS" get secret "$MODEL_KEY_SECRET" \
    -o go-template="{{with index .data \"${MODEL_KEY_VAR}\"}}{{len .}}{{end}}" 2>/dev/null)"
  if [ -n "$len" ] && [ "$len" -gt 0 ]; then
    pass "Secret has a non-empty ${MODEL_KEY_VAR} entry (value not read)"
  else
    fail "Secret has no ${MODEL_KEY_VAR} entry — recreate it: make model-secret"
  fi
  # 3. No apply annotation.
  ann="$(kc -n "$AGENT_NS" get secret "$MODEL_KEY_SECRET" \
    -o go-template='{{with .metadata.annotations}}{{index . "kubectl.kubernetes.io/last-applied-configuration" | len}}{{end}}' 2>/dev/null)"
  if [ -z "$ann" ] || [ "$ann" = "0" ]; then
    pass "no last-applied-configuration annotation (Secret was created, not applied)"
  else
    fail "Secret carries last-applied-configuration — it holds a 2nd copy of the key; delete it and run: make model-secret"
  fi
fi

# 4. No look-alike Secrets elsewhere.
OTHERS="$(kc get secrets -A --no-headers -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name 2>/dev/null \
  | awk -v n="$MODEL_KEY_SECRET" -v ns="$AGENT_NS" 'tolower($2) ~ /openrouter|anthropic|openai|model-api|model-key/ && !($1==ns && $2==n) {print $1"/"$2}')"
if [ -z "$OTHERS" ]; then
  pass "no other model-key-looking Secret in any namespace"
else
  fail "unexpected model-key-like Secret(s): $(echo "$OTHERS" | tr '\n' ' ')"
fi

# 5. Which pods use it (pod specs never contain Secret values).
REFS="$(kc get pods -A -o json 2>/dev/null | python3 -c '
import json, sys
secret, agent_ns, goose = sys.argv[1], sys.argv[2], sys.argv[3]
gk, gv = goose.split("=", 1)
for p in json.load(sys.stdin)["items"]:
    md, spec = p["metadata"], p["spec"]
    refs = any(v.get("secret", {}).get("secretName") == secret for v in spec.get("volumes", []) or [])
    for c in (spec.get("containers") or []) + (spec.get("initContainers") or []):
        for e in c.get("env") or []:
            if (e.get("valueFrom") or {}).get("secretKeyRef", {}).get("name") == secret: refs = True
        for ef in c.get("envFrom") or []:
            if (ef.get("secretRef") or {}).get("name") == secret: refs = True
    if not refs: continue
    is_goose = md["namespace"] == agent_ns and (md.get("labels") or {}).get(gk) == gv
    sa_off = spec.get("automountServiceAccountToken") is False
    print(("OK" if is_goose and sa_off else "BAD"), md["namespace"] + "/" + md["name"],
          "goose" if is_goose else "NOT-goose", "sa-token-off" if sa_off else "SA-TOKEN-MOUNTED")
' "$MODEL_KEY_SECRET" "$AGENT_NS" "$GOOSE_LABEL")"
if [ -z "$REFS" ]; then
  pass "no pod references the Secret right now (goose runs as a short-lived Job)"
elif ! grep -q '^BAD' <<<"$REFS"; then
  pass "only goose pods reference the Secret, all without a ServiceAccount token ($(grep -c '^OK' <<<"$REFS"))"
else
  fail "Secret referenced by a pod it must not be: $(grep '^BAD' <<<"$REFS" | cut -d' ' -f2- | tr '\n' ';')"
fi

[ "$FAILED" -eq 0 ] && echo "model-key Secret OK." || echo "model-key Secret NOT OK — fix the FAIL lines above."
exit "$FAILED"
