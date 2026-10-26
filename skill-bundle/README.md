# skill-bundle/

Part of the agents-assist-attackers teaching demo. This directory holds the agent's skill and
the scripts that sign it, install it only if the signature verifies, and prove that a
tampered copy is refused. How it works, and its traps, are explained in
[DEMO-GUIDE.md, A5](../DEMO-GUIDE.md#a5-the-skill-supply-chain-sign-verify-before-load-refuse-a-tampered-copy).

## The skill

`good-skill/SKILL.md` is the legitimate skill the agent loads in **both** runs: the
fictional vendor's project conventions. It is written as real vendor content, with no mention
of the demo, because the model reads it on every run and a demo marker would change the
model's behavior. Everything in it is fictional, and every host is under `.test`.

## The flow

1. **`make setup`** (`scripts/student-setup.sh`):
   - creates a **throwaway** cosign key pair in `~/.demo-secrets/agents-assist-attackers/`
     if none exists (folder 0700, `cosign.key` 0600, no passphrase). It signs one local
     artifact that nothing else trusts. It is still a private key: it stays outside the
     repo and is never printed;
   - starts the local TLS registry on `127.0.0.1:5001` (`registry/run-registry.sh`);
   - runs `package-and-sign.sh`, which packages the skill in ToolHive's OCI format
     (`thv skill build`), pushes it to `localhost:5001/skills/corewave-sdk-conventions:1.0.0`,
     and signs it **by digest**. The digest is written to `bundle.digest` (gitignored).
2. **`make up`** runs `install-skill.sh`: `thv skill install <repo>@<digest> --public-key
   cosign.pub`. ToolHive installs the skill only if the signature on that exact digest
   verifies against the public key, and pins the key in its lock file. The installed copy,
   under `.runtime/goose-project/.claude/skills/corewave-sdk-conventions/`, is the one the
   goose pod mounts.
3. **`make defend`** (`./3-defend`) runs `verify.sh check` (read-only: the live tag still
   points at the signed digest, the signature verifies, and the installed copy is
   byte-identical to the signed artifact) and `verify.sh tamper` (below).
4. **`make verify`** runs `verify.sh full`: `check`, `tamper`, and an offline check.

`make setup` is idempotent. A second run reports `already signed: … — not re-signing`.

## Signing modes (`TLOG_MODE` in `demo.env`)

- **`none` (the default): offline.** `cosign sign --tlog-upload=false`, verified with
  `--insecure-ignore-tlog=true`. No public log entry is created and nothing leaves your
  machine, so re-signing after `make down CONFIRM=1` (which deletes the registry volume) is
  free: the next `make setup` signs again.
- **`rekor` (optional advanced exercise).** Uses your own passphrase-protected key and also
  records the signature in Sigstore's public Rekor transparency log. That entry is
  **permanent and public**. `make verify-rekor` checks it. See
  [DEMO-GUIDE.md, section 9](../DEMO-GUIDE.md#9-optional-sign-with-the-public-transparency-log-rekor).

## The tampered twin

`attacker/tampered-skill/SKILL.md` is a byte-for-byte copy of the good skill that differs
**only** in the one `@corewave:registry=` line, which points at an attacker's mirror (a
dependency-confusion substitution). `verify.sh tamper`:

- packages it exactly like the real skill and pushes it to the **scratch** repository
  `tamper-test/corewave-sdk-conventions` (`SKILL_TAMPER_REPO`), never the live repository;
- copies the publisher's genuine signature onto it;
- requires cosign to reject it and ToolHive to refuse to install it, both **for a signature
  reason**, and checks that nothing changed in the agent's skills folder.

A refusal for any other reason (registry down, wrong key path, wrong repository name) counts
as a failure, because it would prove nothing.

If you edit the good skill, regenerate the twin so it still differs by exactly that one line.

## What a signature proves

A valid signature proves **who** published these bytes and that they were **not changed**.
It does not prove that the content is safe. A malicious skill signed by a trusted publisher
would still install.
