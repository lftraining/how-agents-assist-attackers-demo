#!/usr/bin/env bash
#
# check-model-key.sh — check how your model key is stored, without ever printing it.
#
#   --runtime   Also search the goose, collector, and Falco logs for the key.

set -uo pipefail   # not -e, so every problem is reported

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

FAILED=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILED=1; }
warn() { printf 'WARN  %s\n' "$*"; }

if [ -z "${MODEL_KEY_FILE:-}" ]; then
  fail "MODEL_KEY_FILE is not set in your shell (its path lives only in your environment) — export it, then: make set-model-key"
  exit 1
fi
if [ ! -f "$MODEL_KEY_FILE" ]; then
  fail "no key file at $MODEL_KEY_FILE — run: make set-model-key"
  exit 1
fi
pass "key file exists ($MODEL_KEY_FILE)"

mode="$(stat -c %a "$MODEL_KEY_FILE")"
if [ "$mode" = "600" ] || [ "$mode" = "400" ]; then pass "key file is owner-only (mode $mode)"
else fail "key file mode is $mode — run: chmod 600 $MODEL_KEY_FILE"; fi

dmode="$(stat -c %a "$(dirname "$MODEL_KEY_FILE")")"
if [ "$dmode" = "700" ]; then pass "secrets dir is owner-only (mode $dmode)"
else fail "secrets dir mode is $dmode — run: chmod 700 $(dirname "$MODEL_KEY_FILE")"; fi

if [ "$(stat -c %U "$MODEL_KEY_FILE")" = "$(id -un)" ]; then pass "key file owned by $(id -un)"
else fail "key file is not owned by $(id -un)"; fi

case "$(realpath "$MODEL_KEY_FILE")" in
  "$(realpath "$REPO_ROOT")"/*) fail "key file is INSIDE the repo — move it out" ;;
  *) pass "key file is outside the repo" ;;
esac

# The file must hold only the key, with no trailing newline.
KEY="$(cat "$MODEL_KEY_FILE")"
if [ -z "$KEY" ]; then
  fail "key file is empty — re-run: make set-model-key"
elif [[ "$KEY" == *=* && "$KEY" != sk-* ]]; then
  fail "key file looks like the old NAME=value format — re-run: make set-model-key (it now stores the raw key)"
elif [ "$(tail -c1 "$MODEL_KEY_FILE" | od -An -c | tr -d ' ')" = '\n' ] || [ "$(wc -l < "$MODEL_KEY_FILE")" -ne 0 ]; then
  fail "key file has a trailing newline — the Secret value would be corrupted; re-run: make set-model-key"
else
  pass "file holds a raw, single-line key with no trailing newline (value not shown)"
fi

# Search the repo and its history. The pattern is read from a file, never an argument.
if [ -n "$KEY" ]; then
  if grep -rqF --exclude-dir=.git -f "$MODEL_KEY_FILE" "$REPO_ROOT" 2>/dev/null; then
    fail "the key value appears in a repo file — remove it and ROTATE the key with your model vendor"
  else
    pass "key value not present in any repo file"
  fi
  if git -C "$REPO_ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
    hits="$(git -C "$REPO_ROOT" log --all -p 2>/dev/null | grep -cF -f "$MODEL_KEY_FILE" || true)"
    if [ "${hits:-0}" -gt 0 ]; then
      fail "the key value is in git history — ROTATE the key and rewrite history before any push"
    else
      pass "key value not present in git history"
    fi
  fi
fi

# With --runtime, search the logs a run writes.
if [ "${1:-}" = "--runtime" ] && [ -n "$KEY" ]; then
  scan() {  # $1 = label; stdin = text to scan
    local n; n="$(grep -cF -f "$MODEL_KEY_FILE" || true)"
    if [ "${n:-0}" -gt 0 ]; then fail "the key value appears in the $1 — ROTATE it with your model vendor and find the leak"
    else pass "key value not present in the $1"; fi
  }
  kc -n "$AGENT_NS" logs -l "$GOOSE_LABEL" --tail=-1 2>/dev/null | scan "goose Job log"
  docker logs "$COLLECTOR_CONTAINER" 2>&1 | scan "collector log"
  kc -n "$FALCO_NS" logs -l "$FALCO_SELECTOR" --tail=-1 2>/dev/null | scan "Falco log"
fi
unset KEY

# The key itself must not be exported in your shell.
if [ -n "${!MODEL_KEY_VAR:-}" ]; then
  warn "${MODEL_KEY_VAR} is exported in this shell — unnecessary; the Secret is built from the file. Consider: unset ${MODEL_KEY_VAR}"
fi

[ "$FAILED" -eq 0 ] && echo "model key storage OK." || echo "model key storage NOT OK — fix the FAIL lines above."
exit "$FAILED"
