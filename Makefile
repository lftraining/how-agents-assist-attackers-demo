# Makefile — agents-assist-attackers
#
# Runs the component scripts in order. The logic lives in the scripts, and every demo
# target waits on a real readiness check, never a timer.
#
#   once:       make set-model-key       # choose a vendor and store your model key
#               make setup               # throwaway signing key, local registry, signed skill
#               make up                  # cluster, images, controls; waits until ready
#   run one:    make attack              # no controls: the decoy reaches the collector
#   defenses:   make defend              # turn the controls on and prove each one
#   run two:    make rerun               # the same recipe: contained, and the work completes
#   again:      make reset               # back to the clean starting state
#   finished:   make down CONFIRM=1      # delete everything the demo created
#
# The numbered scripts ./1-setup … ./5-reset wrap these targets. Every name and path comes
# from demo.env.

SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

include demo.env
# Your saved choices (written by `make set-model-key`) override demo.env. The `-` makes the
# file optional.
-include demo.local.env
# Pass every demo.env variable to the scripts.
export $(shell sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' demo.env demo.local.env 2>/dev/null | sort -u)

# --- Command shortcuts -------------------------------------------------------------
KC              := kubectl --context $(KUBE_CONTEXT)
READINESS       := bash cluster/readiness-check.sh
QUICK_READINESS := CHECK_SANDBOX=0 bash cluster/readiness-check.sh
RUN_TASK        := bash agent/run-task.sh
VERIFY_BUNDLE   := bash skill-bundle/verify.sh
GATEWAY_POLICY_APPLY := bash controls/agentgateway/apply-policy.sh

.PHONY: help setup images up readiness quick-readiness attack defend rerun verify verify-rekor \
        reset review set-model-key model-secret preflight lint layout down

# ---------------------------------------------------------------------------
help: ## Show this help (default target)
	@echo "agents-assist-attackers — targets:"
	@echo ""
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  \033[1m%-16s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo ""
	@echo "First time:  make set-model-key   make setup   make up"
	@echo "Then:        ./1-setup  ./2-attack  ./3-defend  ./4-rerun  ./5-reset"
	@echo "Finished:    make down CONFIRM=1"

# ---------------------------------------------------------------------------
# SETUP
# ---------------------------------------------------------------------------
setup: ## Create the throwaway signing key and local registry, and sign the skill offline
	bash scripts/student-setup.sh

images: ## Build the images and load them into the kind node (needs the cluster; make up runs it)
	bash scripts/build-images.sh

up: ## Create the cluster, images, controls, attacker containers, and verified skill; wait until ready
	@echo ">> make up — bringing the whole environment up (first run: several minutes)."
	# 1. Create the kind cluster without its default network plugin, so Cilium can replace it.
	kind get clusters 2>/dev/null | grep -qx "$(CLUSTER_NAME)" || \
	  kind create cluster --name "$(CLUSTER_NAME)" --config "$(KIND_CONFIG)"
	# 2. Build the images and load them into the node, so no pod pulls at run time.
	bash scripts/build-images.sh
	# 3. Create the namespaces.
	$(KC) apply -f cluster/namespaces.yaml
	# 4. Start the two attacker containers at fixed IPs on the kind network.
	bash attacker/start-attacker.sh
	# 5. Install Cilium, then fill the attacker IPs into the templates and apply the DNS entries.
	bash cluster/cilium-install.sh
	bash scripts/render-config.sh
	$(KC) apply -f $(RENDERED_DIR)/coredns-custom.yaml
	$(KC) -n $(COREDNS_NS) rollout restart deployment/coredns
	$(KC) -n $(COREDNS_NS) rollout status deployment/coredns --timeout=$(TIMEOUT)
	# 6. Install Falco.
	bash controls/falco/install.sh
	# 7. Sign the skill if needed, and confirm the registry is not wired into the cluster.
	bash scripts/student-setup.sh
	bash registry/wire-registry-to-kind.sh
	# 8. Install the skill with ToolHive, which refuses anything unsigned or altered.
	bash skill-bundle/install-skill.sh
	# 9. Deploy the gateway in open mode and the three MCP servers.
	$(KC) apply -f controls/agentgateway/deploy.yaml
	$(KC) apply -f $(MCP_MANIFESTS)/
	$(GATEWAY_POLICY_APPLY) --open
	# 10. Apply the always-on goose fence, rendered for your model vendor.
	$(KC) apply -f $(RENDERED_DIR)/goose-baseline-egress.yaml
	# 11. Create the model-key Secret. MODEL_KEY_FILE must be exported in this terminal.
	bash scripts/create-model-secret.sh
	# 12. Wait until everything is ready.
	$(READINESS)
	@echo ">> up complete and READY. Next: ./1-setup (or ./2-attack)"

# ---------------------------------------------------------------------------
readiness: ## Full readiness check, including the goose fence proof (about 30 s longer)
	$(READINESS)

quick-readiness: ## Readiness check without the goose fence proof (run before each demo step)
	$(QUICK_READINESS)

# ---------------------------------------------------------------------------
# RUN ONE — the compromise
# ---------------------------------------------------------------------------
attack: quick-readiness ## Run one: the recipe with no controls; the collector receives the decoy
	@echo ">> make attack — running $(RECIPE) (the ONE recipe, unchanged)."
	@echo "   No controls applied yet: the exfiltration should succeed."
	$(RUN_TASK)

# ---------------------------------------------------------------------------
# DEFENSES — apply the controls and prove each one
# ---------------------------------------------------------------------------
defend: quick-readiness ## Turn on the gateway policy and Cilium egress; prove them; refuse the tampered skill
	@echo ">> make defend — applying the deterministic controls."
	# Mark the run boundary, so anything below it in the collector log belongs to run two.
	bash scripts/run-boundary.sh
	# Switch the gateway to deny-by-default.
	$(GATEWAY_POLICY_APPLY) --defended
	# Limit each tool server's destinations. The collector is blocked because it is not listed.
	$(KC) apply -f controls/cilium/egress-policy.yaml
	# Check readiness again.
	$(QUICK_READINESS)
	# Prove the gateway control: the tool is gone, and a direct call is refused.
	bash controls/agentgateway/probe-deny.sh
	# Re-check the installed skill, then show the tampered copy being refused.
	$(VERIFY_BUNDLE) check
	$(VERIFY_BUNDLE) tamper
	@echo ">> defend complete — controls enforcing. Next: make rerun (or ./4-rerun)"

# ---------------------------------------------------------------------------
# RUN TWO — the contained re-run
# ---------------------------------------------------------------------------
rerun: quick-readiness ## Run two: the identical recipe; exfiltration blocked, the work completes
	@echo ">> make rerun — running the SAME $(RECIPE), byte-identical to the attack run."
	@echo "   Controls applied: http_post is denied, the collector stays empty,"
	@echo "   and the legitimate project setup still completes."
	$(RUN_TASK)
	# List the project the agent built, to show the controls removed the harm, not the work.
	@echo ""
	@echo ">> make rerun — the legitimate deliverable the agent built under the controls:"
	@$(KC) -n $(DEMO_NS) exec deploy/$(MCP_FS_DEPLOY) -- ls -la $(DELIVERABLE_DIR) \
	  || echo "   (deliverable dir $(DELIVERABLE_DIR) not found — did the run finish building it?)"

# ---------------------------------------------------------------------------
# EXTRA PROOFS
# ---------------------------------------------------------------------------
verify: ## Signing proof: the skill verifies, a tampered copy is refused, verification works offline
	$(VERIFY_BUNDLE) full

verify-rekor: ## Optional (TLOG_MODE=rekor only): check the signature in the public Rekor log
	$(VERIFY_BUNDLE) rekor

# ---------------------------------------------------------------------------
reset: ## Return to the clean starting state (controls off, collector empty, old Job gone)
	@echo ">> make reset — removing controls, clearing the collector, deleting the finished Job."
	bash scripts/reset.sh
	@echo ">> reset complete — pre-attack state."

# ---------------------------------------------------------------------------
review: ## Read-only audit of the demo's rules; fails on any BLOCKER
	bash scripts/check-invariants.sh

set-model-key: ## Choose your model vendor and store its key in MODEL_KEY_FILE (hidden prompt)
	bash scripts/set-model-key.sh

model-secret: ## Re-create the model-key Secret in namespace agent from MODEL_KEY_FILE
	bash scripts/create-model-secret.sh

preflight: readiness ## Full readiness, plus: key file private, Secret only in ns agent, key in no log
	@echo ">> make preflight — key and Secret audits."
	@bash scripts/check-model-key.sh --runtime
	@bash scripts/check-model-secret.sh
	@echo ">> preflight passed."

# ---------------------------------------------------------------------------
lint: ## Syntax-check every shell script (bash -n), plus shellcheck when installed
	@files="$$( { git ls-files -co --exclude-standard '*.sh' 2>/dev/null || find . -name '*.sh' -not -path './.git/*'; }; ls [1-5]-* )"; \
	fail=0; for f in $$files; do \
	  bash -n "$$f" || { echo "SYNTAX  $$f"; fail=1; }; \
	done; \
	if command -v shellcheck >/dev/null 2>&1; then \
	  shellcheck -x -S warning $$files || fail=1; \
	else echo "note: shellcheck not installed — bash -n only"; fi; \
	[ $$fail -eq 0 ] && echo "lint OK"

layout: ## Confirm every file the demo needs is present
	bash scripts/check-layout.sh

# ---------------------------------------------------------------------------
down: ## Delete everything the demo created (requires CONFIRM=1)
	@if [ "$${CONFIRM:-0}" != "1" ]; then \
	  echo "Refusing to delete the demo without confirmation. This removes the kind cluster"; \
	  echo "'$(CLUSTER_NAME)', the '$(COLLECTOR_CONTAINER)'/'$(VENDOR_DOCS_CONTAINER)'/'$(REGISTRY_NAME)' containers,"; \
	  echo "the '$(REGISTRY_NETWORK)' network and the '$(REGISTRY_VOLUME)' volume."; \
	  echo "Re-run:  make down CONFIRM=1"; exit 1; \
	fi
	@echo ">> make down CONFIRM=1 — deleting the demo cluster, containers, network and volume."
	kind delete cluster --name "$(CLUSTER_NAME)"
	# Remove only containers this project created, so a same-named container from another
	# project is left alone.
	@ids="$$(docker ps -aq --filter label=app.kubernetes.io/part-of=agents-assist-attackers)"; \
	  if [ -n "$$ids" ]; then docker rm -f $$ids >/dev/null; fi
	@vol="$$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/registry"}}{{.Name}}{{end}}{{end}}' "$(REGISTRY_NAME)" 2>/dev/null || true)"; \
	  if [ "$$vol" = "$(REGISTRY_VOLUME)" ]; then docker rm -f "$(REGISTRY_NAME)" >/dev/null; fi
	-docker network rm "$(REGISTRY_NETWORK)" >/dev/null 2>&1 || true
	-docker volume rm "$(REGISTRY_VOLUME)" >/dev/null 2>&1 || true
	@echo ">> down complete. Kept: your signing key in $${DEMO_SECRETS_DIR:-$$HOME/.demo-secrets/agents-assist-attackers}/"
	@echo "   and the built images. Start again with: make setup && make up"
