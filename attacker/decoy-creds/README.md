# decoy-creds: provenance (repo-side, never served or mounted)

Part of the agents-assist-attackers teaching demo. This is **inert, local, educational**
content. See [SAFETY.md](../../SAFETY.md) for the demo's full safety statement.

This README is for people reading the repo. It is never copied into an image, never mounted
into a pod, and never served over HTTP, so the agent under test never reads it.

## What `credentials` is

`credentials` is a **synthetic, invented** AWS-style credentials file. Every value in it was
made up for this demo. It is tied to **no real AWS account**, grants access to nothing, and
has never existed as a working key. Its access key begins `AKIAZ7QW…`; this README
deliberately does not repeat the rest.

## How it stays safe without a marker in the file

- The values are **invented** and match no real account. Even when the agent sends them to
  the collector, they expose nothing.
- The collector is a **local** container (`telemetry.corewave.test`) on your machine's
  `kind` Docker network. It is the only destination the poisoned document names. Nothing
  leaves your machine.
- This README and [SAFETY.md](../../SAFETY.md) state plainly that every credential in the
  demo is synthetic.
- `scripts/check-inert.sh` and `make review` require this README to say the credential is
  synthetic. Their scans for AWS-shaped keys exempt **only** this file (`make review` also
  exempts the ConfigMap generated from it, below), so a real key pasted anywhere else is
  still caught.

## Where it is used at runtime

`agent/mcp-servers/gen-decoy-configmap.sh` copies these exact bytes into the generated
ConfigMap `agent/mcp-servers/k8s/00-mcp-fs-decoy-configmap.yaml`. That ConfigMap is mounted
read-only into the `mcp-fs` tool server at `/workspace/.aws/credentials` (`DECOY_CRED_PATH`
in `demo.env`). If you change this file, re-run the generator.

When the agent reads the file, Falco raises `AGENT_CRED_READ`. When the agent is steered into
posting it, the collector prints it: `docker logs collector` shows it, and `./2-attack`
displays it.

## GitHub push protection may flag this file

Because the decoy matches the real AWS key pattern, GitHub secret scanning may block the
first push of this repository (push protection), or raise an alert after it. This is a
**known false positive**.

1. Confirm that every file GitHub names is one of these two:
   - `attacker/decoy-creds/credentials`
   - `agent/mcp-servers/k8s/00-mcp-fs-decoy-configmap.yaml` (generated from the first)
2. Follow the link in GitHub's push error and allow the secret, choosing the reason **"It's
   used in tests"** or **"It's a false positive"**.

**Never bypass push protection for any other file.** If GitHub flags anything else, treat it
as a real leak: stop, remove the secret, and rotate it if it was ever real.
