#!/usr/bin/env bash
# check-layout.sh — confirm the repo has every file the demo needs. Read-only.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
cd "$REPO_ROOT" || exit 1

REQUIRED=(
  README.md SAFETY.md DEMO-GUIDE.md Makefile demo.env .gitignore
  1-setup 2-attack 3-defend 4-rerun 5-reset
  scripts/lib/common.sh scripts/check-invariants.sh scripts/verify-fqdn-policy.sh
  scripts/smoke-test-falco.sh scripts/check-recipe.sh scripts/validate-policy.sh
  scripts/check-inert.sh scripts/check-layout.sh scripts/build-images.sh scripts/student-setup.sh scripts/render-config.sh
  scripts/set-model-key.sh scripts/check-model-key.sh scripts/verify-goose-sandbox.sh
  scripts/create-model-secret.sh scripts/check-model-secret.sh
  scripts/00-verify-kernel.sh scripts/01-install-tools.sh
  cluster/kind-config.yaml cluster/namespaces.yaml cluster/dns-probe.yaml cluster/cilium-install.sh cluster/coredns-custom.yaml cluster/readiness-check.sh
  registry/run-registry.sh registry/wire-registry-to-kind.sh
  skill-bundle/README.md skill-bundle/good-skill/SKILL.md skill-bundle/package-and-sign.sh skill-bundle/verify.sh
  skill-bundle/install-skill.sh skill-bundle/lib.sh attacker/tampered-skill/SKILL.md
  attacker/start-attacker.sh attacker/vendor-docs/Dockerfile attacker/vendor-docs/llms.txt
  attacker/vendor-docs/index.html attacker/collector/Dockerfile attacker/collector/listener.py
  attacker/decoy-creds/credentials
  agent/recipe.yaml agent/goose-job.yaml agent/run-task.sh agent/goose-image/Dockerfile
  agent/mcp-servers/k8s/README.md
  controls/agentgateway/deploy.yaml controls/agentgateway/mcp-authz-policy.yaml
  controls/agentgateway/apply-policy.sh controls/agentgateway/probe-deny.sh controls/cilium/goose-baseline-egress.yaml controls/cilium/egress-policy.yaml
  controls/falco/install.sh controls/falco/rules-agent.yaml
  scripts/reset.sh scripts/run-boundary.sh
)
REQUIRED_DIRS=(agent/mcp-servers/fs-server agent/mcp-servers/fetch-server agent/mcp-servers/http-post-server)

missing=0
for p in "${REQUIRED[@]}"; do [ -e "$p" ] || { echo "MISSING file  $p"; missing=1; }; done
for d in "${REQUIRED_DIRS[@]}"; do [ -d "$d" ] || { echo "MISSING dir   $d"; missing=1; }; done
if [ "$missing" -eq 0 ]; then echo "layout OK — all required paths present"; exit 0; fi
echo "layout NOT OK — create the missing paths above"; exit 1
