#!/usr/bin/env bash
#
# 01-install-tools.sh — install the demo's command-line tools at exact versions into
# ~/.local/bin, without sudo. A tool already at its pinned version is skipped. Docker, make,
# jq, git, openssl, curl, and python3 must already be installed; this script only checks them.

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# --- Pinned versions ----------------------------------------------------------------
KUBECTL_VERSION=v1.32.13      # matches the kind node's Kubernetes 1.32
KIND_VERSION=v0.26.0          # its node image is pinned in cluster/kind-config.yaml
HELM_VERSION=v3.22.0          # Helm 3, for the Cilium and Falco charts
CILIUM_CLI_VERSION=v0.20.1    # checks the health of Cilium
HUBBLE_VERSION=v1.20.2        # optional: observe network flows
COSIGN_VERSION=v2.6.5         # must stay on 2.6.x
ORAS_VERSION=v1.3.4           # reads the skill artifact in the registry
THV_VERSION=v0.54.0           # ToolHive: verifies the skill before installing it
AGENTGATEWAY_VERSION=v1.6.0   # validates the gateway policy
YQ_VERSION=v4.54.1            # edits YAML in scripts
SHELLCHECK_VERSION=v0.11.0    # koalaman/shellcheck — make lint

BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
ARCH="$(uname -m)"
if [ "$ARCH" != "x86_64" ]; then
  printf 'FATAL this script pins x86_64 assets only; arch is %s\n' "$ARCH" >&2
  exit 1
fi

# The pinned cosign must match COSIGN_REQUIRED_LINE in demo.env.
case "$COSIGN_VERSION" in
  v"$COSIGN_REQUIRED_LINE".*) : ;;  # e.g. v2.6.5 starts with v2.6.
  *) printf 'FATAL COSIGN_VERSION=%s is not on the required %s.x line (cosign 3.x can hang offline)\n' \
            "$COSIGN_VERSION" "$COSIGN_REQUIRED_LINE" >&2; exit 1 ;;
esac

mkdir -p "$BIN_DIR"
case ":$PATH:" in
  *":$BIN_DIR:"*) : ;;
  *) printf 'WARN %s is not on PATH; add it (e.g. in ~/.profile) so installed tools resolve\n' "$BIN_DIR" >&2 ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log()  { printf '%s\n' "$*"; }
step() { printf '\n>>> %s\n' "$*"; }

# Download with retries, and fail on HTTP errors.
dl() { curl -fsSL --retry 3 --retry-delay 2 -m 300 -o "$1" "$2"; }

# True when the tool is on PATH at the pinned version, so a re-run can skip it.
installed_ok() {
  local tool="$1" needle="$2"; shift 2
  command -v "$tool" >/dev/null 2>&1 || return 1
  local out
  out="$("$@" 2>&1 || true)"
  printf '%s\n' "$out" | grep -qF -- "$needle"
}

place() { install -m 0755 "$1" "$BIN_DIR/$2"; }

# --- Tools shipped as a single binary -------------------------------------------------
install_single() {  # name needle url versioncmd...
  local name="$1" needle="$2" url="$3"; shift 3
  if installed_ok "$name" "$needle" "$@"; then
    log "ok    $name already at $needle — skipping"; return 0
  fi
  log "get   $name -> $needle"
  dl "$WORK/$name" "$url"
  place "$WORK/$name" "$name"
}

# --- Tools shipped in an archive ---------------------------------------------------------
install_tar() {  # name needle url archive-type binary-basename versioncmd...
  local name="$1" needle="$2" url="$3" atype="$4" inner="$5"; shift 5
  if installed_ok "$name" "$needle" "$@"; then
    log "ok    $name already at $needle — skipping"; return 0
  fi
  log "get   $name -> $needle"
  local tb="$WORK/$name.tar" d="$WORK/$name.d"
  dl "$tb" "$url"; mkdir -p "$d"
  case "$atype" in
    gz) tar -xzf "$tb" -C "$d" ;;
    xz) tar -xJf "$tb" -C "$d" ;;
    *)  printf 'FATAL unknown archive type %s\n' "$atype" >&2; exit 1 ;;
  esac
  local found; found="$(find "$d" -type f -name "$inner" | head -1)"
  [ -n "$found" ] || { printf 'FATAL %s not found inside %s archive\n' "$inner" "$name" >&2; exit 1; }
  place "$found" "$name"
}

GH=https://github.com

log "=== Installing pinned CLIs into $BIN_DIR ==="

# Check the tools you install yourself.
for t in docker make jq git openssl curl python3; do
  command -v "$t" >/dev/null 2>&1 || { printf 'FATAL %s is not installed — install it with your package manager, then re-run\n' "$t" >&2; exit 1; }
done

# --- Kubernetes ---------------------------------------------------------------------------
step "kubectl ($KUBECTL_VERSION) + kind ($KIND_VERSION)"
install_single kubectl "$KUBECTL_VERSION" \
  "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
  kubectl version --client
install_single kind "${KIND_VERSION#v}" \
  "$GH/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-amd64" \
  kind --version

step "helm ($HELM_VERSION)"
install_tar helm "$HELM_VERSION" \
  "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" gz helm \
  helm version --short

# --- Cilium and Hubble -------------------------------------------------------------------
step "cilium CLI ($CILIUM_CLI_VERSION) + hubble CLI ($HUBBLE_VERSION)"
install_tar cilium "$CILIUM_CLI_VERSION" \
  "$GH/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz" gz cilium \
  cilium version --client
install_tar hubble "$HUBBLE_VERSION" \
  "$GH/cilium/hubble/releases/download/${HUBBLE_VERSION}/hubble-linux-amd64.tar.gz" gz hubble \
  hubble version

# --- Signing: cosign, oras, ToolHive ---------------------------------------------------------
step "cosign ($COSIGN_VERSION — 2.6.x line) + oras ($ORAS_VERSION) + thv ($THV_VERSION)"
install_single cosign "${COSIGN_VERSION#v}" \
  "$GH/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64" \
  cosign version
install_tar oras "${ORAS_VERSION#v}" \
  "$GH/oras-project/oras/releases/download/${ORAS_VERSION}/oras_${ORAS_VERSION#v}_linux_amd64.tar.gz" gz oras \
  oras version
install_tar thv "$THV_VERSION" \
  "$GH/stacklok/toolhive/releases/download/${THV_VERSION}/toolhive_${THV_VERSION#v}_linux_amd64.tar.gz" gz thv \
  thv version

# --- agentgateway CLI ------------------------------------------------------------------------
step "agentgateway ($AGENTGATEWAY_VERSION)"
install_single agentgateway "${AGENTGATEWAY_VERSION#v}" \
  "$GH/agentgateway/agentgateway/releases/download/${AGENTGATEWAY_VERSION}/agentgateway-linux-amd64" \
  agentgateway --version

# -- General tooling: yq, shellcheck -----------------------------------------------
step "yq ($YQ_VERSION) + shellcheck ($SHELLCHECK_VERSION)"
install_single yq "$YQ_VERSION" \
  "$GH/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
  yq --version
install_tar shellcheck "${SHELLCHECK_VERSION#v}" \
  "$GH/koalaman/shellcheck/releases/download/${SHELLCHECK_VERSION}/shellcheck-${SHELLCHECK_VERSION}.linux.x86_64.tar.xz" xz shellcheck \
  shellcheck --version

# --- Print the installed versions ----------------------------------------------------------
log ""
log "=== Installed versions (compare with DEMO-GUIDE.md, section 15) ==="
printf '%-14s %s\n' "TOOL" "VERSION"
printf '%-14s %s\n' "----" "-------"
row() { printf '%-14s %s\n' "$1" "$2"; }
row docker       "$(docker --version 2>/dev/null | sed 's/,.*//')"
row kubectl      "$(kubectl version --client 2>/dev/null | awk '/Client Version/{print $3}')"
row kind         "$(kind --version 2>/dev/null)"
row helm         "$(helm version --short 2>/dev/null)"
row cilium       "$(cilium version --client 2>/dev/null | awk '/cilium-cli/{print $2}')"
row hubble       "$(hubble version 2>/dev/null | awk '{print $2}')"
row cosign       "$(cosign version 2>/dev/null | awk '/GitVersion/{print $2}')"
row oras         "$(oras version 2>/dev/null | awk '/Version/{print $2}')"
row thv          "$(thv version 2>/dev/null | head -1)"
row agentgateway "$(agentgateway -V 2>/dev/null | head -1)"
row yq           "$(yq --version 2>/dev/null | awk '{print $NF}')"
row shellcheck   "$(shellcheck --version 2>/dev/null | awk '/version:/{print $2}')"
row jq           "$(jq --version 2>/dev/null)"
row git          "$(git --version 2>/dev/null | awk '{print $3}')"
row python3      "$(python3 --version 2>/dev/null | awk '{print $2}')"

log ""
log "Done. All CLIs pinned and installed into $BIN_DIR. Re-run is idempotent (skips matches)."
