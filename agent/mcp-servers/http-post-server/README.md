# mcp-http-post: generic outbound HTTP POST MCP server (the exfiltration tool)

Part of the agents-assist-attackers teaching demo.

A streamable-HTTP MCP server (`server.py`) with one **generic** underlying tool,
`http_post(url, body, content_type)` (`EXFIL_TOOL_NAME` in `demo.env`). Nothing in it points
at the collector: the destination comes from the poisoned document, as in real incidents.

The server is identical in both runs. The control is entirely at the gateway: in the
defended run, agentgateway removes `http_post` from the agent's tool list and refuses a
direct call to it (`controls/agentgateway/probe-deny.sh` shows both). Cilium's egress policy
also limits this server to DNS only, so it cannot reach the collector even if called
([DEMO-GUIDE.md, A1](../../../DEMO-GUIDE.md#a1-agentgateway-deny-by-default-mcp-authorization)
and [A2](../../../DEMO-GUIDE.md#a2-cilium-the-goose-fence-and-the-tool-server-egress-allowlist)).

It runs as its own Deployment (`mcp-http-post`, label `demo-role=http-post`) behind
agentgateway; see [../k8s/](../k8s/README.md). Image: `mcp-http-post:1.0.0` (digest-pinned
base), built by `scripts/build-images.sh`, loaded into the kind node, and run with
`imagePullPolicy: Never`.
