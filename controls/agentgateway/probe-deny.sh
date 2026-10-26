#!/usr/bin/env bash
#
# probe-deny.sh — prove the gateway control. It passes only if the exfiltration tool is gone
# from tools/list and a direct call to it is refused. It runs from a throwaway pod with
# goose's label, using the mcp-fs image for its MCP client library.
set -euo pipefail

# shellcheck source=../../scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"

require_set GATEWAY_URL
require_set EXFIL_TOOL_NAME
PROBE_POD="agentgateway-deny-probe"
PROBE_IMAGE="${PROBE_IMAGE:-$MCP_FS_IMAGE}"

# The MCP client the probe pod runs.
read -r -d '' PROBE_PY <<'PY' || true
import asyncio, os, sys
from mcp.client.streamable_http import streamable_http_client
from mcp.client.session import ClientSession

URL = os.environ["GATEWAY_URL"]
EXFIL = os.environ["EXFIL_TOOL_NAME"]              # underlying name, e.g. http_post

def is_exfil(client_facing_name: str) -> bool:
    # tools/list shows prefixed names, such as http-post_http_post.
    return client_facing_name == EXFIL or client_facing_name.endswith("_" + EXFIL)

async def main() -> int:
    # Becomes true once the verdict is printed.
    verdict_done = False
    rc = 1
    try:
        async with streamable_http_client(URL) as (r, w):
            async with ClientSession(r, w) as s:
                await s.initialize()
                listed = [t.name for t in (await s.list_tools()).tools]
                print("tools/list from the gateway:")
                for n in listed:
                    print("   -", n)

                gone = not any(is_exfil(n) for n in listed)
                print("\n[1] exfil tool (%r) absent from tools/list: %s" % (EXFIL, "YES" if gone else "NO"))

                # Try a direct call anyway, with the tool's prefixed name.
                refused = False
                target_name = "http-post_" + EXFIL      # <target>_<underlying>
                try:
                    res = await s.call_tool(target_name, {"url": "http://example.invalid/", "body": "x"})
                    refused = bool(getattr(res, "is_error", False))
                    detail = (res.content[0].text if res.content else "")[:160]
                except Exception as e:                   # gateway refuses → client raises
                    refused = True
                    detail = "%s: %s" % (type(e).__name__, str(e)[:160])
                print("[2] direct tools/call for %r REFUSED by the gateway: %s" % (target_name, "YES" if refused else "NO"))
                print("    gateway response: %s" % detail)

                ok = gone and refused
                print("\nPROBE: %s" % ("PASS" if ok else "FAIL"))
                rc = 0 if ok else 1
                verdict_done = True

                # Silence output after the verdict.
                sys.stdout.flush()
                sys.stderr.flush()
                sys.stdout = open(os.devnull, "w")
                sys.stderr = open(os.devnull, "w")
    except Exception:
        # Ignore errors after the verdict; re-raise anything before it.
        if not verdict_done:
            raise
    return rc

sys.exit(asyncio.run(main()))
PY

echo ">> probe-deny: launching in-cluster probe pod ${PROBE_POD} (ns ${AGENT_NS})"
kc -n "$AGENT_NS" delete pod "$PROBE_POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true

# --attach returns the probe's exit code, and --rm deletes the pod afterward.
kc -n "$AGENT_NS" run "$PROBE_POD" \
  --image="$PROBE_IMAGE" --image-pull-policy=Never --restart=Never \
  --labels="app=goose-agent" \
  --env="GATEWAY_URL=${GATEWAY_URL}" --env="EXFIL_TOOL_NAME=${EXFIL_TOOL_NAME}" \
  --attach --rm --quiet \
  --command -- python -c "$PROBE_PY"
