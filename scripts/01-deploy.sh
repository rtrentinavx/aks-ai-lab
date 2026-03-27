#!/usr/bin/env bash
###############################################################################
# Script 01 — Deploy Infrastructure (Terraform) + Bootstrap Cluster
#
# What this does, step by step:
#   1. terraform apply   — AKS (Cilium CNI + NAP + KAITO + KEDA), Key Vault,
#                          Service Bus, managed identities, federated credentials,
#                          AGfC subnet + ALB controller identity
#   2. kubectl context   — fetches kubeconfig
#   3. Helm              — KEDA HTTP add-on, DCGM exporter
#   4. Cilium WireGuard  — enables node-to-node encryption
#   5. ALB Controller    — App Gateway for Containers in-cluster controller
#   6. Envoy Gateway     — in-cluster ingress + Inference Extension CRDs
#   7. Manifests         — namespace, workload identity, networking policies
#   8. Smoke tests       — verifies all components are running
###############################################################################
set -euo pipefail

# INFERENCE_MODE controls which inference backend is deployed:
#   gpu  (default) — KAITO/vLLM on GPU nodes via NAP
#   cpu             — Ollama with tinyllama on CPU nodes (slow but functional)
#   mock            — static HTTP echo, no model loaded (fastest, routing tests only)
#
# Usage: INFERENCE_MODE=cpu bash 01-deploy.sh
INFERENCE_MODE="${INFERENCE_MODE:-gpu}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TF_DIR="$ROOT_DIR/terraform"
MANIFESTS="$ROOT_DIR/manifests"

echo "============================================================"
echo "  AKS AI Lab — Deploy"
echo "  Inference mode: $INFERENCE_MODE"
echo "============================================================"

# ── Step 1: Terraform ─────────────────────────────────────────
echo -e "\n[1/8] Deploying infrastructure with Terraform..."
cd "$TF_DIR"

if [[ ! -f terraform.tfvars ]]; then
  echo "ERROR: terraform.tfvars not found."
  echo "  cp terraform.tfvars.example terraform.tfvars"
  echo "  Then fill in your subscription_id and other values."
  exit 1
fi

terraform init -upgrade
terraform plan -out=tfplan
terraform apply tfplan

RG_NAME=$(terraform output -raw resource_group_name)
CLUSTER_NAME=$(terraform output -raw aks_cluster_name)
KAITO_CLIENT_ID=$(terraform output -raw kaito_identity_client_id)
WORKLOAD_CLIENT_ID=$(terraform output -raw workload_identity_client_id)
KEDA_CLIENT_ID=$(terraform output -raw keda_identity_client_id)
ALB_CLIENT_ID=$(terraform output -raw alb_identity_client_id)
AGFC_SUBNET_ID=$(terraform output -raw agfc_subnet_id)
KV_NAME=$(terraform output -raw key_vault_uri | sed 's|https://||' | sed 's|.vault.azure.net/||')
SB_NAMESPACE=$(terraform output -raw servicebus_namespace 2>/dev/null || echo "")
TENANT_ID=$(az account show --query tenantId -o tsv)

echo "  Cluster: $CLUSTER_NAME | RG: $RG_NAME"

# ── Step 2: kubeconfig ────────────────────────────────────────
echo -e "\n[2/8] Fetching kubeconfig..."

# kubelogin is required for AAD-enabled clusters (azure_active_directory_role_based_access_control).
# az aks get-credentials writes a kubeconfig that references kubelogin as a credential plugin.
if ! command -v kubelogin &>/dev/null; then
  echo "  Installing kubelogin (required for AAD-enabled AKS)..."
  if command -v brew &>/dev/null; then
    brew install Azure/kubelogin/kubelogin
  else
    # Linux fallback
    az aks install-cli 2>/dev/null || true
  fi
fi

for attempt in 1 2 3; do
  if az aks get-credentials \
      --resource-group "$RG_NAME" \
      --name "$CLUSTER_NAME" \
      --overwrite-existing; then
    break
  fi
  echo "  Attempt $attempt failed, retrying in 30s..."
  sleep 30
  [[ $attempt -eq 3 ]] && { echo "ERROR: could not fetch kubeconfig after 3 attempts"; exit 1; }
done

# Convert kubeconfig to use Azure CLI auth (no interactive browser popup in CI).
kubelogin convert-kubeconfig -l azurecli

kubectl get nodes

# ── Step 3: Helm — KEDA HTTP Add-on + DCGM ───────────────────
echo -e "\n[3/8] Installing KEDA HTTP add-on and DCGM exporter..."

helm repo add kedacore https://kedacore.github.io/charts
helm repo add gpu-helm-charts https://nvidia.github.io/dcgm-exporter/helm-charts
helm repo update kedacore gpu-helm-charts

helm upgrade --install http-add-on kedacore/keda-add-ons-http \
  --namespace keda \
  --create-namespace \
  --set interceptor.replicas.min=2 \
  --set interceptor.replicas.max=5 \
  --set-json 'interceptor.tolerations=[{"key":"CriticalAddonsOnly","operator":"Exists","effect":"NoSchedule"}]' \
  --set-json 'scaler.tolerations=[{"key":"CriticalAddonsOnly","operator":"Exists","effect":"NoSchedule"}]' \
  --set-json 'operator.tolerations=[{"key":"CriticalAddonsOnly","operator":"Exists","effect":"NoSchedule"}]' \
  --wait --timeout=5m

if [[ "$INFERENCE_MODE" == "gpu" ]]; then
  helm upgrade --install dcgm-exporter gpu-helm-charts/dcgm-exporter \
    --namespace monitoring \
    --create-namespace \
    --set serviceMonitor.enabled=false \
    --set tolerations[0].key=nvidia.com/gpu \
    --set tolerations[0].operator=Exists \
    --set tolerations[0].effect=NoSchedule
  # No --wait: DCGM pods schedule on GPU nodes provisioned on-demand by NAP
else
  echo "  Skipping DCGM GPU exporter (INFERENCE_MODE=$INFERENCE_MODE)"
fi

# ── Step 4: Cilium WireGuard ──────────────────────────────────
echo -e "\n[4/8] Enabling Cilium WireGuard node-to-node encryption..."

kubectl -n kube-system patch configmap cilium-config \
  --type merge \
  -p '{"data":{"enable-wireguard":"true","enable-wireguard-userspace-fallback":"true"}}'

# Restart Cilium to apply encryption config
kubectl -n kube-system rollout restart daemonset/cilium
kubectl -n kube-system rollout status daemonset/cilium --timeout=5m
echo "  ✓ WireGuard encryption enabled"

# ── Step 5: ALB Controller ────────────────────────────────────
echo -e "\n[5/8] Installing App Gateway for Containers ALB controller..."

helm upgrade --install alb-controller \
  oci://mcr.microsoft.com/application-lb/charts/alb-controller \
  --namespace azure-alb-system \
  --create-namespace \
  --version 1.9.16 \
  --set albController.namespace=azure-alb-system \
  --set albController.podIdentity.clientID="$ALB_CLIENT_ID" \
  --set-json 'albController.controller.tolerations=[{"key":"CriticalAddonsOnly","operator":"Exists","effect":"NoSchedule"}]' \
  --wait --timeout=5m

echo "  ✓ ALB controller installed"
echo "  AGfC subnet ID: $AGFC_SUBNET_ID"
echo "  To create an ApplicationLoadBalancer resource, apply:"
echo "    manifests/ingress/2-app-gateway-containers.yaml (after setting subnet ID)"

# ── Step 6: Envoy Gateway + Inference Extension ───────────────
echo -e "\n[6/8] Installing Envoy Gateway and Inference Extension CRDs..."

# Gateway API standard CRDs — apply first with server-side to avoid field-manager
# conflicts when Helm or Istio has already touched these CRDs
kubectl apply --server-side --force-conflicts -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml

# Envoy Gateway CRDs — helm upgrade never re-applies crds/ on subsequent runs,
# so stream them directly from the chart on every deploy (idempotent).
helm show crds oci://docker.io/envoyproxy/gateway-helm --version v1.3.0 \
  | kubectl apply --server-side --force-conflicts -f -

helm upgrade --install eg \
  oci://docker.io/envoyproxy/gateway-helm \
  --version v1.3.0 \
  --namespace envoy-gateway-system \
  --create-namespace \
  --skip-crds \
  --set-json 'deployment.pod.tolerations=[{"key":"CriticalAddonsOnly","operator":"Exists","effect":"NoSchedule"}]' \
  --set-json 'certgen.job.tolerations=[{"key":"CriticalAddonsOnly","operator":"Exists","effect":"NoSchedule"}]' \
  --wait --timeout=5m

echo "  ✓ Envoy Gateway installed"

# Inference Extension CRDs (InferencePool, InferenceModel) + EPP deployment
kubectl apply --server-side --force-conflicts -f \
  https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/v0.5.0/manifests.yaml

echo "  ✓ Inference Extension CRDs installed"

# Namespace must exist before Gateway (Gateway is scoped to the inference namespace)
kubectl apply -f "$MANIFESTS/kaito/namespace.yaml"

# Apply GatewayClass and internal Gateway
kubectl apply -f "$MANIFESTS/networking/01-gateway-class.yaml"
kubectl apply -f "$MANIFESTS/networking/02-gateway.yaml"

# ── Step 7: Manifests ─────────────────────────────────────────
echo -e "\n[7/8] Applying namespace, workload identity, and networking manifests..."

sed \
  -e "s|<WORKLOAD_IDENTITY_CLIENT_ID>|$WORKLOAD_CLIENT_ID|g" \
  -e "s|<AZURE_TENANT_ID>|$TENANT_ID|g" \
  "$MANIFESTS/workload-identity/serviceaccount.yaml" | kubectl apply -f -

sed \
  -e "s|<WORKLOAD_IDENTITY_CLIENT_ID>|$WORKLOAD_CLIENT_ID|g" \
  -e "s|<KEY_VAULT_NAME>|$KV_NAME|g" \
  -e "s|<AZURE_TENANT_ID>|$TENANT_ID|g" \
  "$MANIFESTS/workload-identity/secret-provider-class.yaml" | kubectl apply -f -

sed \
  -e "s|<KEDA_IDENTITY_CLIENT_ID>|$KEDA_CLIENT_ID|g" \
  "$MANIFESTS/workload-identity/keda-trigger-auth.yaml" | kubectl apply -f -

# Cilium network policies
kubectl apply -f "$MANIFESTS/networking/03-cilium-network-policy.yaml"

# Wait for Envoy Gateway CRDs to be fully registered before applying resources
kubectl wait --for=condition=Established \
  crd/backendtrafficpolicies.gateway.envoyproxy.io \
  crd/clienttrafficpolicies.gateway.envoyproxy.io \
  --timeout=60s

kubectl apply -f "$MANIFESTS/networking/04-backend-traffic-policy.yaml"

# Deploy inference backend based on mode
case "$INFERENCE_MODE" in
  mock)
    echo "  Deploying mock inference server..."
    kubectl apply -f "$MANIFESTS/vllm/mock-inference.yaml"
    echo "  ✓ Mock inference ready (stateless echo, no model)"
    ;;
  cpu)
    echo "  Deploying Ollama CPU inference (tinyllama — slow but functional)..."
    kubectl apply -f "$MANIFESTS/vllm/ollama-cpu.yaml"
    echo "  ✓ Ollama deploying — model pull happens in initContainer, may take a few minutes"
    ;;
  gpu)
    echo "  GPU mode: run 02-deploy-model.sh to deploy a KAITO workspace"
    ;;
  *)
    echo "ERROR: unknown INFERENCE_MODE '$INFERENCE_MODE'. Use: gpu | cpu | mock" >&2
    exit 1
    ;;
esac

# ── Step 8: Smoke Tests ───────────────────────────────────────
echo -e "\n[8/8] Running smoke tests..."

check_running() {
  local label=$1; local ns=$2
  local count; count=$(kubectl get pods -n "$ns" -l "$label" \
    --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
  if [[ $count -gt 0 ]]; then
    echo "  ✓ $label ($count pod(s))"
  else
    echo "  ✗ $label — no running pods in namespace $ns"
  fi
}

check_running "app=keda-operator"                                          keda
check_running "app.kubernetes.io/name=keda-add-ons-http-interceptor"      keda
check_running "app.kubernetes.io/name=kaito-workspace"                    kube-system
check_running "app.kubernetes.io/name=alb-controller"                     azure-alb-system
check_running "app.kubernetes.io/name=envoy-gateway"                      envoy-gateway-system

kubectl get nodepool 2>/dev/null \
  && echo "  ✓ NAP NodePool CRD available" \
  || echo "  ✗ NAP NodePool CRD not found"

kubectl get gatewayclass envoy-gateway 2>/dev/null \
  && echo "  ✓ Envoy GatewayClass installed" \
  || echo "  ✗ Envoy GatewayClass not found"

kubectl get crd inferencepools.inference.networking.x-k8s.io 2>/dev/null \
  && echo "  ✓ Inference Extension CRDs installed" \
  || echo "  ✗ Inference Extension CRDs not found"

echo ""
echo "============================================================"
echo "  Infrastructure deployed. Next: run 02-deploy-model.sh"
echo "============================================================"
echo ""
echo "  Key values (save these):"
echo "  WORKLOAD_CLIENT_ID = $WORKLOAD_CLIENT_ID"
echo "  KEDA_CLIENT_ID     = $KEDA_CLIENT_ID"
echo "  KAITO_CLIENT_ID    = $KAITO_CLIENT_ID"
echo "  ALB_CLIENT_ID      = $ALB_CLIENT_ID"
echo "  AGFC_SUBNET_ID     = $AGFC_SUBNET_ID"
echo "  KEY_VAULT_NAME     = $KV_NAME"
[[ -n "$SB_NAMESPACE" ]] && echo "  SB_NAMESPACE       = $SB_NAMESPACE" || echo "  SB_NAMESPACE       = (disabled — set enable_service_bus=true to deploy)"
echo "  TENANT_ID          = $TENANT_ID"
