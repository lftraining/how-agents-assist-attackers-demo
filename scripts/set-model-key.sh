#!/usr/bin/env bash
#
# set-model-key.sh — choose your model vendor and store its API key. Run it yourself with
# `make set-model-key`, after exporting MODEL_KEY_FILE in your shell. The key is read at a
# hidden prompt, and your vendor choice goes in the gitignored demo.local.env.

set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

if [ ! -t 0 ]; then
  echo "FATAL run this interactively in your own terminal (it prompts for the vendor and key)." >&2
  exit 1
fi
if [ -z "${MODEL_KEY_FILE:-}" ]; then
  echo "FATAL MODEL_KEY_FILE is not set in your shell. Choose a path OUTSIDE the repo, e.g.:" >&2
  echo "      export MODEL_KEY_FILE=\$HOME/.demo-secrets/model-api-key   (add it to ~/.bashrc)" >&2
  exit 1
fi
case "$(realpath -m "$MODEL_KEY_FILE")" in
  "$(realpath "$REPO_ROOT")"/*)
    echo "FATAL MODEL_KEY_FILE points inside the repo ($MODEL_KEY_FILE) — refusing." >&2
    exit 1 ;;
esac

# --- 1. Choose the vendor --------------------------------------------------------
# The default is your current choice. Each vendor's settings come from demo.env.
echo "Which model vendor are you using?"
echo "  1) OpenRouter   (recommended and tested)"
echo "  2) Anthropic    (Claude)"
echo "  3) OpenAI       (ChatGPT)"
echo "NOTE: This demo was built and tested with OpenRouter only, and OpenRouter is the"
echo "      recommended choice for the attack in run one to work consistently. You may choose"
echo "      OpenAI or Anthropic instead — the demo supports all three — but those paths have"
echo "      not been run here and may not produce reliable results: the model may decline the"
echo "      injected instruction, so run one may not reproduce the compromise. Run two (the"
echo "      defended side) works the same on every vendor."
read -r -p "Enter 1, 2 or 3 (press Enter to keep '${MODEL_VENDOR}'): " choice
case "$choice" in
  1) VENDOR=openrouter ;;
  2) VENDOR=anthropic ;;
  3) VENDOR=openai ;;
  "") VENDOR="$MODEL_VENDOR" ;;
  *) echo "FATAL not 1, 2 or 3." >&2; exit 1 ;;
esac
_vp="$(printf '%s' "$VENDOR" | tr '[:lower:]' '[:upper:]')"
_keyvar_ref="${_vp}_KEY_VAR";  VENDOR_KEY_VAR="${!_keyvar_ref}"
_model_ref="${_vp}_MODEL";     VENDOR_MODEL="${!_model_ref}"

# --- 2. Keep or change the model -------------------------------------------------
read -r -p "Model for ${VENDOR} [${VENDOR_MODEL}] (press Enter to keep, or type a slug): " model_in
MODEL_SLUG="${model_in:-$VENDOR_MODEL}"

# --- 3. The key ------------------------------------------------------------------
umask 077
mkdir -p "$(dirname "$MODEL_KEY_FILE")"
chmod 700 "$(dirname "$MODEL_KEY_FILE")"
if [ -f "$MODEL_KEY_FILE" ]; then
  read -r -p "A key file already exists at $MODEL_KEY_FILE. Replace it? [y/N] " ans
  case "$ans" in y|Y|yes|YES) ;; *) echo "Keeping the existing key file; recording the vendor choice only."; KEY="" ;; esac
fi
if [ "${KEY+set}" != "set" ]; then
  read -r -s -p "Paste your ${VENDOR} API key (input hidden), then press Enter: " KEY
  echo
  KEY="$(printf '%s' "$KEY" | tr -d '[:space:]')"
  if [ -z "$KEY" ]; then echo "FATAL empty key — nothing written." >&2; exit 1; fi
  # Only a warning: sk-or- OpenRouter, sk-ant- Anthropic, sk- OpenAI.
  case "$VENDOR" in
    openrouter) case "$KEY" in sk-or-*) ;; *) echo "WARN  an OpenRouter key usually starts with 'sk-or-'." >&2 ;; esac ;;
    anthropic)  case "$KEY" in sk-ant-*) ;; *) echo "WARN  an Anthropic key usually starts with 'sk-ant-'." >&2 ;; esac ;;
    openai)     case "$KEY" in sk-*) ;; *) echo "WARN  an OpenAI key usually starts with 'sk-'." >&2 ;; esac ;;
  esac
  TMP="$(mktemp "$(dirname "$MODEL_KEY_FILE")/.model-key.XXXXXX")"
  trap 'rm -f "$TMP"' EXIT
  printf '%s' "$KEY" > "$TMP"          # no trailing newline
  chmod 600 "$TMP"
  mv "$TMP" "$MODEL_KEY_FILE"
  trap - EXIT
  echo "PASS  key stored at $MODEL_KEY_FILE (mode $(stat -c %a "$MODEL_KEY_FILE"), $(wc -c < "$MODEL_KEY_FILE") bytes, raw value)."
fi
unset KEY 2>/dev/null || true

# --- 4. Save the vendor choice in demo.local.env ------------------------------------
# It holds MODEL_VENDOR and any model you changed, never a secret, and git ignores it.
LOCAL_ENV="${DEMO_LOCAL_ENV:-$REPO_ROOT/demo.local.env}"
{
  echo "# Written by make set-model-key — your local model-vendor choice. Not committed."
  echo "MODEL_VENDOR=${VENDOR}"
  if [ "$MODEL_SLUG" != "$VENDOR_MODEL" ]; then echo "${_vp}_MODEL=${MODEL_SLUG}"; fi
} > "$LOCAL_ENV"
echo "PASS  vendor recorded in demo.local.env: MODEL_VENDOR=${VENDOR}, model=${MODEL_SLUG} (key env var ${VENDOR_KEY_VAR})."
echo "      Verify the key file any time with:  bash scripts/check-model-key.sh"
echo "      Next:  make setup   &&   make up      (then ./1-setup)"
