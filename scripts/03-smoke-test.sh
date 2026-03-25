#!/usr/bin/env bash
###############################################################################
# Script 03 — Smoke Test: End-to-End Inference
#
# Usage: ./03-smoke-test.sh [model]
#   model: phi4-mini (default) | phi3-mini | mistral-7b | llama3-8b | llama3-70b
#
# Tests the full chain:
#   1. Checks workspace is Ready
#   2. Runs a port-forward to the KAITO service
#   3. Sends an OpenAI-compatible /v1/chat/completions request
#   4. Checks KEDA ScaledObject status
#   5. Shows GPU utilization from DCGM metrics
###############################################################################
set -euo pipefail

MODEL=${1:-phi4-mini}

declare -A WORKSPACE_NAMES=(
  [phi4-mini]="workspace-phi4-mini"
  [phi3-mini]="workspace-phi3-mini-128k"
  [mistral-7b]="workspace-mistral-7b"
  [llama3-8b]="workspace-llama3-8b"
  [llama3-70b]="workspace-llama3-70b"
)

declare -A MODEL_IDS=(
  [phi4-mini]="phi-4-mini-instruct"
  [phi3-mini]="phi-3-mini-128k-instruct"
  [mistral-7b]="mistral-7b-instruct"
  [llama3-8b]="llama-3.1-8b-instruct"
  [llama3-70b]="llama-3.3-70b-instruct"
)

WS="${WORKSPACE_NAMES[$MODEL]}"
MODEL_ID="${MODEL_IDS[$MODEL]}"
NS="inference"
LOCAL_PORT=18000

echo "============================================================"
echo "  Smoke Test: $MODEL ($WS)"
echo "============================================================"

# ── 1: Workspace ready? ───────────────────────────────────────
echo -e "\n[1/5] Checking workspace status..."
STATUS=$(kubectl get workspace "$WS" -n "$NS" \
  -o jsonpath='{.status.conditions[?(@.type=="WorkspaceReady")].status}' 2>/dev/null || echo "Unknown")

if [[ "$STATUS" != "True" ]]; then
  echo "  ✗ Workspace $WS is not Ready (status: $STATUS)"
  echo "    Run: kubectl describe workspace $WS -n $NS"
  exit 1
fi
echo "  ✓ Workspace is Ready"

# ── 2: Port-forward ───────────────────────────────────────────
echo -e "\n[2/5] Starting port-forward (localhost:$LOCAL_PORT → $WS:5000)..."
kubectl port-forward "svc/$WS" "$LOCAL_PORT:5000" -n "$NS" &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null; exit" INT TERM EXIT

sleep 3  # Give port-forward time to establish

# ── 3: /v1/models ─────────────────────────────────────────────
echo -e "\n[3/5] Checking available models..."
MODELS=$(curl -sf "http://localhost:$LOCAL_PORT/v1/models" | jq -r '.data[].id')
echo "  Models served: $MODELS"

# ── 4: /v1/chat/completions ───────────────────────────────────
echo -e "\n[4/5] Sending test inference request..."
RESPONSE=$(curl -sf \
  -X POST "http://localhost:$LOCAL_PORT/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"$MODEL_ID\",
    \"messages\": [
      {\"role\": \"system\", \"content\": \"You are a Kubernetes expert.\"},
      {\"role\": \"user\",   \"content\": \"In one sentence, what does KEDA stand for and what does it do?\"}
    ],
    \"max_tokens\": 80,
    \"temperature\": 0.1
  }")

ANSWER=$(echo "$RESPONSE" | jq -r '.choices[0].message.content')
TTFT=$(echo "$RESPONSE"   | jq -r '.usage.completion_tokens // "N/A"')
echo ""
echo "  Model response:"
echo "  ──────────────────────────────────────────────────────────"
echo "  $ANSWER"
echo "  ──────────────────────────────────────────────────────────"
echo "  Completion tokens: $TTFT"

# ── 5: KEDA status ────────────────────────────────────────────
echo -e "\n[5/5] KEDA ScaledObjects status..."
kubectl get scaledobject -n "$NS" 2>/dev/null \
  || echo "  No ScaledObjects found in namespace $NS"

kubectl get httpscaledobject -n "$NS" 2>/dev/null \
  || echo "  No HTTPScaledObjects found"

echo ""
echo "  GPU nodes currently active:"
kubectl get nodes -l karpenter.azure.com/sku-family=NC \
  -o custom-columns="NAME:.metadata.name,SKU:.metadata.labels.karpenter\\.azure\\.com/sku-name,STATUS:.status.conditions[-1].type" \
  2>/dev/null || echo "  No GPU nodes found (NAP may have deprovisioned idle nodes)"

echo ""
echo "  ✓ Smoke test complete."
