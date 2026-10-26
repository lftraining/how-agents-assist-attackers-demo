# shellcheck shell=bash
# The scripts that source this file use the variables it defines.
# shellcheck disable=SC2034
# skill-bundle/lib.sh — shared helpers for the signing scripts. Source it after
# scripts/lib/common.sh.

SB_CA_CRT="${REPO_ROOT}/${REGISTRY_RUNTIME_DIR}/ca.crt"
SB_CA_BUNDLE="${REPO_ROOT}/${REGISTRY_CA_BUNDLE}"
SB_SIGSTORE_DIR="${REPO_ROOT}/${SIGSTORE_RUNTIME_DIR}"
SB_REKOR_PUB="${SB_SIGSTORE_DIR}/rekor.pub"
SB_BACKUP="${SB_SIGSTORE_DIR}/oci-backup"
SB_THV_DIR="${REPO_ROOT}/${THV_STATE_DIR}"
SB_THV_URL="http://127.0.0.1:${THV_API_PORT}"
LIVE_REPO="${REGISTRY}/${SKILL_REPO}"
TAMPER_REPO="${REGISTRY}/${SKILL_TAMPER_REPO}"
DIGEST_FILE="${REPO_ROOT}/${SKILL_DIGEST_FILE}"
GOOSE_PROJECT_ABS="${REPO_ROOT}/${GOOSE_PROJECT_DIR}"
SB_THV_PID=""

ORAS_TLS=(--plain-http=false --ca-file "$SB_CA_CRT")
ORAS_CP_TLS=(--from-plain-http=false --from-ca-file "$SB_CA_CRT" --to-plain-http=false --to-ca-file "$SB_CA_CRT")

# Trust the registry's CA through a file.
export SSL_CERT_FILE="$SB_CA_BUNDLE"

sb_die() { printf 'FATAL %s\n' "$*" >&2; exit 1; }

sb_require_tools() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || sb_die "'$t' not found on PATH (run scripts/01-install-tools.sh; pinned tools live in ~/.local/bin)"
  done
}

# cosign must be 2.6.x.
sb_cosign_guard() {
  local v
  v="$(cosign version 2>/dev/null | grep -m1 -i 'GitVersion' || true)"
  case "$v" in
    *"v${COSIGN_REQUIRED_LINE}."*) : ;;
    *) sb_die "cosign is not on the ${COSIGN_REQUIRED_LINE}.x line (${v:-not installed}) — refusing" ;;
  esac
}

sb_registry_up() {
  [ -s "$SB_CA_BUNDLE" ] || sb_die "registry CA bundle missing (${REGISTRY_CA_BUNDLE}) — run registry/run-registry.sh"
  curl --cacert "$SB_CA_CRT" -fsS -m 5 -o /dev/null "https://${REGISTRY}/v2/" 2>/dev/null \
    || sb_die "registry https://${REGISTRY} not answering — run registry/run-registry.sh"
}

sb_resolve() { oras resolve "${ORAS_TLS[@]}" "$1" 2>/dev/null; }

# The tag where cosign 2.6 stores a digest's signature: sha256-<hex>.sig
sb_sig_tag() { printf 'sha256-%s.sig' "${1#sha256:}"; }

sb_recorded_digest() { [ -s "$DIGEST_FILE" ] && tr -d '[:space:]' < "$DIGEST_FILE"; }

# --- ToolHive: private API server --------------------------------------------------------
thvc() {
  env XDG_CONFIG_HOME="${SB_THV_DIR}/config" XDG_STATE_HOME="${SB_THV_DIR}/state" \
      XDG_DATA_HOME="${SB_THV_DIR}/data" XDG_CACHE_HOME="${SB_THV_DIR}/cache" \
      TOOLHIVE_API_URL="$SB_THV_URL" TOOLHIVE_SKIP_UPDATE_CHECK=true \
      thv "$@"
}

sb_thv_down() {
  if [ -n "$SB_THV_PID" ] && kill -0 "$SB_THV_PID" 2>/dev/null; then
    kill "$SB_THV_PID" 2>/dev/null
    wait "$SB_THV_PID" 2>/dev/null
  fi
  SB_THV_PID=""
  rm -f "${SB_THV_DIR}/serve.pid"
}

sb_thv_up() {
  mkdir -p "$SB_THV_DIR"
  # Stop a leftover server from an earlier run of this demo.
  if [ -s "${SB_THV_DIR}/serve.pid" ]; then
    local old; old="$(cat "${SB_THV_DIR}/serve.pid")"
    if [ "$(ps -o comm= -p "$old" 2>/dev/null)" = "thv" ]; then kill "$old" 2>/dev/null || true; fi
    rm -f "${SB_THV_DIR}/serve.pid"
  fi
  local _
  for _ in $(seq 1 40); do
    curl -fs -m 1 -o /dev/null "${SB_THV_URL}/health" 2>/dev/null || break
    sleep 0.05   # poll: give a just-killed leftover server time to release the port
  done
  if curl -fs -m 1 -o /dev/null "${SB_THV_URL}/health" 2>/dev/null; then
    sb_die "port ${THV_API_PORT} already serves something that is not our ToolHive — set THV_API_PORT"
  fi
  env XDG_CONFIG_HOME="${SB_THV_DIR}/config" XDG_STATE_HOME="${SB_THV_DIR}/state" \
      XDG_DATA_HOME="${SB_THV_DIR}/data" XDG_CACHE_HOME="${SB_THV_DIR}/cache" \
      TOOLHIVE_SKIP_UPDATE_CHECK=true \
      thv serve --host 127.0.0.1 --port "$THV_API_PORT" >"${SB_THV_DIR}/serve.log" 2>&1 &
  SB_THV_PID=$!
  echo "$SB_THV_PID" > "${SB_THV_DIR}/serve.pid"
  for _ in $(seq 1 200); do
    if curl -fs -m 1 -o /dev/null "${SB_THV_URL}/health" 2>/dev/null; then return 0; fi
    kill -0 "$SB_THV_PID" 2>/dev/null || break
    sleep 0.05   # poll: bounded wait for the API server (normally ~0.5 s)
  done
  tail -5 "${SB_THV_DIR}/serve.log" >&2
  sb_die "ToolHive API server did not come up on ${SB_THV_URL}"
}

# Package a skill with ToolHive and print its digest: sb_thv_build <skill-dir> <oci-tag>
sb_thv_build() {
  local src="$1" tag="$2" stage digest
  stage="$(mktemp -d)"
  mkdir -p "${stage}/${SKILL_NAME}"
  if [ -d "$src" ]; then cp -R "$src"/. "${stage}/${SKILL_NAME}/"; else cp "$src" "${stage}/${SKILL_NAME}/${SKILL_FILE}"; fi
  if ! thvc skill build "${stage}/${SKILL_NAME}" -t "$tag" >/dev/null; then
    rm -rf "$stage"; return 1
  fi
  rm -rf "$stage"
  digest="$(thvc skill builds --format json | python3 -c '
import json, sys
tag = sys.argv[1]
for b in json.load(sys.stdin) or []:
    if b.get("tag") == tag:
        print(b["digest"]); break
' "$tag")"
  [ -n "$digest" ] || return 1
  printf '%s\n' "$digest"
}

# --- cosign ----------------------------------------------------------------------------
# Verify a signature with your public key, offline: sb_cosign_verify <ref@digest>
SB_WRAP=()
sb_cosign_verify() {
  if [ "$TLOG_MODE" = "none" ]; then
    "${SB_WRAP[@]}" cosign verify --key "$COSIGN_PUB" --insecure-ignore-tlog=true "$1" 2>&1
  else
    [ -s "$SB_REKOR_PUB" ] || { echo "pinned Rekor key missing (${SIGSTORE_RUNTIME_DIR}/rekor.pub) — run: make setup"; return 1; }
    SIGSTORE_REKOR_PUBLIC_KEY="$SB_REKOR_PUB" "${SB_WRAP[@]}" cosign verify --key "$COSIGN_PUB" --offline=true "$1" 2>&1
  fi
}

# Print the Rekor bundle stored with a signature, if any: sb_rekor_bundle <repo> <digest>
sb_rekor_bundle() {
  local repo="$1" digest="$2"
  oras manifest fetch "${ORAS_TLS[@]}" "${repo}:$(sb_sig_tag "$digest")" 2>/dev/null | python3 -c '
import json, sys
m = json.load(sys.stdin)
for l in m.get("layers", []):
    b = (l.get("annotations") or {}).get("dev.sigstore.cosign/bundle")
    if b:
        print(b); break
' 2>/dev/null
}

# Save the Rekor public key that signed a bundle: sb_pin_rekor_key <bundle-json>
sb_pin_rekor_key() {
  local bundle="$1" tr
  tr="${TUF_ROOT:-$HOME/.sigstore/root}/tuf-repo-cdn.sigstore.dev/targets/trusted_root.json"
  if [ ! -s "$tr" ]; then
    cosign initialize >/dev/null 2>&1 || sb_die "cosign initialize failed (online needed once to fetch the Sigstore trust root)"
  fi
  [ -s "$tr" ] || sb_die "no Sigstore trusted_root.json at ${tr}"
  mkdir -p "$SB_SIGSTORE_DIR"
  printf '%s' "$bundle" | python3 -c '
import base64, hashlib, json, sys, textwrap
bundle = json.load(sys.stdin)
log_id = bundle["Payload"]["logID"]
root = json.load(open(sys.argv[1]))
for t in root.get("tlogs", []):
    kid = base64.b64decode(t["logId"]["keyId"]).hex()
    if kid != log_id:
        continue
    der = base64.b64decode(t["publicKey"]["rawBytes"])
    if hashlib.sha256(der).hexdigest() != log_id:
        sys.exit("logID does not match the key bytes")
    pem = "-----BEGIN PUBLIC KEY-----\n" + "\n".join(textwrap.wrap(base64.b64encode(der).decode(), 64)) + "\n-----END PUBLIC KEY-----\n"
    open(sys.argv[2], "w").write(pem)
    sys.exit(0)
sys.exit("no tlog in trusted_root.json matches logID " + log_id)
' "$tr" "$SB_REKOR_PUB"
}

# Print the digest ToolHive's lock file records for the skill, prefixed "UNSIGNED " if it
# was installed unsigned. Usage: sb_lock_digest <project-root>
sb_lock_digest() {
  [ -s "$1/toolhive.lock.yaml" ] || return 0
  python3 - "$1/toolhive.lock.yaml" "$SKILL_NAME" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
for block in re.split(r'\n\s*- name: ', '\n' + text)[1:]:
    if block.split('\n', 1)[0].strip() == sys.argv[2]:
        m = re.search(r'^\s+digest:\s*(\S+)', block, re.M)
        unsigned = re.search(r'^\s+unsigned:\s*true', block, re.M)
        print(("UNSIGNED " if unsigned else "") + (m.group(1) if m else ""))
PY
}

# Print SKILL.md exactly as packed in the artifact: sb_artifact_skill_md <repo> <digest>
sb_artifact_skill_md() {
  local repo="$1" digest="$2" m layer
  m="$(oras manifest fetch "${ORAS_TLS[@]}" "${repo}@${digest}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["manifests"][0]["digest"])')" || return 1
  layer="$(oras manifest fetch "${ORAS_TLS[@]}" "${repo}@${m}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["layers"][0]["digest"])')" || return 1
  oras blob fetch "${ORAS_TLS[@]}" --output - "${repo}@${layer}" | tar -xzO "$SKILL_FILE"
}

# Print the public key ToolHive pinned for the skill: sb_lock_pubkey <project-root>
sb_lock_pubkey() {
  [ -s "$1/toolhive.lock.yaml" ] || return 0
  python3 - "$1/toolhive.lock.yaml" "$SKILL_NAME" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
for block in re.split(r'\n\s*- name: ', '\n' + text)[1:]:
    if block.split('\n', 1)[0].strip() == sys.argv[2]:
        m = re.search(r'^\s+publicKey:\s*(\S+)', block, re.M)
        print(m.group(1) if m else "")
PY
}

# Count the public Rekor entries under your key. Prints nothing if Rekor is unreachable.
sb_rekor_entries_for_key() {
  local body
  body="$(python3 -c 'import base64,json,sys; print(json.dumps({"publicKey":{"format":"x509","content":base64.b64encode(open(sys.argv[1],"rb").read()).decode()}}))' "$COSIGN_PUB")" || return 1
  curl -fsS -m 15 -X POST -H 'Content-Type: application/json' -d "$body" \
    "${REKOR_URL}/api/v1/index/retrieve" 2>/dev/null \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin) or []))' 2>/dev/null
}
