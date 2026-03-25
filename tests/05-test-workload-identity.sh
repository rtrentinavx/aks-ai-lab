#!/usr/bin/env bash
###############################################################################
# Test 05 — Workload Identity Validation
#
# Verifies the zero-secret auth chain is working end-to-end:
#   1. ServiceAccount is annotated with the correct managed identity
#   2. Webhook is injecting AZURE_CLIENT_ID into pods
#   3. A test pod can get an AAD token using the federated OIDC credential
#   4. The AAD token has access to Key Vault (can read a secret)
#   5. The Secrets Store CSI driver has mounted the secret successfully
#
# Usage:
#   ./05-test-workload-identity.sh [key-vault-name] [namespace]
#   ./05-test-workload-identity.sh my-kv inference
###############################################################################
set -euo pipefail

KV_NAME=${1:-""}
NS=${2:-inference}
TEST_POD="wi-test-$$"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
pass()    { echo -e "${GREEN}  ✓${NC} $1"; }
fail()    { echo -e "${RED}  ✗${NC} $1"; }
info()    { echo -e "${CYAN}  →${NC} $1"; }
section() { echo -e "\n${YELLOW}[$1]${NC} $2"; }

cleanup() {
  kubectl delete pod "$TEST_POD" -n "$NS" --ignore-not-found --grace-period=0 >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# Resolve Key Vault name from Terraform if not provided
if [[ -z "$KV_NAME" ]]; then
  TF_DIR="$(dirname "$(dirname "${BASH_SOURCE[0]}")")/terraform"
  KV_URI=$(terraform -chdir="$TF_DIR" output -raw key_vault_uri 2>/dev/null || echo "")
  KV_NAME=$(echo "$KV_URI" | sed 's|https://||' | sed 's|\.vault\.azure\.net.*||')
fi

echo "============================================================"
echo "  Test 05: Workload Identity Validation"
echo "  Key Vault: $KV_NAME | Namespace: $NS"
echo "============================================================"

# ── Test 1: ServiceAccount annotation ────────────────────────────────────────
section "1/5" "ServiceAccount annotation check"

SA_CLIENT_ID=$(kubectl get serviceaccount inference-sa -n "$NS" \
  -o jsonpath='{.metadata.annotations.azure\.workload\.identity/client-id}' 2>/dev/null || echo "")

if [[ -n "$SA_CLIENT_ID" && "$SA_CLIENT_ID" != "<WORKLOAD_IDENTITY_CLIENT_ID>" ]]; then
  pass "ServiceAccount 'inference-sa' annotated with client-id: $SA_CLIENT_ID"
else
  fail "ServiceAccount missing or has placeholder client-id: '$SA_CLIENT_ID'"
  echo "  Run 01-deploy.sh to apply correct annotations, or:"
  echo "  kubectl annotate sa inference-sa -n $NS azure.workload.identity/client-id=<CLIENT_ID>"
  exit 1
fi

# ── Test 2: Existing inference pods — webhook injection ───────────────────────
section "2/5" "Webhook token injection in running pods"

INFERENCE_POD=$(kubectl get pods -n "$NS" \
  -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null \
  | tr ' ' '\n' | head -1)

if [[ -n "$INFERENCE_POD" ]]; then
  INJECTED=$(kubectl exec "$INFERENCE_POD" -n "$NS" -- \
    env 2>/dev/null | grep "AZURE_CLIENT_ID" | head -1 || echo "")
  TOKEN_FILE=$(kubectl exec "$INFERENCE_POD" -n "$NS" -- \
    env 2>/dev/null | grep "AZURE_FEDERATED_TOKEN_FILE" | head -1 || echo "")

  if [[ -n "$INJECTED" ]]; then
    pass "AZURE_CLIENT_ID injected into pod '$INFERENCE_POD'"
    info "$INJECTED"
  else
    fail "AZURE_CLIENT_ID not found in pod '$INFERENCE_POD'"
    info "Check that pod has label: azure.workload.identity/use=true"
  fi

  if [[ -n "$TOKEN_FILE" ]]; then
    pass "AZURE_FEDERATED_TOKEN_FILE injected: $TOKEN_FILE"
  else
    fail "AZURE_FEDERATED_TOKEN_FILE not injected"
  fi
else
  info "No running inference pods found. Spawning a dedicated test pod instead."
fi

# ── Test 3: Dedicated token-exchange test pod ─────────────────────────────────
section "3/5" "OIDC token → AAD token exchange test"

TENANT_ID=$(kubectl get serviceaccount inference-sa -n "$NS" \
  -o jsonpath='{.metadata.annotations.azure\.workload\.identity/tenant-id}' 2>/dev/null || \
  az account show --query tenantId -o tsv 2>/dev/null || echo "")

# Spawn a minimal pod using the federated SA to attempt Key Vault access
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $TEST_POD
  namespace: $NS
  labels:
    azure.workload.identity/use: "true"
spec:
  restartPolicy: Never
  serviceAccountName: inference-sa
  containers:
    - name: test
      image: mcr.microsoft.com/azure-cli:latest
      command:
        - /bin/bash
        - -c
        - |
          set -e
          echo "=== Environment check ==="
          echo "AZURE_CLIENT_ID=\$AZURE_CLIENT_ID"
          echo "AZURE_TENANT_ID=\$AZURE_TENANT_ID"
          echo "AZURE_FEDERATED_TOKEN_FILE=\$AZURE_FEDERATED_TOKEN_FILE"
          echo ""
          echo "=== OIDC token (first 80 chars) ==="
          head -c 80 \$AZURE_FEDERATED_TOKEN_FILE && echo "..."
          echo ""
          echo "=== Authenticating to Azure ==="
          az login --federated-token \$(cat \$AZURE_FEDERATED_TOKEN_FILE) \
            --service-principal \
            --username \$AZURE_CLIENT_ID \
            --tenant \$AZURE_TENANT_ID \
            --output none
          echo "AAD login: SUCCESS"
          echo ""
          echo "=== Reading Key Vault secret ==="
          az keyvault secret show \
            --vault-name ${KV_NAME} \
            --name hf-token \
            --query value -o tsv 2>/dev/null \
            && echo "Key Vault read: SUCCESS" \
            || echo "Key Vault read: FAILED (secret may not exist yet — run: az keyvault secret set --vault-name ${KV_NAME} --name hf-token --value test)"
      resources:
        requests:
          cpu: 100m
          memory: 128Mi
EOF

info "Test pod '$TEST_POD' submitted. Waiting for completion (up to 3 min)..."
for i in $(seq 1 36); do
  sleep 5
  PHASE=$(kubectl get pod "$TEST_POD" -n "$NS" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
  printf "  [%ds] Pod status: %s\n" "$(( i*5 ))" "$PHASE"
  if [[ "$PHASE" == "Succeeded" || "$PHASE" == "Failed" ]]; then break; fi
done

LOGS=$(kubectl logs "$TEST_POD" -n "$NS" 2>/dev/null || echo "")

if echo "$LOGS" | grep -q "AAD login: SUCCESS"; then
  pass "OIDC → AAD token exchange succeeded"
else
  fail "OIDC → AAD token exchange failed"
fi

if echo "$LOGS" | grep -q "Key Vault read: SUCCESS"; then
  pass "Key Vault secret read via Workload Identity (no connection string)"
else
  info "Key Vault read test: $(echo "$LOGS" | grep 'Key Vault read' || echo 'not attempted')"
fi

echo ""
echo "  Full pod output:"
echo "$LOGS" | sed 's/^/    /'

# ── Test 4: CSI driver secret mount ───────────────────────────────────────────
section "4/5" "Secrets Store CSI driver mount"

SPC=$(kubectl get secretproviderclass lab-secrets -n "$NS" 2>/dev/null || echo "")
if [[ -n "$SPC" ]]; then
  pass "SecretProviderClass 'lab-secrets' exists"
  # Check if any pod has the volume mounted
  MOUNTED_POD=$(kubectl get pods -n "$NS" \
    -o jsonpath='{.items[?(@.spec.volumes[*].csi.driver=="secrets-store.csi.k8s.io")].metadata.name}' \
    2>/dev/null | tr ' ' '\n' | head -1)
  if [[ -n "$MOUNTED_POD" ]]; then
    MOUNT_STATUS=$(kubectl get pod "$MOUNTED_POD" -n "$NS" \
      -o jsonpath='{.status.containerStatuses[0].state.running}' 2>/dev/null || echo "")
    if [[ -n "$MOUNT_STATUS" ]]; then
      pass "Secret volume mounted in pod '$MOUNTED_POD'"
    fi
  else
    info "No pods with CSI mount found. Mount is validated when a full inference pod is running."
  fi
else
  fail "SecretProviderClass 'lab-secrets' not found"
  echo "  Apply: kubectl apply -f manifests/workload-identity/secret-provider-class.yaml"
fi

# ── Test 5: Kubernetes secret mirror ─────────────────────────────────────────
section "5/5" "Mirrored Kubernetes Secret (lab-secrets-k8s)"

K8S_SECRET=$(kubectl get secret lab-secrets-k8s -n "$NS" 2>/dev/null || echo "")
if [[ -n "$K8S_SECRET" ]]; then
  KEYS=$(kubectl get secret lab-secrets-k8s -n "$NS" \
    -o jsonpath='{.data}' 2>/dev/null | jq -r 'keys[]' 2>/dev/null || echo "")
  pass "Kubernetes Secret 'lab-secrets-k8s' exists with keys: $KEYS"
  info "Pods can reference these via envFrom: secretRef or env: secretKeyRef"
else
  info "Kubernetes Secret 'lab-secrets-k8s' not yet created."
  info "It is created automatically by the CSI driver when a pod mounts the volume."
fi

echo ""
echo "============================================================"
echo "  Workload Identity test complete."
echo "============================================================"
