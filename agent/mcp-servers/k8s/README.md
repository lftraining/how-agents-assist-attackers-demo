# MCP server Kubernetes manifests

Part of the agents-assist-attackers teaching demo.

`make up` applies this directory with `kubectl apply -f agent/mcp-servers/k8s/`
(`MCP_MANIFESTS` in `demo.env`):

- `00-mcp-fs-decoy-configmap.yaml`: **generated** by `../gen-decoy-configmap.sh` from the
  single source `attacker/decoy-creds/credentials`, a synthetic, invented credential (see
  [its README](../../../attacker/decoy-creds/README.md)). It is mounted into `mcp-fs` with a
  `subPath` file mount, so the path the server opens is exactly `DECOY_CRED_PATH`, which is
  what Falco's rule matches
  ([DEMO-GUIDE.md, A3](../../../DEMO-GUIDE.md#a3-falco-runtime-detection-on-the-credential-read)).
  Re-run the generator if the decoy changes. GitHub push protection may flag this file for
  the same reason as the decoy; see the decoy README.
- `10-mcp-fs.yaml`, `20-mcp-fetch.yaml`, `30-mcp-http-post.yaml`: one Deployment and
  Service each, labelled `app=<name>` **and** `demo-role=<role>`. Cilium policies, Falco
  rules, and the test scripts select by `demo-role`, never `app`, so a throwaway test pod is
  never adopted (and deleted) by a Deployment's ReplicaSet.

Every pod runs as non-root with a read-only root filesystem, all capabilities dropped,
seccomp `RuntimeDefault`, and no ServiceAccount token. Each serves streamable-HTTP MCP on
`:8080/mcp`, and only agentgateway connects to them.
