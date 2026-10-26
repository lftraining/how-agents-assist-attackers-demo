# mcp-fs: filesystem MCP server

Part of the agents-assist-attackers teaching demo.

A streamable-HTTP MCP server (`server.py`, built on the MCP Python SDK's `MCPServer`),
scoped to the `/workspace` root (`FS_WORKSPACE` in `demo.env`). Its underlying tools are
`read_text_file`, `list_directory`, `write_file`, and `create_directory`. These are the
names the gateway's authorization rules match on
([DEMO-GUIDE.md, A1](../../../DEMO-GUIDE.md#a1-agentgateway-deny-by-default-mcp-authorization)).

- The write tools let both runs build the deliverable under `DELIVERABLE_DIR`. The defended
  run still needs them; the controls remove the harm, not the work.
- Reads pass the literal path to `open()`, so Falco's `AGENT_CRED_READ` rule matches a read
  of the decoy at `/workspace/.aws/credentials`
  ([DEMO-GUIDE.md, A3](../../../DEMO-GUIDE.md#a3-falco-runtime-detection-on-the-credential-read)).
  The decoy is synthetic and invented; see
  [attacker/decoy-creds/README.md](../../../attacker/decoy-creds/README.md).

It runs as its own Deployment (`mcp-fs`, labels `app=mcp-fs` and `demo-role=fs`) behind
agentgateway; see [../k8s/](../k8s/README.md). Image: `mcp-fs:1.0.0`, built from this
directory's `Dockerfile` (digest-pinned base) by `scripts/build-images.sh`, loaded into the
kind node, and run with `imagePullPolicy: Never`.
