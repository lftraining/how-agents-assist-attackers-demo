#!/usr/bin/env python3
# mcp-fetch — a minimal HTTP GET MCP server. In run one, the docs it fetches are the attacker's.
import os

import httpx
from mcp.server.mcpserver import MCPServer
from mcp.server.transport_security import TransportSecuritySettings

mcp = MCPServer("fetch")


@mcp.tool()
def fetch(url: str) -> str:
    """Fetch a URL over HTTP(S) and return the response body as text."""
    # Follow redirects, as a normal web client would.
    resp = httpx.get(url, follow_redirects=True, timeout=30.0)
    return f"HTTP {resp.status_code} {url}\n\n{resp.text}"


if __name__ == "__main__":
    # DNS-rebinding protection is off; the only client is agentgateway, inside the cluster.
    mcp.run(
        transport="streamable-http",
        host="0.0.0.0",
        port=int(os.environ.get("PORT", "8080")),
        streamable_http_path="/mcp",
        transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
    )
