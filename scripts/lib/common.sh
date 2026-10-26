# shellcheck shell=bash
# scripts/lib/common.sh — shared setup that every demo script sources.
#
# It loads demo.env and demo.local.env and defines a few helpers. A value already set in
# the environment wins, so one-off overrides work: TIMEOUT=300s make readiness

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
DEMO_ENV="${DEMO_ENV:-$REPO_ROOT/demo.env}"
export REPO_ROOT DEMO_ENV

if [ ! -f "$DEMO_ENV" ]; then
  printf 'FATAL demo.env not found at %s\n' "$DEMO_ENV" >&2
  return 1 2>/dev/null || exit 1
fi

# Load demo.local.env first, so your saved choices override demo.env.
_parse_env() {
  local _line _key _val
  [ -f "$1" ] || return 0
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in ''|'#'*) continue ;; esac
    if [[ "$_line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      _key="${BASH_REMATCH[1]}"
      _val="${BASH_REMATCH[2]}"
      _val="${_val%"${_val##*[![:space:]]}"}"   # trim trailing whitespace
      if [ -z "${!_key+x}" ]; then export "$_key=$_val"; fi
    fi
  done < "$1"
}
_parse_env "${DEMO_LOCAL_ENV:-$REPO_ROOT/demo.local.env}"
_parse_env "$DEMO_ENV"
unset -f _parse_env

# --- Model vendor ----------------------------------------------------------------------
# Copy the chosen vendor's block from demo.env into the MODEL_* names the scripts use.
MODEL_VENDOR="${MODEL_VENDOR:-openrouter}"
case "$MODEL_VENDOR" in
  openrouter|anthropic|openai) ;;
  *) printf 'FATAL MODEL_VENDOR=%s is not one of openrouter|anthropic|openai (set it in demo.local.env or demo.env)\n' "$MODEL_VENDOR" >&2
     return 1 2>/dev/null || exit 2 ;;
esac
_vp="$(printf '%s' "$MODEL_VENDOR" | tr '[:lower:]' '[:upper:]')"   # OPENROUTER / ANTHROPIC / OPENAI
for _f in PROVIDER KEY_VAR API_FQDN BASE_URL MODEL; do
  _src="${_vp}_${_f}"                 # e.g. OPENROUTER_PROVIDER
  case "$_f" in MODEL) _dst=MODEL_ID ;; *) _dst="MODEL_${_f}" ;; esac
  if [ -z "${!_dst+x}" ]; then export "$_dst=${!_src}"; fi
done
unset _vp _f _src _dst

# Keys live outside the repo, in a folder used only by this project.
DEMO_SECRETS_DIR="${DEMO_SECRETS_DIR:-$HOME/.demo-secrets/agents-assist-attackers}"
COSIGN_KEY="${COSIGN_KEY:-$DEMO_SECRETS_DIR/cosign.key}"
COSIGN_PUB="${COSIGN_PUB:-$DEMO_SECRETS_DIR/cosign.pub}"
# MODEL_KEY_FILE has no default on purpose: its path comes only from your shell.
export DEMO_SECRETS_DIR COSIGN_KEY COSIGN_PUB

# --- Attacker IPs ------------------------------------------------------------------------
# Each attacker IP is a position counted down from the top of the kind network's range.
# Both stay empty until the kind network exists; scripts that need them call
# require_attacker_ips.

# Print the address N below the top address of an IPv4 range: ip_from_top CIDR N
ip_from_top() {
  local a b c d bits="${1#*/}" n
  IFS=. read -r a b c d <<<"${1%/*}"
  n=$(( ((a << 24) | (b << 16) | (c << 8) | d) | ((1 << (32 - bits)) - 1) ))
  n=$(( n - $2 ))
  printf '%d.%d.%d.%d' $(( (n >> 24) & 255 )) $(( (n >> 16) & 255 )) $(( (n >> 8) & 255 )) $(( n & 255 ))
}

# The kind network's IPv4 range (its IPv6 range is skipped).
KIND_SUBNET=""
if command -v docker >/dev/null 2>&1; then
  KIND_SUBNET="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "${KIND_DOCKER_NETWORK:-kind}" 2>/dev/null \
    | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' | head -n1 || true)"
fi
# A range smaller than /24 is too small to keep the fixed IPs clear of Docker's addresses.
if [ -n "$KIND_SUBNET" ] && [ "${KIND_SUBNET#*/}" -le 24 ]; then
  [ -n "${VENDOR_DOCS_IP:-}" ] || VENDOR_DOCS_IP="$(ip_from_top "$KIND_SUBNET" "$VENDOR_DOCS_IP_FROM_TOP")"
  [ -n "${COLLECTOR_IP:-}" ]   || COLLECTOR_IP="$(ip_from_top "$KIND_SUBNET" "$COLLECTOR_IP_FROM_TOP")"
fi
export KIND_SUBNET VENDOR_DOCS_IP="${VENDOR_DOCS_IP:-}" COLLECTOR_IP="${COLLECTOR_IP:-}"

# Stop with a clear message when the attacker IPs cannot be computed yet.
require_attacker_ips() {
  if [ -z "$KIND_SUBNET" ] && { [ -z "$VENDOR_DOCS_IP" ] || [ -z "$COLLECTOR_IP" ]; }; then
    printf "FATAL Docker network '%s' not found, so the attacker IPs cannot be computed — create the cluster first (make up)\n" "${KIND_DOCKER_NETWORK:-kind}" >&2
    exit 2
  fi
  if [ -z "$VENDOR_DOCS_IP" ] || [ -z "$COLLECTOR_IP" ]; then
    printf "FATAL the '%s' network's IPv4 range %s is smaller than /24 — too small for the fixed attacker IPs\n" "${KIND_DOCKER_NETWORK:-kind}" "$KIND_SUBNET" >&2
    exit 2
  fi
}

# kubectl always targets the demo's cluster, never your current context.
KCTX=()
if [ -n "${KUBE_CONTEXT:-}" ]; then KCTX=(--context "$KUBE_CONTEXT"); fi
kc() { kubectl "${KCTX[@]}" "$@"; }

# True if a value is empty or still a placeholder.
is_placeholder() { case "$1" in *PLACEHOLDER*|'') return 0 ;; *) return 1 ;; esac; }

# Stop if a required value is empty or still a placeholder.
require_set() {
  local name="$1"
  if is_placeholder "${!name:-}"; then
    printf 'FATAL %s is still a placeholder (%s) — set it in demo.env first\n' "$name" "${!name:-<empty>}" >&2
    exit 2
  fi
}
