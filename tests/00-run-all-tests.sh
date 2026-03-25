#!/usr/bin/env bash
###############################################################################
# Test 00 — Run All Tests
#
# Orchestrates all test scripts in order. Each test is independent and can
# also be run individually.
#
# Usage:
#   ./00-run-all-tests.sh [workspace] [namespace] [sb-namespace] [kv-name]
#   ./00-run-all-tests.sh workspace-phi4-mini inference aks-ai-lab-sb my-kv
#
# Skip individual tests by setting environment variables:
#   SKIP_ENDPOINT=1   ./00-run-all-tests.sh    # skip test 01
#   SKIP_KEDA=1       ./00-run-all-tests.sh    # skip test 02
#   SKIP_NAP=1        ./00-run-all-tests.sh    # skip test 03 (slowest, ~10 min)
#   SKIP_LOAD=1       ./00-run-all-tests.sh    # skip test 04
#   SKIP_WI=1         ./00-run-all-tests.sh    # skip test 05
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS=${1:-workspace-phi4-mini}
NS=${2:-inference}
SB_NS=${3:-""}
KV_NAME=${4:-""}

# Try to resolve from Terraform outputs if not provided
if [[ -z "$SB_NS" || -z "$KV_NAME" ]]; then
  TF_DIR="$(dirname "$SCRIPT_DIR")/terraform"
  if [[ -d "$TF_DIR" && -f "$TF_DIR/terraform.tfvars" ]]; then
    SB_NS=${SB_NS:-$(terraform -chdir="$TF_DIR" output -raw servicebus_namespace 2>/dev/null || echo "")}
    KV_URI=$(terraform -chdir="$TF_DIR" output -raw key_vault_uri 2>/dev/null || echo "")
    KV_NAME=${KV_NAME:-$(echo "$KV_URI" | sed 's|https://||' | sed 's|\.vault\.azure\.net.*||')}
  fi
fi

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASSED=(); FAILED=(); SKIPPED=()

run_test() {
  local num=$1; local name=$2; local skip_var=$3; shift 3
  local script="$SCRIPT_DIR/${num}-${name}.sh"

  if [[ "${!skip_var:-0}" == "1" ]]; then
    echo -e "\n${YELLOW}[SKIP]${NC} Test $num: $name"
    SKIPPED+=("$num: $name")
    return
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${YELLOW}[RUN]${NC}  Test $num: $name"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if bash "$script" "$@"; then
    PASSED+=("$num: $name")
  else
    FAILED+=("$num: $name")
    echo -e "${RED}  Test $num failed. Continuing to next test...${NC}"
  fi
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AKS AI Lab — Full Test Suite"
echo "  Workspace: $WS | Namespace: $NS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

chmod +x "$SCRIPT_DIR"/*.sh

run_test "01" "test-endpoint"          SKIP_ENDPOINT  "$WS" "$NS"
run_test "02" "test-keda-scaling"      SKIP_KEDA      "$SB_NS" "inference-requests" "10"
run_test "03" "test-nap-lifecycle"     SKIP_NAP       "gpu-inference"
run_test "04" "test-load"              SKIP_LOAD      "$WS" "$NS" "5" "20"
run_test "05" "test-workload-identity" SKIP_WI        "$KV_NAME" "$NS"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  TEST SUITE SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

for t in "${PASSED[@]:-}"; do echo -e "${GREEN}  ✓ PASSED${NC} — $t"; done
for t in "${FAILED[@]:-}"; do echo -e "${RED}  ✗ FAILED${NC} — $t"; done
for t in "${SKIPPED[@]:-}"; do echo -e "${YELLOW}  ⊘ SKIPPED${NC} — $t"; done

echo ""
TOTAL_RUN=$(( ${#PASSED[@]} + ${#FAILED[@]} ))
echo "  Ran: $TOTAL_RUN  |  Passed: ${#PASSED[@]}  |  Failed: ${#FAILED[@]}  |  Skipped: ${#SKIPPED[@]}"

if [[ ${#FAILED[@]} -eq 0 ]]; then
  echo -e "\n${GREEN}All tests passed.${NC}"
  exit 0
else
  echo -e "\n${RED}${#FAILED[@]} test(s) failed.${NC}"
  exit 1
fi
