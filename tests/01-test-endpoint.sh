#!/usr/bin/env bash
###############################################################################
# Test 01 — vLLM Endpoint Validation
#
# Verifies the inference server is responding correctly at every API surface:
#   /health              — liveness check
#   /v1/models           — model registry
#   /v1/completions      — legacy text completion
#   /v1/chat/completions — chat API (OpenAI-compatible)
#   /metrics             — Prometheus metrics exposure
#
# Usage:
#   ./01-test-endpoint.sh [workspace-name] [namespace]
#   ./01-test-endpoint.sh workspace-phi4-mini inference
#   ./01-test-endpoint.sh workspace-mistral-7b inference
#
# The script port-forwards automatically — no Ingress or LoadBalancer needed.
###############################################################################
set -euo pipefail

WS=${1:-workspace-phi4-mini}
NS=${2:-inference}
PORT=19000
BASE="http://localhost:$PORT"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS=0; FAIL=0

pass() { echo -e "${GREEN}  ✓ PASS${NC} — $1"; ((PASS++)); }
fail() { echo -e "${RED}  ✗ FAIL${NC} — $1"; ((FAIL++)); }
info() { echo -e "${CYAN}  →${NC} $1"; }
section() { echo -e "\n${YELLOW}[$1]${NC} $2"; }

# ── Setup: port-forward ───────────────────────────────────────────────────────
echo "============================================================"
echo "  Test 01: vLLM Endpoint Validation"
echo "  Workspace: $WS  |  Namespace: $NS"
echo "============================================================"

# Detect service port (KAITO uses 5000, standalone vLLM uses 8000)
SVC_PORT=$(kubectl get svc "$WS" -n "$NS" \
  -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "5000")
info "Service $WS:$SVC_PORT → localhost:$PORT"

kubectl port-forward "svc/$WS" "$PORT:$SVC_PORT" -n "$NS" \
  --address 127.0.0.1 >/dev/null 2>&1 &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null; echo '  Port-forward closed.'" EXIT INT TERM

# Wait for port-forward to be ready
for i in $(seq 1 15); do
  if curl -sf --max-time 2 "$BASE/health" >/dev/null 2>&1; then break; fi
  sleep 1
done

# ── Test 1: Health ────────────────────────────────────────────────────────────
section "1/6" "Health check"
HTTP=$(curl -so /dev/null -w "%{http_code}" --max-time 5 "$BASE/health" 2>/dev/null)
if [[ "$HTTP" == "200" ]]; then
  pass "/health returned HTTP 200"
else
  fail "/health returned HTTP $HTTP (expected 200)"
fi

# ── Test 2: Models list ───────────────────────────────────────────────────────
section "2/6" "Model registry"
MODELS_JSON=$(curl -sf --max-time 5 "$BASE/v1/models" 2>/dev/null || echo "{}")
MODEL_COUNT=$(echo "$MODELS_JSON" | jq '.data | length' 2>/dev/null || echo "0")
MODEL_ID=$(echo "$MODELS_JSON" | jq -r '.data[0].id // "none"' 2>/dev/null)

if [[ "$MODEL_COUNT" -gt 0 ]]; then
  pass "/v1/models returned $MODEL_COUNT model(s)"
  info "Model ID: $MODEL_ID"
else
  fail "/v1/models returned no models"
  MODEL_ID="unknown"
fi

# ── Test 3: Text completion ───────────────────────────────────────────────────
section "3/6" "Legacy completion (/v1/completions)"
COMP=$(curl -sf --max-time 60 \
  -X POST "$BASE/v1/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"$MODEL_ID\",
    \"prompt\": \"The capital of France is\",
    \"max_tokens\": 5,
    \"temperature\": 0
  }" 2>/dev/null || echo "{}")

COMP_TEXT=$(echo "$COMP" | jq -r '.choices[0].text // ""')
if [[ -n "$COMP_TEXT" ]]; then
  pass "/v1/completions returned: \"The capital of France is${COMP_TEXT}\""
else
  fail "/v1/completions returned empty or error: $COMP"
fi

# ── Test 4: Chat completion ───────────────────────────────────────────────────
section "4/6" "Chat completion (/v1/chat/completions)"
T_START=$(date +%s%3N)

CHAT=$(curl -sf --max-time 90 \
  -X POST "$BASE/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"$MODEL_ID\",
    \"messages\": [
      {\"role\": \"system\", \"content\": \"You are a helpful assistant. Answer in one sentence only.\"},
      {\"role\": \"user\",   \"content\": \"What is Kubernetes?\"}
    ],
    \"max_tokens\": 60,
    \"temperature\": 0.1
  }" 2>/dev/null || echo "{}")

T_END=$(date +%s%3N)
ELAPSED=$(( T_END - T_START ))

CHAT_TEXT=$(echo "$CHAT" | jq -r '.choices[0].message.content // ""')
PROMPT_TOKENS=$(echo "$CHAT" | jq -r '.usage.prompt_tokens // "N/A"')
COMP_TOKENS=$(echo "$CHAT"  | jq -r '.usage.completion_tokens // "N/A"')
FINISH=$(echo "$CHAT"       | jq -r '.choices[0].finish_reason // "unknown"')

if [[ -n "$CHAT_TEXT" && "$CHAT_TEXT" != "null" ]]; then
  pass "/v1/chat/completions responded in ${ELAPSED}ms"
  info "Answer: \"$CHAT_TEXT\""
  info "Tokens: prompt=$PROMPT_TOKENS  completion=$COMP_TOKENS  finish=$FINISH"
  # Warn if finish_reason is "length" (hit max_tokens limit)
  if [[ "$FINISH" == "length" ]]; then
    echo -e "${YELLOW}  ⚠ finish_reason=length — response was truncated (increase max_tokens)${NC}"
  fi
else
  fail "/v1/chat/completions returned empty or error"
  echo "  Raw response: $CHAT"
fi

# ── Test 5: Streaming ─────────────────────────────────────────────────────────
section "5/6" "Streaming response (stream: true)"
STREAM_DATA=$(curl -sf --max-time 60 -N \
  -X POST "$BASE/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"$MODEL_ID\",
    \"messages\": [{\"role\": \"user\", \"content\": \"Say hello\"}],
    \"max_tokens\": 20,
    \"stream\": true
  }" 2>/dev/null | head -20 || echo "")

CHUNK_COUNT=$(echo "$STREAM_DATA" | grep -c "^data:" || echo "0")
if [[ "$CHUNK_COUNT" -gt 0 ]]; then
  pass "Streaming returned $CHUNK_COUNT SSE chunks"
else
  fail "Streaming returned no SSE chunks"
fi

# ── Test 6: Prometheus metrics ────────────────────────────────────────────────
section "6/6" "Prometheus metrics (/metrics)"
METRICS=$(curl -sf --max-time 5 "$BASE/metrics" 2>/dev/null || echo "")
check_metric() {
  local name=$1
  if echo "$METRICS" | grep -q "^${name}"; then
    pass "Metric present: $name"
  else
    fail "Metric missing: $name"
  fi
}

check_metric "vllm:num_requests_running"
check_metric "vllm:num_requests_waiting"
check_metric "vllm:gpu_cache_usage_perc"
check_metric "vllm:time_to_first_token_seconds"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
TOTAL=$(( PASS + FAIL ))
if [[ $FAIL -eq 0 ]]; then
  echo -e "${GREEN}All $TOTAL tests passed.${NC} Endpoint is healthy."
else
  echo -e "${RED}$FAIL/$TOTAL tests failed.${NC}"
  exit 1
fi
