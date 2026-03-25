#!/usr/bin/env bash
###############################################################################
# Test 04 — Load / Throughput Test
#
# Sends concurrent requests to the inference endpoint and measures:
#   - Time to first token (TTFT) per request
#   - Total tokens generated per second (throughput)
#   - Error rate under load
#   - Whether KEDA scales out additional replicas under sustained load
#
# Uses only bash + curl — no Python or additional tools needed.
# For deeper benchmarking, see the vLLM benchmark suite or GuideLLM.
#
# Usage:
#   ./04-test-load.sh [workspace] [namespace] [concurrency] [total-requests]
#   ./04-test-load.sh workspace-phi4-mini inference 5 20
###############################################################################
set -euo pipefail

WS=${1:-workspace-phi4-mini}
NS=${2:-inference}
CONCURRENCY=${3:-5}
TOTAL=${4:-20}
PORT=19001
BASE="http://localhost:$PORT"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}  →${NC} $1"; }
pass()    { echo -e "${GREEN}  ✓${NC} $1"; }
fail()    { echo -e "${RED}  ✗${NC} $1"; }

RESULTS_DIR="/tmp/load-test-$$"
mkdir -p "$RESULTS_DIR"

# ── Setup ─────────────────────────────────────────────────────────────────────
echo "============================================================"
echo "  Test 04: Load / Throughput Test"
echo "  Workspace: $WS | Concurrency: $CONCURRENCY | Requests: $TOTAL"
echo "============================================================"

SVC_PORT=$(kubectl get svc "$WS" -n "$NS" \
  -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "5000")

kubectl port-forward "svc/$WS" "$PORT:$SVC_PORT" -n "$NS" \
  --address 127.0.0.1 >/dev/null 2>&1 &
PF_PID=$!
trap "kill $PF_PID 2>/dev/null; rm -rf $RESULTS_DIR" EXIT INT TERM

for i in $(seq 1 15); do
  curl -sf --max-time 2 "$BASE/health" >/dev/null 2>&1 && break
  sleep 1
done

MODEL_ID=$(curl -sf "$BASE/v1/models" | jq -r '.data[0].id' 2>/dev/null || echo "unknown")
info "Model: $MODEL_ID | Endpoint: $BASE"

# ── Snapshot replica count before load ────────────────────────────────────────
TARGET_DEPLOY=$(kubectl get deployment -n "$NS" -l "apps=$WS" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null \
  || kubectl get deployment "$WS" -n "$NS" \
  -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")
REPLICAS_BEFORE=$(kubectl get deployment "$TARGET_DEPLOY" -n "$NS" \
  -o jsonpath='{.status.replicas}' 2>/dev/null || echo "1")
info "Replicas before load: ${REPLICAS_BEFORE:-1}"

# Prompts designed to produce varied output lengths
PROMPTS=(
  "In one sentence, what is Kubernetes?"
  "Name three benefits of container orchestration."
  "What does GPU stand for?"
  "Explain vLLM in two sentences."
  "What is the difference between a pod and a container?"
  "In one sentence, what is KEDA?"
  "Name two open-source LLMs."
  "What is inference latency?"
)

# ── Send concurrent requests ───────────────────────────────────────────────────
echo ""
echo "  Sending $TOTAL requests at concurrency=$CONCURRENCY..."
echo "  (Each dot = 1 completed request)"
echo ""

send_request() {
  local id=$1
  local prompt="${PROMPTS[$((id % ${#PROMPTS[@]}))]}"
  local out_file="$RESULTS_DIR/req_${id}.json"
  local t_start; t_start=$(date +%s%3N)

  HTTP=$(curl -so "$out_file" -w "%{http_code}" \
    --max-time 90 \
    -X POST "$BASE/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"$MODEL_ID\",
      \"messages\": [{\"role\": \"user\", \"content\": \"$prompt\"}],
      \"max_tokens\": 60,
      \"temperature\": 0.1
    }" 2>/dev/null || echo "000")

  local t_end; t_end=$(date +%s%3N)
  local elapsed=$(( t_end - t_start ))

  if [[ "$HTTP" == "200" ]]; then
    local tokens; tokens=$(jq -r '.usage.completion_tokens // 0' "$out_file" 2>/dev/null || echo 0)
    echo "${elapsed} ${tokens} ok" > "$RESULTS_DIR/result_${id}.txt"
    printf "."
  else
    echo "${elapsed} 0 err_${HTTP}" > "$RESULTS_DIR/result_${id}.txt"
    printf "E"
  fi
}

export -f send_request
export RESULTS_DIR BASE MODEL_ID
export PROMPTS

# Use GNU parallel if available, otherwise background subshells with throttle
T_LOAD_START=$(date +%s%3N)

if command -v parallel &>/dev/null; then
  seq 0 $(( TOTAL - 1 )) | parallel -j "$CONCURRENCY" send_request {}
else
  # Pure bash concurrency throttle
  running=0
  for i in $(seq 0 $(( TOTAL - 1 ))); do
    send_request "$i" &
    (( running++ ))
    if (( running >= CONCURRENCY )); then
      wait -n 2>/dev/null || wait
      (( running-- ))
    fi
  done
  wait
fi

T_LOAD_END=$(date +%s%3N)
TOTAL_MS=$(( T_LOAD_END - T_LOAD_START ))
echo ""

# ── Analyze results ───────────────────────────────────────────────────────────
echo ""
echo "  ── Results ──────────────────────────────────────────────"

SUCCESS=0; ERRORS=0
TOTAL_TOKENS=0; TOTAL_LATENCY=0
MIN_LAT=999999; MAX_LAT=0

for f in "$RESULTS_DIR"/result_*.txt; do
  read -r lat tokens status < "$f"
  if [[ "$status" == "ok" ]]; then
    (( SUCCESS++ ))
    (( TOTAL_TOKENS += tokens ))
    (( TOTAL_LATENCY += lat ))
    (( lat < MIN_LAT )) && MIN_LAT=$lat
    (( lat > MAX_LAT )) && MAX_LAT=$lat
  else
    (( ERRORS++ ))
    echo -e "${RED}    Error: $status (${lat}ms)${NC}"
  fi
done

AVG_LAT=$(( SUCCESS > 0 ? TOTAL_LATENCY / SUCCESS : 0 ))
TPS=$(( TOTAL_MS > 0 ? TOTAL_TOKENS * 1000 / TOTAL_MS : 0 ))

echo "  Total requests : $TOTAL"
echo "  Successful     : $SUCCESS"
echo "  Errors         : $ERRORS"
echo "  Error rate     : $(( ERRORS * 100 / TOTAL ))%"
echo ""
echo "  Latency (per request):"
echo "    Min : ${MIN_LAT}ms"
echo "    Max : ${MAX_LAT}ms"
echo "    Avg : ${AVG_LAT}ms"
echo ""
echo "  Throughput:"
echo "    Total tokens generated : $TOTAL_TOKENS"
echo "    Wall-clock time        : ${TOTAL_MS}ms"
echo "    Tokens/second          : ${TPS} tok/s"
echo "    Requests/second        : $(echo "scale=2; $TOTAL * 1000 / $TOTAL_MS" | bc 2>/dev/null || echo "~$(( TOTAL * 1000 / TOTAL_MS ))")"

# ── Check if KEDA scaled out ───────────────────────────────────────────────────
echo ""
echo "  ── KEDA Scale-out Check ─────────────────────────────────"
if [[ -n "$TARGET_DEPLOY" ]]; then
  REPLICAS_AFTER=$(kubectl get deployment "$TARGET_DEPLOY" -n "$NS" \
    -o jsonpath='{.status.replicas}' 2>/dev/null || echo "1")
  if [[ "${REPLICAS_AFTER:-1}" -gt "${REPLICAS_BEFORE:-1}" ]]; then
    pass "KEDA scaled out: ${REPLICAS_BEFORE:-1} → ${REPLICAS_AFTER} replicas under load"
  else
    info "Replicas unchanged at ${REPLICAS_AFTER:-1} (load may not have exceeded threshold)"
    info "To trigger scale-out, increase --concurrency or lower the ScaledObject threshold"
  fi
fi

# ── vLLM metrics snapshot ─────────────────────────────────────────────────────
echo ""
echo "  ── vLLM Internal Metrics Snapshot ───────────────────────"
METRICS=$(curl -sf --max-time 5 "$BASE/metrics" 2>/dev/null || echo "")
if [[ -n "$METRICS" ]]; then
  extract() { echo "$METRICS" | grep "^$1 " | awk '{print $2}' | head -1; }
  echo "  vllm:num_requests_running     : $(extract 'vllm:num_requests_running')"
  echo "  vllm:num_requests_waiting     : $(extract 'vllm:num_requests_waiting')"
  echo "  vllm:gpu_cache_usage_perc     : $(extract 'vllm:gpu_cache_usage_perc')"
  TTFT=$(extract 'vllm:time_to_first_token_seconds_sum')
  TTFT_COUNT=$(extract 'vllm:time_to_first_token_seconds_count')
  if [[ -n "$TTFT" && "$TTFT_COUNT" != "0" ]]; then
    AVG_TTFT=$(echo "scale=3; $TTFT / $TTFT_COUNT" | bc 2>/dev/null || echo "N/A")
    echo "  Avg time-to-first-token (TTFT): ${AVG_TTFT}s"
  fi
fi

echo ""
echo "============================================================"
if [[ $ERRORS -eq 0 ]]; then
  echo -e "${GREEN}Load test passed — no errors at concurrency=$CONCURRENCY${NC}"
else
  echo -e "${YELLOW}Load test completed with $ERRORS error(s)${NC}"
fi
echo "============================================================"
