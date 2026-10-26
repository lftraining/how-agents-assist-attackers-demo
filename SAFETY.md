# Safety and responsible use

This is an educational, defensive security demo. It runs a real attack technique against a
real agent, and everything in it is **inert, local, and synthetic**:

- **The "attacker" is two containers on your own machine.** They publish no port and make
  no outbound connections. Nothing leaves your machine except the agent's calls to your
  model provider.
- **The poisoned vendor document is plain text.** It contains no code and does nothing on
  its own. The only harm is an agent following it to the local collector.
- **Every credential is synthetic and invented.** The decoy AWS-style key (`AKIAZ7QW…`) is
  made to look real so the agent treats it as real, but it belongs to no account and has
  never worked. See [attacker/decoy-creds/README.md](attacker/decoy-creds/README.md).
- **No real malicious samples are used.** The CVEs the demo discusses are mirrored, not
  reproduced or exploited.
- **The only real secret is your own model API key.** It stays in a file outside the repo
  and is passed only to the agent's pod.

The agent sends everything it reads to your model provider, including the decoy. To confirm
the attacker content is inert, run `bash scripts/check-inert.sh`.

## Your model key

- Set a spend limit on the key in your vendor account.
- Store the key with `make set-model-key`, in a file under `~/.demo-secrets/`.
- Never paste the key on a command line, into a repo file, or into an issue or chat.
- When you finish, delete the key file and revoke the key.

## Responsible use

By running this demo, you agree to:

- run it only on a machine you own or are authorized to use;
- keep the attacker side local, and never use a real credential as the decoy;
- never use the technique against systems you are not authorized to test, because poisoning
  documents or tools that real agents read is an attack on real people;
- never weaken a control to force the attack to work; and
- state that every credential shown is synthetic whenever you record or present the demo.

If you find anything in this repo that is not inert, local, or synthetic, stop using it and
report it by opening an issue in this repository.
