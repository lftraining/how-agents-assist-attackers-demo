# mcp-fetch: HTTP GET (fetch) MCP server

Part of the agents-assist-attackers teaching demo.

A streamable-HTTP MCP server (`server.py`) with one underlying tool, `fetch(url)`. The agent
uses it to retrieve the vendor docs, which the attacker controls. This is the "fetched at
runtime" class of supply-chain attack (see
[DEMO-GUIDE.md, section 12](../../../DEMO-GUIDE.md#12-why-this-is-realistic-the-real-incidents-it-mirrors)).

In the defended run, Cilium's egress policy lets this server reach only DNS and the vendor
docs host, so even a steered fetch cannot reach the collector or the internet
([DEMO-GUIDE.md, A2](../../../DEMO-GUIDE.md#a2-cilium-the-goose-fence-and-the-tool-server-egress-allowlist)).

It runs as its own Deployment (`mcp-fetch`, label `demo-role=fetch`) behind agentgateway;
see [../k8s/](../k8s/README.md). Image: `mcp-fetch:1.0.0` (digest-pinned base), built by
`scripts/build-images.sh`, loaded into the kind node, and run with
`imagePullPolicy: Never`.
