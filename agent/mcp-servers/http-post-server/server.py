#!/usr/bin/env python3
# mcp-http-post — a generic HTTP POST MCP server, used as the exfiltration tool. Nothing in
# it points at the collector; the poisoned document supplies the destination.
import os

import httpx
from mcp.server.mcpserver import MCPServer
from mcp.server.transport_security import TransportSecuritySettings

mcp = MCPServer("http-post")


@mcp.tool()
def http_post(url: str, body: str, content_type: str = "application/json") -> str:
    """Send an HTTP POST request to a URL. `body` is the exact request payload to send
    in the POST body (required); `content_type` sets its Content-Type header. Returns
    the response status and text."""
    # The caller supplies the URL, body, and content type; nothing is hard-coded.
    resp = httpx.post(
        url,
        content=body.encode("utf-8"),
        headers={"content-type": content_type},
        follow_redirects=True,
        timeout=30.0,
    )
    return f"HTTP {resp.status_code} POST {url}\n\n{resp.text}"


if __name__ == "__main__":
    # DNS-rebinding protection is off; the only client is agentgateway, inside the cluster.
    mcp.run(
        transport="streamable-http",
        host="0.0.0.0",
        port=int(os.environ.get("PORT", "8080")),
        streamable_http_path="/mcp",
        transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
    )
