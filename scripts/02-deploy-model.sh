#!/usr/bin/env bash
###############################################################################
# Script 02 — Deploy a KAITO Model Workspace + InferencePool
#
# Usage:
#   ./02-deploy-model.sh phi4-mini     # cheapest, fastest
#   ./02-deploy-model.sh phi3-mini     # 128K context
#   ./02-deploy-model.sh mistral-7b    # balanced
#   ./02-deploy-model.sh llama3-8b     # best quality / single GPU
#   ./02-deploy-model.sh llama3-70b    # multi-node, 2x A100
#
# What happens:
#   1. Applies KAITO Workspace CRD → KAITO creates Deployment + Service
#   2. NAP detects pending GPU pod → provisions optimal VM → node joins
#   3. Pod schedules → model downloads → vLLM starts
#   4. Once workspace is Ready, applies InferencePool for the model
#      so Envoy Gateway can route to it with KV-cache-aware load balancing
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS="$(dirname "$SCRIPT_DIR")/manifests/kaito"
NETWORKING_MANIFESTS="$(dirname "$SCRIPT_DIR")/manifests/networking"
MODEL=${1:-phi4-mini}

declare -A MODEL_FILES=(
  [phi4-mini]="workspace-phi4-mini.yaml"
  [phi3-mini]="workspace-phi3-mini.yaml"
  [mistral-7b]="workspace-mistral-7b.yaml"
  [llama3-8b]="workspace-llama3-8b.yaml"
  [llama3-70b]="workspace-llama3-70b.yaml"
)

declare -A MODEL_POOLS=(
  [phi4-mini]="phi-4-mini-instruct"
  [phi3-mini]="phi-3-mini-128k-instruct"
  [mistral-7b]="mistral-7b-instruct"
  [llama3-8b]="llama-3.1-8b-instruct"
  [llama3-70b]="llama-3.3-70b-instruct"
)

declare -A MODEL_DESCRIPTIONS=(
  [phi4-mini]="Phi-4 Mini Instruct | GPU: 1x T4 (NC4as_T4_v3) | VRAM: 16GB | Est. provision: 4-6 min"
  [phi3-mini]="Phi-3 Mini 128K    | GPU: 1x T4 (NC8as_T4_v3)  | VRAM: 16GB | Est. provision: 4-6 min"
  [mistral-7b]="Mistral 7B Instruct| GPU: 1x T4 (NC16as_T4_v3) | VRAM: 16GB | Est. provision: 5-7 min"
  [llama3-8b]="Llama 3.1 8B       | GPU: 1x V100 (NC6s_v3)    | VRAM: 16GB | Est. provision: 6-8 min"
  [llama3-70b]="Llama 3.3 70B     | GPU: 2x A100 (NC24ads)    | VRAM: 160GB| Est. provision: 8-12 min"
)

if [[ -z "${MODEL_FILES[$MODEL]+_}" ]]; then
  echo "Unknown model: $MODEL"
  echo "Available: ${!MODEL_FILES[*]}"
  exit 1
fi

MANIFEST="${MANIFESTS}/${MODEL_FILES[$MODEL]}"
echo "============================================================"
echo "  Deploying: ${MODEL_DESCRIPTIONS[$MODEL]}"
echo "============================================================"
echo ""

kubectl apply -f "$MANIFEST"
echo "  Workspace CRD applied. Watching status..."
echo ""
echo "  NAP will now:"
echo "    1. Detect the pending pod (GPU resource request)"
echo "    2. Select a GPU SKU from the NodePool requirements"
echo "    3. Provision the VM → it joins the cluster"
echo "    4. Pod schedules → model downloads → vLLM starts"
echo ""

WORKSPACE_NAME=$(kubectl get -f "$MANIFEST" -o jsonpath='{.metadata.name}' 2>/dev/null | head -1)
echo "  Watching workspace: $WORKSPACE_NAME"
echo "  (Ctrl+C to exit watch — deployment continues in background)"
echo ""

for i in $(seq 1 60); do
  STATUS=$(kubectl get workspace "$WORKSPACE_NAME" -n inference \
    -o jsonpath='{.status.conditions[?(@.type=="WorkspaceReady")].status}' 2>/dev/null || echo "Pending")
  REASON=$(kubectl get workspace "$WORKSPACE_NAME" -n inference \
    -o jsonpath='{.status.conditions[?(@.type=="WorkspaceReady")].reason}' 2>/dev/null || echo "")
  NODE=$(kubectl get pods -n inference -l "app=$WORKSPACE_NAME" \
    -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || echo "not yet scheduled")

  echo "  [$(date +%H:%M:%S)] Status=$STATUS | Reason=$REASON | Node=$NODE"

  if [[ "$STATUS" == "True" ]]; then
    echo ""
    echo "  ✓ Workspace ready!"
    SVC=$(kubectl get svc -n inference "$WORKSPACE_NAME" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    echo "  Service ClusterIP: $SVC:5000"
    echo ""

    # Apply InferencePool so Envoy Gateway can route to this model
    echo "  Applying InferencePool for ${MODEL_POOLS[$MODEL]}..."
    sed \
      -e "s|<MODEL_NAME>|${MODEL_POOLS[$MODEL]}|g" \
      -e "s|<WORKSPACE_NAME>|$WORKSPACE_NAME|g" \
      "$NETWORKING_MANIFESTS/05-inference-pool.yaml" | kubectl apply -f -
    echo "  ✓ InferencePool created — Envoy Gateway will route /v1 to this model"
    echo ""
    echo "  Run: ./03-smoke-test.sh $MODEL"
    exit 0
  fi
  sleep 15
done

echo "  Workspace not ready after 15 min. Check:"
echo "    kubectl describe workspace $WORKSPACE_NAME -n inference"
echo "    kubectl get events -n inference --sort-by=.lastTimestamp"
