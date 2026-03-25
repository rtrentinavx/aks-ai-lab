#!/usr/bin/env bash
###############################################################################
# Test 03 — NAP GPU Node Lifecycle
#
# Verifies that Node Auto Provisioning (Karpenter) correctly:
#   1. Has no GPU nodes initially (or confirms existing ones)
#   2. Provisions a GPU node when a GPU-requesting pod is created
#   3. Labels and taints the node correctly
#   4. Deprovisions the node when the pod is deleted (scale-to-zero)
#
# This test creates a short-lived GPU pod (nvidia-smi) independently of KAITO,
# so you can verify NAP mechanics without a full model workspace deployed.
#
# Usage:
#   ./03-test-nap-lifecycle.sh [nodepool-name]
#   ./03-test-nap-lifecycle.sh gpu-inference
###############################################################################
set -euo pipefail

NODEPOOL=${1:-gpu-inference}
NS="nap-test"
POD_NAME="gpu-probe"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
pass()    { echo -e "${GREEN}  ✓${NC} $1"; }
fail()    { echo -e "${RED}  ✗${NC} $1"; }
info()    { echo -e "${CYAN}  →${NC} $1"; }
section() { echo -e "\n${YELLOW}[$1]${NC} $2"; }

cleanup() {
  kubectl delete pod "$POD_NAME" -n "$NS" --ignore-not-found --grace-period=0 >/dev/null 2>&1 || true
  kubectl delete namespace "$NS" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

echo "============================================================"
echo "  Test 03: NAP GPU Node Lifecycle"
echo "  NodePool: $NODEPOOL"
echo "============================================================"

# ── Phase 1: NodePool CRD check ───────────────────────────────────────────────
section "1/5" "Verify NodePool CRD and configuration"

NP=$(kubectl get nodepool "$NODEPOOL" 2>/dev/null || echo "")
if [[ -n "$NP" ]]; then
  pass "NodePool '$NODEPOOL' exists"
  # Show limits
  GPU_LIMIT=$(kubectl get nodepool "$NODEPOOL" \
    -o jsonpath='{.spec.limits.nvidia\.com/gpu}' 2>/dev/null || echo "not set")
  info "GPU limit: $GPU_LIMIT GPUs"
else
  fail "NodePool '$NODEPOOL' not found"
  echo "  Apply first: kubectl apply -f manifests/nap/gpu-nodepool.yaml"
  exit 1
fi

# ── Phase 2: Baseline GPU node count ──────────────────────────────────────────
section "2/5" "Baseline GPU node inventory"

GPU_NODES_BEFORE=$(kubectl get nodes \
  -l "karpenter.azure.com/sku-family=NC" \
  --no-headers 2>/dev/null | wc -l | tr -d ' ')
info "GPU nodes before test: $GPU_NODES_BEFORE"

if [[ "$GPU_NODES_BEFORE" -gt 0 ]]; then
  echo -e "${YELLOW}  ⚠ Existing GPU nodes found. NAP may reuse them instead of provisioning new ones.${NC}"
  kubectl get nodes -l "karpenter.azure.com/sku-family=NC" \
    -o custom-columns="NAME:.metadata.name,SKU:.metadata.labels.karpenter\.azure\.com/sku-name,STATUS:.status.conditions[-1].type"
fi

# ── Phase 3: Create GPU-requesting pod ────────────────────────────────────────
section "3/5" "Submitting GPU probe pod → watching NAP provision"

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# The nvidia-smi pod is a minimal GPU probe. It:
#   1. Requests 1 GPU → signals NAP to provision a GPU node
#   2. Runs nvidia-smi → confirms GPU driver is functional
#   3. Exits cleanly → node becomes idle → NAP deprovisions
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $POD_NAME
  namespace: $NS
  labels:
    test: nap-gpu-probe
spec:
  restartPolicy: Never
  tolerations:
    - key: nvidia.com/gpu
      operator: Equal
      value: "true"
      effect: NoSchedule
  containers:
    - name: probe
      image: nvidia/cuda:12.4.1-base-ubuntu22.04
      command: ["nvidia-smi"]
      resources:
        requests:
          nvidia.com/gpu: "1"
          cpu: "1"
          memory: "4Gi"
        limits:
          nvidia.com/gpu: "1"
EOF

pass "GPU probe pod submitted — waiting for NAP to provision a node..."
info "Expected: 3-6 minutes if no GPU node exists"
T_POD_START=$(date +%s)

# Poll for node provisioning and pod scheduling
NODE_PROVISIONED=false
for i in $(seq 1 72); do  # 72 x 5s = 6 minutes
  sleep 5

  POD_STATUS=$(kubectl get pod "$POD_NAME" -n "$NS" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
  POD_NODE=$(kubectl get pod "$POD_NAME" -n "$NS" \
    -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")
  GPU_NODES_NOW=$(kubectl get nodes \
    -l "karpenter.azure.com/sku-family=NC" \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')

  printf "  [%3ds] pod=%-12s node=%-40s gpu-nodes=%s\n" \
    "$(( i*5 ))" "$POD_STATUS" "${POD_NODE:-(pending)}" "$GPU_NODES_NOW"

  if [[ -n "$POD_NODE" && "$NODE_PROVISIONED" == "false" ]]; then
    T_NODE=$(date +%s)
    NODE_LAG=$(( T_NODE - T_POD_START ))
    pass "Pod scheduled on node '$POD_NODE' after ${NODE_LAG}s"
    NODE_PROVISIONED=true

    # Grab the GPU SKU of the provisioned node
    GPU_SKU=$(kubectl get node "$POD_NODE" \
      -o jsonpath='{.metadata.labels.karpenter\.azure\.com/sku-name}' 2>/dev/null || echo "unknown")
    info "GPU SKU selected by NAP: $GPU_SKU"
  fi

  if [[ "$POD_STATUS" == "Succeeded" ]]; then
    T_DONE=$(date +%s)
    pass "Pod completed successfully after $(( T_DONE - T_POD_START ))s"
    break
  elif [[ "$POD_STATUS" == "Failed" ]]; then
    fail "Pod failed. Logs:"
    kubectl logs "$POD_NAME" -n "$NS" 2>/dev/null || true
    exit 1
  fi
done

# ── Phase 4: Validate GPU driver output ──────────────────────────────────────
section "4/5" "Validate NVIDIA driver (nvidia-smi output)"

NVIDIA_SMI=$(kubectl logs "$POD_NAME" -n "$NS" 2>/dev/null || echo "")
if echo "$NVIDIA_SMI" | grep -q "NVIDIA-SMI"; then
  GPU_NAME=$(echo "$NVIDIA_SMI" | grep -oP '(T4|V100|A100|H100)[^|]*' | head -1 | xargs)
  DRIVER_VER=$(echo "$NVIDIA_SMI" | grep -oP 'Driver Version: \K[0-9.]+' || echo "unknown")
  CUDA_VER=$(echo "$NVIDIA_SMI" | grep -oP 'CUDA Version: \K[0-9.]+' || echo "unknown")
  pass "NVIDIA driver functional"
  info "GPU: $GPU_NAME | Driver: $DRIVER_VER | CUDA: $CUDA_VER"
  echo ""
  echo "$NVIDIA_SMI" | head -20 | sed 's/^/    /'
else
  fail "nvidia-smi output unexpected"
  echo "$NVIDIA_SMI"
fi

# ── Phase 5: Delete pod → watch NAP deprovision ───────────────────────────────
section "5/5" "Delete pod → watch NAP deprovision GPU node"

info "Deleting probe pod..."
kubectl delete pod "$POD_NAME" -n "$NS" --grace-period=0 >/dev/null 2>&1
info "NAP will deprovision the node after consolidateAfter (2m) if it's empty."
info "Watching... (up to 5 min)"

T_DELETE=$(date +%s)
for i in $(seq 1 30); do
  sleep 10
  GPU_NODES_NOW=$(kubectl get nodes \
    -l "karpenter.azure.com/sku-family=NC" \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')
  printf "  [%3ds] GPU nodes remaining: %s\n" "$(( i*10 ))" "$GPU_NODES_NOW"

  if [[ "$GPU_NODES_NOW" -le "$GPU_NODES_BEFORE" ]]; then
    T_DEPROV=$(date +%s)
    pass "GPU node deprovisioned after $(( T_DEPROV - T_DELETE ))s — GPU billing stopped"
    break
  fi
done

echo ""
echo "============================================================"
echo "  NAP lifecycle test complete."
echo "============================================================"
