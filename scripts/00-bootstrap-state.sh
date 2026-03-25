#!/usr/bin/env bash
###############################################################################
# Script 00 — Bootstrap Terraform Remote State
#
# Run this ONCE before your first terraform init/apply.
# Creates a dedicated resource group + storage account for Terraform state.
# Uses Azure AD auth (no storage account key needed).
###############################################################################
set -euo pipefail

LOCATION="${LOCATION:-eastus2}"
STATE_RG="rg-tfstate"
STATE_SA="tfstateaksailab$(az account show --query id -o tsv | tr -d '-' | cut -c1-8)"
STATE_CONTAINER="tfstate"
STATE_KEY="aks-ai-lab.tfstate"

echo "============================================================"
echo "  Bootstrap Terraform Remote State"
echo "============================================================"
echo "  Resource Group : $STATE_RG"
echo "  Storage Account: $STATE_SA"
echo "  Container      : $STATE_CONTAINER"
echo "  Blob key       : $STATE_KEY"
echo ""

# ── Resource Group ─────────────────────────────────────────────
echo "[1/4] Creating resource group..."
az group create --name "$STATE_RG" --location "$LOCATION" --output none
echo "  ✓ $STATE_RG"

# ── Storage Account ────────────────────────────────────────────
echo "[2/4] Creating storage account..."
az storage account create \
  --name "$STATE_SA" \
  --resource-group "$STATE_RG" \
  --location "$LOCATION" \
  --sku Standard_GRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --enable-hierarchical-namespace false \
  --output none

# Enable versioning + soft delete for state history / recovery
az storage account blob-service-properties update \
  --account-name "$STATE_SA" \
  --resource-group "$STATE_RG" \
  --enable-versioning true \
  --enable-delete-retention true \
  --delete-retention-days 30 \
  --output none
echo "  ✓ $STATE_SA (GRS, versioning enabled)"

# ── Container ──────────────────────────────────────────────────
echo "[3/4] Creating blob container..."
az storage container create \
  --name "$STATE_CONTAINER" \
  --account-name "$STATE_SA" \
  --auth-mode login \
  --output none
echo "  ✓ $STATE_CONTAINER"

# ── RBAC ───────────────────────────────────────────────────────
echo "[4/4] Assigning Storage Blob Data Contributor..."
SA_ID=$(az storage account show --name "$STATE_SA" --resource-group "$STATE_RG" --query id -o tsv)
CURRENT_USER=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)

if [[ -n "$CURRENT_USER" ]]; then
  az role assignment create \
    --role "Storage Blob Data Contributor" \
    --assignee "$CURRENT_USER" \
    --scope "$SA_ID" \
    --output none
  echo "  ✓ Assigned to current user"
fi

# Also assign to CI service principal if provided
if [[ -n "${CI_CLIENT_ID:-}" ]]; then
  az role assignment create \
    --role "Storage Blob Data Contributor" \
    --assignee "$CI_CLIENT_ID" \
    --scope "$SA_ID" \
    --output none
  echo "  ✓ Assigned to CI service principal ($CI_CLIENT_ID)"
fi

# ── Write backend.hcl ──────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_FILE="$SCRIPT_DIR/../terraform/backend.hcl"

cat > "$BACKEND_FILE" <<EOF
resource_group_name  = "$STATE_RG"
storage_account_name = "$STATE_SA"
container_name       = "$STATE_CONTAINER"
key                  = "$STATE_KEY"
use_azuread_auth     = true
EOF

echo ""
echo "  ✓ Written: terraform/backend.hcl"
echo ""
echo "============================================================"
echo "  Next steps:"
echo "    cd terraform"
echo "    terraform init -backend-config=backend.hcl -migrate-state"
echo "============================================================"
echo ""
echo "  Add these to GitHub Actions secrets:"
echo "    TF_BACKEND_SA   = $STATE_SA"
echo "    TF_BACKEND_RG   = $STATE_RG"
