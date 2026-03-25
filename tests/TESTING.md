# Testing Guide

Five test scripts covering every layer of the stack, plus a runner that executes them all in order.

---

## Quick Start

```bash
# Run all tests (auto-resolves Service Bus and Key Vault from Terraform outputs)
./tests/00-run-all-tests.sh workspace-phi4-mini inference

# Run a single test
./tests/01-test-endpoint.sh workspace-phi4-mini inference

# Skip slow tests (NAP lifecycle takes ~10 min)
SKIP_NAP=1 ./tests/00-run-all-tests.sh workspace-phi4-mini inference
```

---

## Test 01 — Endpoint Validation

**What it tests:** Every surface of the vLLM OpenAI-compatible API.

**What each check means:**

| Check | Endpoint | What a failure means |
|---|---|---|
| Health | `GET /health` | vLLM process crashed or not yet ready |
| Model list | `GET /v1/models` | Model failed to load into memory |
| Completion | `POST /v1/completions` | Inference pipeline broken |
| Chat | `POST /v1/chat/completions` | Chat template not applied (model config issue) |
| Streaming | `POST /v1/chat/completions` + `stream: true` | SSE not working — client buffering issue |
| Prometheus | `GET /metrics` | Metrics not exposed — KEDA Prometheus trigger will fail |

**Key metrics exposed at `/metrics`:**
```
vllm:num_requests_running       # Actively being processed right now
vllm:num_requests_waiting       # In the scheduler queue (KEDA trigger source)
vllm:gpu_cache_usage_perc       # KV cache pressure — if >90%, add replicas or reduce max-model-len
vllm:time_to_first_token_seconds # TTFT distribution — p50/p95/p99 latency
vllm:e2e_request_latency_seconds # End-to-end latency including queue wait
```

**Run it:**
```bash
./tests/01-test-endpoint.sh workspace-phi4-mini inference
```

**Expected output (healthy):**
```
[1/6] Health check
  ✓ PASS — /health returned HTTP 200
[4/6] Chat completion
  ✓ PASS — /v1/chat/completions responded in 1823ms
  → Answer: "Kubernetes is an open-source container orchestration..."
  → Tokens: prompt=42  completion=38  finish=stop
All 9 tests passed. Endpoint is healthy.
```

---

## Test 02 — KEDA Scale-Up / Scale-Down

**What it tests:** The complete KEDA lifecycle — scale from 0 to N and back to 0.

**The timeline you should observe:**

```
t=0s    Messages sent to Service Bus queue (10 messages)
t=15s   KEDA polls queue → detects messages > activationThreshold
t=30s   KEDA sets replicas: 0 → 1
t=30s   (if GPU node exists) pod schedules in seconds
t=3-6m  (if no GPU node) NAP provisions GPU node, pod schedules, model loads
t=Xm    All messages consumed by worker pods
t=X+5m  cooldownPeriod (300s) elapses → KEDA sets replicas: N → 0
```

**What to watch for:**

- `ACTIVE=False → True`: KEDA detects demand and activates
- Replica count `0 → 1+`: scale-up happened
- Replica count `N → 0`: scale-down happened after cooldown
- `KEDA reaction time`: time from message send to replica > 0 (should be 15-30s)

**Diagnosing KEDA issues:**
```bash
# Full ScaledObject state
kubectl describe scaledobject inference-sb-scaler -n inference

# KEDA operator logs (shows polling decisions)
kubectl logs -n keda -l app=keda-operator --tail=50

# Check TriggerAuthentication is working
kubectl get triggerauthentication -n inference
```

**Run it:**
```bash
./tests/02-test-keda-scaling.sh aks-ai-lab-sb inference-requests 10
```

---

## Test 03 — NAP GPU Node Lifecycle

**What it tests:** NAP's end-to-end ability to provision and deprovision GPU nodes on demand.

**This test is independent of KAITO** — it submits a minimal `nvidia-smi` pod directly, which:
1. Requests `nvidia.com/gpu: 1` → NAP sees a pending GPU pod
2. NAP selects the cheapest GPU SKU from the NodePool requirements
3. VM provisions and joins the cluster (3-6 min)
4. Pod schedules, `nvidia-smi` runs, pod exits
5. Node goes idle → NAP's `consolidateAfter: 2m` kicks in → node deprovisioned

**What to look for in the output:**

```
[3/5] Submitting GPU probe pod → watching NAP provision
  → 5s   pod=Pending   node=(pending)                   gpu-nodes=0
  → 60s  pod=Pending   node=(pending)                   gpu-nodes=0
  → 180s pod=Pending   node=aks-nc4ast4v3-xxxxx          gpu-nodes=1
  ✓ Pod scheduled on node 'aks-nc4ast4v3-xxxxx' after 187s
  → GPU SKU selected by NAP: Standard_NC4as_T4_v3

[4/5] Validate NVIDIA driver
  ✓ NVIDIA driver functional
  → GPU: Tesla T4 | Driver: 550.90.12 | CUDA: 12.4

[5/5] Delete pod → watch NAP deprovision
  → 120s  GPU nodes remaining: 1
  → 240s  GPU nodes remaining: 0
  ✓ GPU node deprovisioned after 243s — GPU billing stopped
```

**If NAP doesn't provision:**
```bash
# Check Karpenter controller logs
kubectl logs -n kube-system -l app=karpenter --tail=50

# Check NodePool limits aren't exhausted
kubectl get nodepool gpu-inference -o yaml | grep -A5 limits

# Check the pod's pending reason
kubectl describe pod gpu-probe -n nap-test
# Look for: "0/N nodes are available: N node(s) didn't match node selector"
# vs:       "pod triggered scale-up" (good)
```

**Run it:**
```bash
./tests/03-test-nap-lifecycle.sh gpu-inference
# Takes 8-12 minutes total — this is expected.
```

---

## Test 04 — Load / Throughput Test

**What it tests:** Inference quality under concurrent load, throughput measurement, and KEDA horizontal scale-out.

**Metrics it reports:**

| Metric | What it means | Healthy range |
|---|---|---|
| Avg latency | Time from request send to full response | <5s for small models / short prompts |
| Tokens/sec | Total tokens generated / wall-clock time | 20-80 tok/s on T4, 100-300 tok/s on A100 |
| Error rate | HTTP non-200 responses | 0% at low concurrency |
| TTFT | Time to first token (from vLLM metrics) | <500ms at low load |
| KV cache usage | GPU memory used for attention cache | <90% before adding replicas |
| KEDA scale-out | Did replicas increase under load? | Yes, if threshold exceeded |

**Tuning concurrency:**
- Start at `--concurrency 5` to establish baseline
- Increase to `--concurrency 20` to test KEDA scale-out trigger
- Watch `vllm:num_requests_waiting` — when it exceeds your Prometheus ScaledObject threshold, KEDA adds a replica

**Run it:**
```bash
# Baseline: 5 concurrent, 20 total requests
./tests/04-test-load.sh workspace-phi4-mini inference 5 20

# Stress: 20 concurrent, 50 total requests (triggers KEDA scale-out)
./tests/04-test-load.sh workspace-phi4-mini inference 20 50
```

---

## Test 05 — Workload Identity

**What it tests:** The full OIDC federation chain — confirms that pods can reach Azure resources with zero stored secrets.

**The chain it validates:**
```
Kubernetes SA → OIDC token → AAD token exchange → Key Vault read
```

**What each phase confirms:**

| Phase | What it proves |
|---|---|
| SA annotation check | Client ID is correctly bound to the SA |
| Webhook injection | Workload Identity mutating webhook is running and injecting env vars |
| AAD login from pod | Federated credential is correctly configured (`subject` matches SA/namespace) |
| Key Vault read | Managed identity has `Key Vault Secrets User` role on the vault |
| CSI mount | Secrets Store driver can translate the AAD token to a Key Vault secret file |

**Common failures and fixes:**

```bash
# "AAD login: FAILED" — federated credential subject mismatch
# The subject in Terraform must exactly match system:serviceaccount:<NS>:<SA-NAME>
az identity federated-credential list \
  --identity-name aks-ai-lab-workload-identity \
  --resource-group rg-aks-ai-lab \
  --query '[].subject'

# "Key Vault read: FAILED" — role assignment missing or secret doesn't exist
az role assignment list --scope $(az keyvault show -n $KV_NAME --query id -o tsv)
az keyvault secret set --vault-name $KV_NAME --name hf-token --value "test-value"

# Webhook not injecting — check webhook is running
kubectl get mutatingwebhookconfiguration | grep workload
kubectl get pods -n kube-system | grep workload-identity
```

**Run it:**
```bash
./tests/05-test-workload-identity.sh my-kv-name inference
```

---

## Manual Debug Commands

```bash
# Watch a workspace come up in real time
kubectl get workspace -n inference -w

# Follow vLLM logs from a KAITO pod
kubectl logs -n inference -l apps=phi4-mini-inference -f

# Check what GPU node NAP chose and its labels
kubectl get node -l karpenter.azure.com/sku-family=NC --show-labels

# Live GPU utilization from inside a pod
kubectl exec -n inference <pod> -- nvidia-smi dmon -s u -d 2

# KEDA ScaledObject details (shows current metric value vs threshold)
kubectl describe scaledobject inference-gpu-scaler -n inference
# Look for: "Current Replicas", "Desired Replicas", "Last Scale Time"

# vLLM metrics in real time (port-forward first)
watch -n 5 'curl -sf http://localhost:19000/metrics | grep -E "waiting|running|cache|ttft"'

# Force immediate scale-to-zero to test cold-start
kubectl scale deployment workspace-phi4-mini -n inference --replicas=0
# Then send a request and time how long until it responds
time curl -X POST http://localhost:19000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"phi-4-mini-instruct","messages":[{"role":"user","content":"hi"}],"max_tokens":5}'
```
