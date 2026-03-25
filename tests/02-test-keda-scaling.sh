#!/usr/bin/env bash
###############################################################################
# Test 02 — KEDA Scale-Up / Scale-Down Verification
#
# Validates the full KEDA lifecycle:
#   1. Confirms the deployment is at 0 replicas (scale-to-zero state)
#   2. Sends a burst of requests via Service Bus queue
#   3. Watches KEDA scale the deployment from 0 → N
#   4. Waits for idle cooldown
#   5. Confirms KEDA scales back to 0
#
# What to watch for:
#   - ScaledObject READY=True and ACTIVE=True/False transitions
#   - Replica count going 0 → 1+ → 0
#   - How long the 0→1 transition takes (pod cold-start + model load)
#
# Usage:
#   ./02-test-keda-scaling.sh [servicebus-namespace] [queue-name] [message-count]
#   ./02-test-keda-scaling.sh aks-ai-lab-sb inference-requests 10
###############################################################################
set -euo pipefail

SB_NS=${1:-""}
QUEUE=${2:-inference-requests}
MSG_COUNT=${3:-10}
NS="inference"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${CYAN}  →${NC} $1"; }
pass()    { echo -e "${GREEN}  ✓${NC} $1"; }
fail()    { echo -e "${RED}  ✗${NC} $1"; }
section() { echo -e "\n${YELLOW}[$1]${NC} $2"; }

echo "============================================================"
echo "  Test 02: KEDA Scale-Up / Scale-Down"
echo "  Service Bus: $SB_NS | Queue: $QUEUE | Messages: $MSG_COUNT"
echo "============================================================"

# Resolve Service Bus namespace from Terraform if not provided
if [[ -z "$SB_NS" ]]; then
  TF_DIR="$(dirname "$(dirname "${BASH_SOURCE[0]}")")/terraform"
  if [[ -d "$TF_DIR" ]]; then
    SB_NS=$(terraform -chdir="$TF_DIR" output -raw servicebus_namespace 2>/dev/null || echo "")
  fi
  if [[ -z "$SB_NS" ]]; then
    echo "ERROR: Provide Service Bus namespace as first argument."
    echo "  Usage: ./02-test-keda-scaling.sh <sb-namespace>"
    exit 1
  fi
fi
RG=$(terraform -chdir="$(dirname "$(dirname "${BASH_SOURCE[0]}")")/terraform" \
  output -raw resource_group_name 2>/dev/null || echo "rg-aks-ai-lab")

# ── Phase 1: Verify scale-to-zero baseline ────────────────────────────────────
section "1/4" "Verify baseline: deployment at 0 replicas"

SCALEDOBJECT=$(kubectl get scaledobject -n "$NS" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -z "$SCALEDOBJECT" ]]; then
  fail "No ScaledObject found in namespace $NS"
  echo "  Apply KEDA manifests first: kubectl apply -f manifests/keda/"
  exit 1
fi

info "ScaledObject: $SCALEDOBJECT"

# Check KEDA ScaledObject readiness
READY=$(kubectl get scaledobject "$SCALEDOBJECT" -n "$NS" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
ACTIVE=$(kubectl get scaledobject "$SCALEDOBJECT" -n "$NS" \
  -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' 2>/dev/null)

if [[ "$READY" == "True" ]]; then
  pass "ScaledObject READY=True"
else
  fail "ScaledObject READY=$READY — check: kubectl describe scaledobject $SCALEDOBJECT -n $NS"
fi

# Get target deployment from ScaledObject
TARGET_DEPLOY=$(kubectl get scaledobject "$SCALEDOBJECT" -n "$NS" \
  -o jsonpath='{.spec.scaleTargetRef.name}' 2>/dev/null)
info "Target deployment: $TARGET_DEPLOY"

CURRENT_REPLICAS=$(kubectl get deployment "$TARGET_DEPLOY" -n "$NS" \
  -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
info "Current replicas: ${CURRENT_REPLICAS:-0}"

if [[ "${CURRENT_REPLICAS:-0}" -eq 0 ]]; then
  pass "Deployment is at 0 replicas (scale-to-zero confirmed)"
else
  echo -e "${YELLOW}  ⚠ Deployment has ${CURRENT_REPLICAS} replicas. Waiting for cooldown...${NC}"
  # Wait up to 10 min for scale-to-zero
  for i in $(seq 1 40); do
    sleep 15
    R=$(kubectl get deployment "$TARGET_DEPLOY" -n "$NS" \
      -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
    info "Waiting for 0 replicas... current: ${R:-0} (${i}/40)"
    if [[ "${R:-0}" -eq 0 ]]; then break; fi
  done
fi

# ── Phase 2: Send messages → trigger scale-up ─────────────────────────────────
section "2/4" "Sending $MSG_COUNT messages to Service Bus → trigger scale-up"

T_SEND_START=$(date +%s)
for i in $(seq 1 "$MSG_COUNT"); do
  az servicebus queue message send \
    --resource-group "$RG" \
    --namespace-name "$SB_NS" \
    --name "$QUEUE" \
    --body "{
      \"id\": $i,
      \"model\": \"phi-4-mini-instruct\",
      \"messages\": [{\"role\": \"user\", \"content\": \"Count to $i\"}],
      \"max_tokens\": 30
    }" --output none
done

T_SEND_END=$(date +%s)
pass "$MSG_COUNT messages sent in $(( T_SEND_END - T_SEND_START ))s"
info "KEDA polls every 15s — first scale-up within 15-30s..."

# ── Phase 3: Watch scale-up ───────────────────────────────────────────────────
section "3/4" "Watching KEDA scale-up (0 → N)"

T_SCALE_START=$(date +%s)
SCALED_UP=false

for i in $(seq 1 40); do
  sleep 5
  R=$(kubectl get deployment "$TARGET_DEPLOY" -n "$NS" \
    -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
  ACTIVE_NOW=$(kubectl get scaledobject "$SCALEDOBJECT" -n "$NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' 2>/dev/null)
  QUEUE_DEPTH=$(az servicebus queue show \
    --resource-group "$RG" \
    --namespace-name "$SB_NS" \
    --name "$QUEUE" \
    --query "countDetails.activeMessageCount" -o tsv 2>/dev/null || echo "?")

  printf "  [%ds] ACTIVE=%-5s replicas=%-3s queue-depth=%s\n" \
    "$(( (i*5) ))" "$ACTIVE_NOW" "${R:-0}" "$QUEUE_DEPTH"

  if [[ "${R:-0}" -gt 0 ]]; then
    T_SCALE_END=$(date +%s)
    SCALE_LAG=$(( T_SCALE_END - T_SEND_END ))
    pass "Scaled up to ${R} replica(s) — KEDA reaction time: ${SCALE_LAG}s after messages sent"
    SCALED_UP=true
    break
  fi
done

if [[ "$SCALED_UP" == "false" ]]; then
  fail "Deployment did not scale up within 200s"
  echo "  Debug:"
  echo "    kubectl describe scaledobject $SCALEDOBJECT -n $NS"
  echo "    kubectl logs -n keda -l app=keda-operator --tail=30"
  exit 1
fi

# ── Phase 4: Wait for cooldown → scale-to-zero ───────────────────────────────
section "4/4" "Waiting for cooldown → scale back to 0"
info "cooldownPeriod is 300s after queue empties. This will take 5-7 minutes..."
info "(Messages are consumed by workers; queue drains first)"

for i in $(seq 1 60); do
  sleep 10
  R=$(kubectl get deployment "$TARGET_DEPLOY" -n "$NS" \
    -o jsonpath='{.status.replicas}' 2>/dev/null || echo "?")
  QUEUE_DEPTH=$(az servicebus queue show \
    --resource-group "$RG" \
    --namespace-name "$SB_NS" \
    --name "$QUEUE" \
    --query "countDetails.activeMessageCount" -o tsv 2>/dev/null || echo "?")
  printf "  [%ds] replicas=%-3s queue-depth=%s\n" "$(( i*10 ))" "${R:-?}" "$QUEUE_DEPTH"

  if [[ "${R:-1}" -eq 0 ]]; then
    pass "Scaled back to 0 replicas after cooldown"
    break
  fi
done

echo ""
echo "============================================================"
echo "  KEDA scale-up/down test complete."
echo "  Key timings:"
echo "    Messages sent     → KEDA detected: ~15-30s (pollingInterval)"
echo "    KEDA detected     → Pod running:   varies (cold-start)"
echo "    Queue empty       → Scale-to-zero: cooldownPeriod (300s)"
echo "============================================================"
