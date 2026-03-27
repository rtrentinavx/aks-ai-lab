#!/usr/bin/env bash
###############################################################################
# Script 00 — Prerequisites Check
# Validates all required tools and Azure permissions before starting the lab.
###############################################################################
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC}  $1"; }
fail() { echo -e "${RED}✗${NC} $1"; FAILED=1; }
FAILED=0

echo "============================================================"
echo "  AKS AI Lab — Prerequisites Check"
echo "============================================================"

# ── Tool versions ──────────────────────────────────────────────
echo -e "\n[1/4] Checking required tools..."

check_tool() {
  local tool=$1; local min=$2; local ver_cmd=${3:---version}
  if command -v "$tool" &>/dev/null; then
    local ver; ver=$("$tool" $ver_cmd 2>/dev/null | grep -v '^WARNING' | head -1)
    pass "$tool found: $ver"
  else
    fail "$tool not found (minimum: $min)"
  fi
}

check_tool az        "2.65+"
check_tool kubectl    "1.29+"  "version --client"
check_tool kubelogin  "0.1+"   "--version"
check_tool helm       "3.14+"
check_tool terraform  "1.7+"
check_tool jq         "1.6+"

# ── Azure login ────────────────────────────────────────────────
echo -e "\n[2/4] Checking Azure login..."
ACCOUNT=$(az account show 2>/dev/null || true)
if [[ -z "$ACCOUNT" ]]; then
  fail "Not logged in to Azure. Run: az login"
else
  SUB_NAME=$(echo "$ACCOUNT" | jq -r '.name')
  SUB_ID=$(echo "$ACCOUNT" | jq -r '.id')
  pass "Logged in — Subscription: $SUB_NAME ($SUB_ID)"
fi

# ── GPU quota check ────────────────────────────────────────────
echo -e "\n[3/4] Checking NC-series GPU quota in eastus2..."
echo "    (This check may take 10-15 seconds)"

check_quota() {
  local family=$1; local region=${2:-eastus2}
  local usage
  usage=$(az vm list-usage --location "$region" \
    --query "[?name.value=='$family'] | [0].{current: currentValue, limit: limit}" \
    -o json 2>/dev/null || echo '{}')
  local current; current=$(echo "$usage" | jq -r '.current // "unknown"')
  local limit;   limit=$(echo "$usage" | jq -r '.limit // "unknown"')

  if [[ "$limit" == "0" || "$limit" == "unknown" ]]; then
    warn "  $family: quota unknown or 0 — may need quota increase"
  elif [[ "$current" -lt "$limit" ]]; then
    pass "  $family: $current/$limit vCPUs used"
  else
    fail "  $family: quota exhausted ($current/$limit)"
  fi
}

check_quota "standardNCASv3Family"          # NC_A100_v4
check_quota "standardNCADSA100v4Family"     # NC24ads_A100_v4
check_quota "standardNCAST4v3Family"        # T4 — cheapest option

echo ""
echo "  If quota is 0, request an increase at:"
echo "  https://aka.ms/AzureGPUQuota"
echo "  Fastest regions for NC quota: eastus2, westus2, westeurope"

# ── Feature flags ──────────────────────────────────────────────
echo -e "\n[4/4] Checking required AKS feature flags..."

check_feature() {
  local ns=$1; local name=$2
  local state
  state=$(az feature show --namespace "$ns" --name "$name" \
    --query 'properties.state' -o tsv 2>/dev/null || echo "NotRegistered")
  if [[ "$state" == "Registered" ]]; then
    pass "  $name: Registered"
  else
    warn "  $name: $state — registering now..."
    az feature register --namespace "$ns" --name "$name" --output none 2>/dev/null || true
    warn "  $name: registration submitted (may take 5-10 min)"
  fi
}

check_feature "Microsoft.ContainerService" "NodeAutoProvisioningPreview"
check_feature "Microsoft.ContainerService" "AIToolchainOperatorPreview"

# Re-register provider after feature registration
az provider register --namespace Microsoft.ContainerService --output none 2>/dev/null || true

# ── Summary ────────────────────────────────────────────────────
echo ""
echo "============================================================"
if [[ $FAILED -eq 0 ]]; then
  echo -e "${GREEN}All prerequisite checks passed. Ready to run 01-deploy.sh${NC}"
else
  echo -e "${RED}Some checks failed. Fix the issues above before proceeding.${NC}"
  exit 1
fi
