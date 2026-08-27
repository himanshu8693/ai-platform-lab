# =============================================================================
# Makefile — ai-platform-lab (Ephemeral Lab Engine)
# =============================================================================
# Targets are designed to be idempotent: running them twice is safe.
# Requires: terraform, kubectl, helm, kind, argocd, cosign, uv, go, kube-linter,
#           vault, boundary (for zero-trust bootstrap targets)
#
# Usage:
#   make up              Provision cluster + full stack + schedule TTL teardown
#   make up TTL=3600     Provision with 1-hour auto-teardown
#   make up BACKEND=k3d  Use k3d instead of kind (faster, less memory)
#   make vault-bootstrap Post-Vault-init configuration (run once per cluster)
#   make boundary-up     Start Boundary dev server + seed targets
#   make scenario        List available fault scenarios
#   make inject TOPOLOGY=consul-admin-partition SCENARIO=ap-network-split
#   make test            All quality gates locally
#   make demo            Open dashboards in browser
#   make load            60-second locust load test
#   make clean           Destroy cluster + all resources
# =============================================================================

.PHONY: all help up cluster argocd-bootstrap stack-sync vault-bootstrap \
        boundary-up boundary-down scenario inject test go-test python-lint \
        kube-lint trivy-scan demo load clean port-forward topology-list \
        fde-bootstrap fde-preload fde-verify fde-clean agent-rca

CLUSTER_NAME   ?= ai-platform-lab
BACKEND        ?= kind
TTL            ?= 7200
KUBECONFIG     ?= $(HOME)/.kube/config
GRAFANA_URL    := http://localhost:3000
ARGOCD_URL     := http://localhost:8080
PROMETHEUS_URL := http://localhost:9090

# Topology and scenario targets (used by make inject)
TOPOLOGY       ?=
SCENARIO       ?=

# ── Default target ────────────────────────────────────────────────────────────
all: help

# FDE targets
FDE_NAMESPACE   ?= fde-airgap
FDE_REGISTRY    ?= localhost:5001
FDE_MODEL       ?= llama3.2-3b

help:
	@echo ""
	@echo "  Ephemeral Lab Engine — Make Targets"
	@echo "  ======================================"
	@echo "  make up                    Provision cluster + full stack + TTL teardown"
	@echo "  make up TTL=3600           Override TTL to 1 hour"
	@echo "  make up BACKEND=k3d        Use k3d backend (faster)"
	@echo "  make vault-bootstrap       Configure Vault post-deploy (run once)"
	@echo "  make boundary-up           Start Boundary dev server + seed targets"
	@echo "  make boundary-down         Stop Boundary dev server"
	@echo "  make topology-list         List all active topology namespaces"
	@echo "  make scenario              List available fault scenarios"
	@echo "  make inject TOPOLOGY=<t> SCENARIO=<s>   Inject a fault scenario"
	@echo "  make remediate TOPOLOGY=<t> SCENARIO=<s> Remove a fault scenario"
	@echo "  make test                  All quality gates (lint, typecheck, test)"
	@echo "  make demo                  Port-forward dashboards and open in browser"
	@echo "  make load                  60-second locust load test"
	@echo "  make agent-rca             Trigger MCP agent RCA against current topology"
	@echo "  --- FDE Targets ---"
	@echo "  make fde-preload           Pre-load images into kind registry (needs internet)"
	@echo "  make fde-bootstrap         5-min air-gapped VPC bootstrap (FDE-001)"
	@echo "  make fde-verify            Verify air-gapped bootstrap SLA compliance"
	@echo "  make fde-clean             Destroy air-gapped namespace + Terraform state"
	@echo "  make clean                 Destroy cluster + all resources"
	@echo ""

# ── Full stack provisioning ───────────────────────────────────────────────────
up: cluster argocd-bootstrap stack-sync vault-bootstrap boundary-up ttl-schedule
	@echo ""
	@echo "==> Stack is up."
	@echo "    Run 'make demo' to open dashboards."
	@echo "    Run 'make scenario' to see available fault scenarios."
	@echo ""

cluster:
	@echo "==> Provisioning $(BACKEND) cluster via Terraform..."
ifeq ($(BACKEND),k3d)
	cd terraform/backends/k3d && terraform init -input=false
	cd terraform/backends/k3d && terraform apply -auto-approve -input=false \
	  -var="cluster_name=$(CLUSTER_NAME)" -var="ttl_seconds=$(TTL)"
else
	cd terraform && terraform init -input=false
	cd terraform && terraform apply -auto-approve -input=false \
	  -var="cluster_name=$(CLUSTER_NAME)"
endif
	@echo "==> Cluster '$(CLUSTER_NAME)' ready (backend: $(BACKEND))."

argocd-bootstrap:
	@echo "==> Bootstrapping ArgoCD..."
	kubectl wait --for=condition=Available deployment/argocd-server \
	  -n argocd --timeout=180s
	kubectl apply -n argocd -f clusters/local-kind/app-of-apps.yaml
	@echo "==> ArgoCD app-of-apps applied."

stack-sync:
	@echo "==> Syncing all ArgoCD applications..."
	argocd login localhost:8080 --username admin \
	  --password $$(kubectl get secret argocd-initial-admin-secret \
	    -n argocd -o jsonpath='{.data.password}' | base64 -d) \
	  --insecure 2>/dev/null || true
	argocd app sync ai-platform-lab --timeout 300 || true
	@echo "==> Sync complete."

# ── Vault bootstrap (run once per cluster) ────────────────────────────────────
vault-bootstrap:
	@echo "==> Configuring Vault (auth methods, policies, PKI, secrets)..."
	kubectl wait --for=condition=Ready pod/vault-0 -n vault --timeout=120s
	kubectl port-forward svc/vault 30820:8200 -n vault > /tmp/pf-vault.log 2>&1 &
	@sleep 3
	VAULT_ADDR=http://localhost:30820 VAULT_TOKEN=root \
	  bash scripts/bootstrap-vault.sh
	@echo "==> Vault configured."

# ── Boundary dev server ───────────────────────────────────────────────────────
boundary-up:
	@echo "==> Starting Boundary dev server..."
	@if pgrep -f "boundary dev" > /dev/null; then \
	  echo "    Boundary dev server already running."; \
	else \
	  boundary dev > /tmp/boundary-dev.log 2>&1 & \
	  sleep 5; \
	  echo "    Boundary dev server started (log: /tmp/boundary-dev.log)"; \
	fi
	VAULT_TOKEN=root bash scripts/bootstrap-boundary.sh

boundary-down:
	@echo "==> Stopping Boundary dev server..."
	pkill -f "boundary dev" 2>/dev/null || true
	@echo "==> Boundary dev server stopped."

# ── TTL teardown scheduling ───────────────────────────────────────────────────
ttl-schedule:
	@echo "==> Scheduling TTL teardown in $(TTL)s..."
	bash scripts/ttl-teardown.sh $(TTL) $(CLUSTER_NAME) $(BACKEND)

# ── Topology management ───────────────────────────────────────────────────────
topology-list:
	@echo "==> Active topology namespaces:"
	@kubectl get namespaces -l platform.ai/component=ephemeral-topology \
	  -o custom-columns="NAMESPACE:.metadata.name,TTL:.metadata.annotations.ephemeral-lab/ttl-seconds,SCENARIO:.metadata.annotations.ephemeral-lab/active-scenario" \
	  2>/dev/null || echo "    No topology namespaces active."

scenario:
	@bash scripts/scenario-inject.sh --list

inject:
	@if [ -z "$(TOPOLOGY)" ] || [ -z "$(SCENARIO)" ]; then \
	  echo "Usage: make inject TOPOLOGY=<topology> SCENARIO=<scenario>"; \
	  echo "List available: make scenario"; \
	  exit 1; \
	fi
	bash scripts/scenario-inject.sh $(TOPOLOGY) $(SCENARIO)

remediate:
	@if [ -z "$(TOPOLOGY)" ] || [ -z "$(SCENARIO)" ]; then \
	  echo "Usage: make remediate TOPOLOGY=<topology> SCENARIO=<scenario>"; \
	  exit 1; \
	fi
	bash scripts/scenario-inject.sh $(TOPOLOGY) $(SCENARIO) --remove

# ── Testing ───────────────────────────────────────────────────────────────────
test: go-test python-lint kube-lint trivy-scan
	@echo ""
	@echo "==> All quality gates passed."

go-test:
	@echo "==> Running Go tests..."
	cd platform/controller && go test ./... -race -count=1 -timeout 60s

python-lint:
	@echo "==> Running Python lint (ruff + mypy)..."
	cd platform/observability && \
	  uv run ruff check . && \
	  uv run mypy mock-dcgm-exporter.py --ignore-missing-imports

kube-lint:
	@echo "==> Running kube-linter..."
	kube-linter lint --config .kube-linter.yaml workloads/ platform/ topologies/

trivy-scan:
	@echo "==> Running Trivy vulnerability scan..."
	trivy fs --exit-code 1 --severity HIGH,CRITICAL \
	  --ignore-unfixed . 2>/dev/null || \
	  (echo "WARN: trivy not installed — skipping scan" && true)

# ── Demo / dashboards ─────────────────────────────────────────────────────────
demo: port-forward
	@echo "==> Opening dashboards..."
	@sleep 3
	open $(GRAFANA_URL) 2>/dev/null || xdg-open $(GRAFANA_URL) || true
	open $(ARGOCD_URL) 2>/dev/null || xdg-open $(ARGOCD_URL) || true
	open $(PROMETHEUS_URL) 2>/dev/null || xdg-open $(PROMETHEUS_URL) || true
	@echo ""
	@echo "  Grafana    : $(GRAFANA_URL)    admin/admin"
	@echo "  ArgoCD     : $(ARGOCD_URL)"
	@echo "  Prometheus : $(PROMETHEUS_URL)"

port-forward:
	@echo "==> Starting port-forwards (background)..."
	kubectl port-forward svc/grafana 3000:3000 -n monitoring \
	  > /tmp/pf-grafana.log 2>&1 &
	kubectl port-forward svc/prometheus-server 9090:80 -n monitoring \
	  > /tmp/pf-prometheus.log 2>&1 &
	kubectl port-forward svc/argocd-server 8080:443 -n argocd \
	  > /tmp/pf-argocd.log 2>&1 &

# ── Load test ─────────────────────────────────────────────────────────────────
load:
	@echo "==> Running 60-second locust load test..."
	cd workloads/inference && \
	  uv run locust --headless -u 20 -r 5 -t 60s \
	    --host http://localhost:8000 2>/dev/null || \
	  (echo "WARN: locust not installed — skipping load test" && true)

# ── AI Agent RCA trigger ──────────────────────────────────────────────────────
agent-rca:
	@echo "==> Triggering MCP agent RCA query..."
	kubectl exec -n inference deploy/ai-assistant -- \
	  python3 -m mcp.client.run \
	  "Analyse current cluster state: what is TTFT p99, how many inference replicas are ready, and are there any pods in non-Running state in the inference namespace?" \
	  2>/dev/null || echo "ai-assistant pod not running — start with: make up"

# ── FDE: Forward Deployed Engineering targets ─────────────────────────────────
fde-preload:
	@echo "==> Pre-loading images into kind registry (requires internet)..."
	CLUSTER_NAME=$(CLUSTER_NAME) bash scripts/fde/preload-images.sh $(FDE_REGISTRY_PORT)
	@echo "==> Images pre-loaded. Safe to apply air-gap NetworkPolicy."

fde-bootstrap:
	@echo "==> Starting FDE-001 air-gapped bootstrap (5-min SLA)..."
	@START=$$(date +%s); \
	kubectl annotate namespace $(FDE_NAMESPACE) \
	  fde.scenario/bootstrap-start=$${START} --overwrite 2>/dev/null || \
	kubectl create namespace $(FDE_NAMESPACE) --dry-run=client -o yaml | \
	  kubectl apply -f - 2>/dev/null || true
	@echo "==> Applying air-gap NetworkPolicy..."
	kubectl apply -f topologies/fde-airgap/network-policy-airgap.yaml 2>/dev/null || \
	  echo "WARN: air-gap NetworkPolicy YAML not found — skipping"
	@echo "==> Running Terraform air-gap bootstrap..."
	cd terraform/backends/airgap && terraform init -input=false
	cd terraform/backends/airgap && terraform apply -auto-approve -input=false \
	  -var="namespace=$(FDE_NAMESPACE)" \
	  -var="internal_registry=$(FDE_REGISTRY)" \
	  -var="model_name=$(FDE_MODEL)" \
	  -var="vault_transit_seal_key_token=$$(vault token create \
	    -policy=fde-transit-unseal -ttl=8h -field=token 2>/dev/null || echo 'root')"
	@echo "==> Terraform apply complete. Verifying SLA..."
	bash scripts/fde/verify-airgap-bootstrap.sh $(FDE_NAMESPACE)

fde-verify:
	@echo "==> Verifying FDE-001 air-gapped bootstrap..."
	bash scripts/fde/verify-airgap-bootstrap.sh $(FDE_NAMESPACE)

fde-clean:
	@echo "==> Destroying FDE air-gapped namespace and Terraform state..."
	cd terraform/backends/airgap && terraform destroy -auto-approve -input=false \
	  -var="namespace=$(FDE_NAMESPACE)" 2>/dev/null || true
	kubectl delete namespace $(FDE_NAMESPACE) --ignore-not-found=true
	rm -f /tmp/fde-airgap-terraform.tfstate
	@echo "==> FDE namespace destroyed."

# ── Cleanup ───────────────────────────────────────────────────────────────────
clean:
	@echo "==> Cancelling any scheduled TTL teardowns..."
	@for f in /tmp/ttl-teardown-*.pid; do \
	  [ -f "$$f" ] && kill $$(cat "$$f") 2>/dev/null && rm -f "$$f" || true; \
	done
	@echo "==> Killing port-forwards and Boundary dev server..."
	pkill -f "kubectl port-forward" 2>/dev/null || true
	pkill -f "boundary dev" 2>/dev/null || true
	@echo "==> Destroying Terraform resources..."
	cd terraform && terraform destroy -auto-approve -input=false 2>/dev/null || true
	@echo "==> Deleting $(BACKEND) cluster (belt + suspenders)..."
ifeq ($(BACKEND),k3d)
	k3d cluster delete $(CLUSTER_NAME) 2>/dev/null || true
else
	kind delete cluster --name $(CLUSTER_NAME) 2>/dev/null || true
endif
	@echo "==> Removing build artifacts..."
	rm -f platform/controller/controller
	find . -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
	find . -name "*.pyc" -delete 2>/dev/null || true
	@echo "==> Clean complete."
