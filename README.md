# AKS AI Inference Lab
### KEDA · Node Auto Provisioning (NAP/Karpenter) · KAITO · vLLM · Workload Identity

A fully event-driven, scale-to-zero GPU inference stack on Azure Kubernetes Service.

---

## Architecture Overview

![Architecture Overview](docs/architecture-overview.svg)

---

## Component Deep Dives

### 1. KEDA — Kubernetes Event-Driven Autoscaling

**What problem it solves:**
Standard HPA scales on CPU/memory — meaningless for LLM inference where GPUs
are the bottleneck and requests arrive unpredictably. KEDA watches external
event sources and scales Deployments based on real demand signals.

**The scale-to-zero trick:**
HPA requires at least one running pod to collect metrics. KEDA bypasses this
by monitoring event sources directly from its operator — no running pod needed.
When demand arrives, it sets replicas from 0 → 1 before HPA ever gets involved.

**Three trigger modes in this lab:**

| Trigger | File | Best For |
|---|---|---|
| HTTP Add-on | `keda/1-http-scaledobject.yaml` | Synchronous inference API; buffers requests while pods cold-start |
| Service Bus Queue | `keda/2-servicebus-scaledobject.yaml` | Async batch inference; message durability; decoupled producers |
| Azure Managed Prometheus | `keda/3-prometheus-scaledobject.yaml` | React to GPU utilization or vLLM internal queue depth |

**HTTP Add-on internals:**
The HTTP add-on installs an interceptor proxy (2 replicas) that sits in front
of your Service. All traffic routes through it. When a request arrives and the
target deployment has 0 replicas, the proxy holds the connection open, signals
KEDA to scale up, and forwards the request once the pod is ready. This is
transparent to the client — they just see extra latency on the first request.

**Key tuning parameters:**
```yaml
cooldownPeriod: 120     # Seconds of idle before scaling to zero.
                        # For LLMs: set higher than your longest generation.
                        # Killing a pod mid-generation loses the response.

pollingInterval: 15     # How often KEDA queries the trigger source.
                        # Lower = faster reaction, more API calls to Azure.

activationThreshold: 1  # Queue depth that triggers scale from 0 → 1.
                        # Keep at 1 for interactive use cases.

threshold: 5            # Target metric value per replica.
                        # "Add a replica per 5 queued messages" or
                        # "Add a replica when GPU util > 70%"
```

**Authentication (no secrets stored):**
KEDA's TriggerAuthentication uses `azure-workload` provider. The KEDA operator
ServiceAccount is federated with an Azure managed identity (via Terraform). It
exchanges its OIDC token for a scoped AAD token at query time. Connection
strings never touch etcd.

---

### 2. NAP — Node Auto Provisioning (Karpenter on AKS)

**What problem it solves:**
Classic AKS cluster autoscaler requires pre-created node pools with fixed VM
sizes. If you don't have a GPU node pool, GPU-requesting pods stay `Pending`
forever. NAP replaces this with a Karpenter-based controller that analyzes each
pending pod's resource requirements and dynamically provisions the optimal VM.

**How selection works:**
```
Pending pod requests:
  nvidia.com/gpu: 1
  memory: 16Gi
  cpu: 4

NAP evaluates NodePool requirements:
  sku-family: NC
  sku-name: [NC4as_T4_v3, NC8as_T4_v3, NC16as_T4_v3, NC6s_v3, NC24ads_A100_v4]
  capacity-type: on-demand

NAP picks the cheapest SKU that fits all requests:
  → Standard_NC4as_T4_v3 (1x T4, 28GiB RAM, 4 vCPU) wins
  → VM provisions, joins cluster, pod schedules
```

**GPU node lifecycle:**
```
Pod pending → NAP provisions node (3-5 min)
Pod running → model loads → inference starts
Pod completed / scaled to 0 → node idle
consolidateAfter: 2m → NAP deprovisions node  ← only if do-not-disrupt is not set
GPU billing stops
```

> **Important:** KAITO sets `karpenter.sh/do-not-disrupt: "true"` on every
> NodeClaim it creates ([source](https://github.com/kaito-project/kaito/blob/main/pkg/utils/nodeclaim/nodeclaim.go#L151)).
> This blocks NAP consolidation — the GPU node stays alive as long as the
> Workspace CRD exists, even when replicas are scaled to zero. True GPU billing
> scale-to-zero with KAITO requires **deleting the Workspace**, not scaling
> replicas. KAITO's official KEDA integration (v0.8.0+) scales pods only and
> uses `minReplicaCount: 1` in all examples — scale-to-zero at the GPU node
> level is not supported. See **KAITO vs vLLM Standalone** below.

**Key CRDs in this lab:**
- `NodePool` (Karpenter API) — constraints: GPU SKU families, capacity type
  (spot vs on-demand), architecture, taints
- `AKSNodeClass` (Azure extension) — VNet/subnet ID, OS disk size, image family

**GPU taint/toleration pattern:**
```yaml
# NodePool applies this taint to every GPU node it provisions:
taints:
  - key: nvidia.com/gpu
    value: "true"
    effect: NoSchedule

# Pods must declare this toleration to land on GPU nodes:
tolerations:
  - key: nvidia.com/gpu
    operator: Equal
    value: "true"
    effect: NoSchedule
```
This ensures CPU workloads never accidentally schedule onto expensive GPU VMs.

**Cost guard:**
```yaml
limits:
  nvidia.com/gpu: "8"   # Hard cap: NAP won't provision beyond 8 GPUs total.
                        # Without this, a misconfigured workload can exhaust
                        # your entire Azure GPU quota.
```

---

### 3. KAITO — Kubernetes AI Toolchain Operator

**What problem it solves:**
Deploying an LLM on Kubernetes without KAITO requires: knowing the right GPU
SKU, writing vLLM startup args, configuring tensor parallelism, managing GPU
driver plugin DaemonSets, writing readiness probes tuned to 2-minute model
load times, and more. KAITO wraps all of this into a single 15-line Workspace
CRD.

**What KAITO does when you `kubectl apply` a Workspace:**
```
1. Reads the Workspace spec (instanceType, preset name)
2. Validates GPU SKU has enough VRAM for the model
3. Creates a Deployment with correct GPU requests + tolerations
4. Creates a ConfigMap with vLLM startup arguments
5. Creates a ClusterIP Service named after the workspace
6. Monitors the Deployment → updates Workspace status conditions
```

NAP provisions the GPU node in parallel (step 3 triggers it).

**Preset model matrix in this lab:**

| KAITO Preset | File | Min GPU | Min VRAM | Approx GPU VM |
|---|---|---|---|---|
| `phi-4-mini-instruct` | workspace-phi4-mini.yaml | 1x T4 | 8 GB | NC4as_T4_v3 |
| `phi-3-mini-128k-instruct` | workspace-phi3-mini.yaml | 1x T4 | 10 GB | NC8as_T4_v3 |
| `mistral-7b-instruct` | workspace-mistral-7b.yaml | 1x T4 | 14 GB | NC16as_T4_v3 |
| `llama-3.1-8b-instruct` | workspace-llama3-8b.yaml | 1x V100 | 16 GB | NC6s_v3 |
| `llama-3.3-70b-instruct` | workspace-llama3-70b.yaml | 2x A100 | 160 GB | 2x NC24ads_A100_v4 |

**vLLM ConfigMap tuning:**
KAITO passes inference config via a ConfigMap referenced in the Workspace. Key
vLLM parameters for LLM workloads:

```yaml
vllm:
  gpu-memory-utilization: 0.90  # Fraction of VRAM reserved for KV cache.
                                 # Higher = more context/batch. Leave 10% margin.
  max-model-len: 4096            # Maximum sequence length (input + output).
                                 # Reduce to fit in VRAM if OOM.
  max-num-seqs: 64               # Max concurrent sequences in the scheduler.
                                 # Each sequence consumes KV cache memory.
  dtype: "float16"               # T4/V100: use float16. A100/H100: use bfloat16.
  enable-prefix-caching: true    # Cache KV for repeated system prompts.
                                 # Big win for chatbot workloads (same system prompt).
```

**KAITO vs vLLM Standalone — which to use:**

| | KAITO | vLLM Standalone |
|---|---|---|
| Model packaging | Pre-built MCR images — no HuggingFace token needed | Pull from HuggingFace or your own registry |
| GPU validation | Validates VRAM before scheduling | Fails at runtime (OOM) |
| Multi-node (70B+) | Handled automatically (Ray topology) | Manual Ray configuration |
| vLLM version control | Pinned to KAITO release | Any version |
| True GPU scale-to-zero | ✗ — `do-not-disrupt` pins the node | ✓ — NAP deprovisions freely |
| Cold start (node warm) | Fast — image cached on node | Fast — image cached on node |

**Use KAITO** for always-on or near-always-on workloads (`minReplicaCount: 1`),
multi-node large models, or when you want preset GPU validation with minimal YAML.

**Use vLLM Standalone** (`manifests/vllm/vllm-standalone.yaml`) when true GPU
billing scale-to-zero is required — bursty workloads, dev/lab environments, or
any scenario where the GPU should deprovision during idle periods. Also use
standalone for custom LoRA adapters, quantized (GGUF/AWQ) weights, or a vLLM
version newer than what KAITO packages.

**Checking workspace status:**
```bash
kubectl get workspace -n inference
# NAME                    INSTANCE             RESOURCEREADY   INFERENCEREADY   WORKSPACEREADY
# workspace-phi4-mini     Standard_NC4as_T4_v3 True            True             True

kubectl describe workspace workspace-phi4-mini -n inference
# Look at the Conditions section for detailed status
```

---

### 4. vLLM — OpenAI-Compatible Inference Server

**Why vLLM (not TGI, Ollama, etc.):**
- PagedAttention: manages KV cache as virtual memory pages → higher throughput
- Continuous batching: processes multiple requests in parallel without waiting
- OpenAI API compatibility: drop-in replacement for GPT-4 clients (no SDK change)
- Tensor parallelism: split a model across multiple GPUs in one line (`--tensor-parallel-size 2`)
- Prefix caching: reuse KV cache for repeated system prompts (significant for chatbots)

**OpenAI-compatible endpoints:**
```
POST /v1/chat/completions    — ChatGPT-style multi-turn conversation
POST /v1/completions         — Legacy text completion
GET  /v1/models              — Lists available models
GET  /health                 — Readiness probe endpoint
GET  /metrics                — Prometheus metrics (queue depth, TTFT, throughput)
```

**Cold-start latency breakdown:**
| Phase | Duration | Notes |
|---|---|---|
| NAP VM provision | 3-5 min | Only if no GPU node available |
| Container pull | 1-2 min | vLLM image ~8GB; faster after first pull |
| Model download | 2-10 min | From HuggingFace; cached in PVC after first run |
| Model load to VRAM | 30-120s | Proportional to model size |
| vLLM ready | ~10s | After model loaded |

**Use a PVC for model caching** (see `vllm-standalone.yaml`). Without it,
every pod restart re-downloads the full model. With it, cold start goes from
10+ minutes to under 2 minutes after the first run.

---

### 5. Workload Identity

**Why not connection strings or Kubernetes Secrets:**
Secrets stored in etcd are base64-encoded (not encrypted) by default. Rotation
requires a redeployment. If your etcd backup leaks, all secrets leak. Workload
Identity eliminates the problem entirely.

**The OIDC federation chain:**
```
Kubernetes Pod
  ↓ ServiceAccount projected token (JWT, short-lived, in /var/run/secrets/)
Azure Workload Identity Webhook
  ↓ injects AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_FEDERATED_TOKEN_FILE
Azure AD
  ↓ validates OIDC token against the cluster's OIDC issuer URL
  ↓ checks subject matches the federated credential (system:serviceaccount:ns:sa)
  ↓ issues an AAD access token scoped to the requested resource
Azure Resource (Key Vault / Service Bus / Foundry)
  ↓ validates AAD token → grants access
```

**Three identities in this lab:**

| Identity | Used By | Permissions |
|---|---|---|
| `kaito-identity` | KAITO GPU provisioner | Contributor on AKS cluster (to provision nodes) |
| `keda-identity` | KEDA operator | Monitoring Data Reader (Prometheus), Service Bus Data Owner |
| `workload-identity` | Inference pods | Key Vault Secrets User, Service Bus Data Sender/Receiver |

**Secrets Store CSI Driver:**
Mounts Key Vault secrets as files inside pods at `/mnt/secrets/`. Combined
with the `secretObjects` block in SecretProviderClass, secrets are also mirrored
as Kubernetes Secret objects (for workloads that read from env vars).

```bash
# Store your HuggingFace token in Key Vault (required for Llama 3):
az keyvault secret set \
  --vault-name <KEY_VAULT_NAME> \
  --name hf-token \
  --value "hf_xxxxxxxxxxxxxxxxxxxx"
```

---

## Directory Structure

```
aks-ai-lab/
├── terraform/
│   ├── main.tf                    # AKS + NAP + KAITO + KEDA + Key Vault + Service Bus
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
│
├── manifests/
│   ├── nap/
│   │   └── gpu-nodepool.yaml      # Karpenter NodePool + AKSNodeClass for GPU nodes
│   │
│   ├── kaito/
│   │   ├── namespace.yaml
│   │   ├── workspace-phi4-mini.yaml      # Cheapest: T4 16GB
│   │   ├── workspace-phi3-mini.yaml      # 128K context: T4 16GB
│   │   ├── workspace-mistral-7b.yaml     # Balanced: T4 16GB
│   │   ├── workspace-llama3-8b.yaml      # Quality: V100 16GB
│   │   └── workspace-llama3-70b.yaml     # Premium: 2x A100 80GB
│   │
│   ├── keda/
│   │   ├── 1-http-scaledobject.yaml      # Scale on HTTP request concurrency
│   │   ├── 2-servicebus-scaledobject.yaml # Scale on Service Bus queue depth
│   │   └── 3-prometheus-scaledobject.yaml # Scale on GPU util / vLLM queue
│   │
│   ├── workload-identity/
│   │   ├── serviceaccount.yaml           # Federated SA for inference pods
│   │   ├── secret-provider-class.yaml    # Key Vault → pod file mounts
│   │   └── keda-trigger-auth.yaml        # KEDA → Azure auth (no secrets)
│   │
│   ├── vllm/
│   │   └── vllm-standalone.yaml          # Direct vLLM deployment (non-KAITO)
│   │
│   ├── ingress/
│   │   ├──  1-app-routing.yaml            # AKS App Routing add-on (NGINX) — lab/dev
│   │   ├── 2-app-gateway-containers.yaml # Application Gateway for Containers — production
│   │   ├── 3-istio-gateway.yaml          # Istio ingress + VirtualService — production
│   │   └── 4-inference-extension.yaml    # Gateway API Inference Extension — multi-replica
│   │
│   └── monitoring/
│       └── dcgm-exporter.yaml            # NVIDIA GPU metrics DaemonSet
│
├── tests/
│   ├── TESTING.md                    # Test guide — what each test validates
│   ├── 00-run-all-tests.sh           # Run full test suite
│   ├── 01-test-endpoint.sh           # vLLM API surface validation
│   ├── 02-test-keda-scaling.sh       # Scale-up / scale-down lifecycle
│   ├── 03-test-nap-lifecycle.sh      # GPU node provision / deprovision
│   ├── 04-test-load.sh               # Throughput / concurrency benchmark
│   └── 05-test-workload-identity.sh  # OIDC → AAD → Key Vault chain
│
├── docs/
│   ├── sizing-guide.md               # Node / pod / replica sizing formulas
│   └── ingress-guide.md              # Ingress options, manifests, decision guide
│
└── scripts/
    ├── 00-prereqs.sh   # Tool versions, GPU quota, feature flag check
    ├── 01-deploy.sh    # terraform apply + helm installs + namespace setup
    ├── 02-deploy-model.sh # kubectl apply a KAITO workspace + watch status
    └── 03-smoke-test.sh   # port-forward + OpenAI API test + KEDA status
```

---

## Quickstart

### Prerequisites
- Azure subscription with NC-series GPU quota (request at https://aka.ms/AzureGPUQuota)
- Tools: `az`, `kubectl`, `helm`, `terraform`, `jq`

### 1. Clone and configure

```bash
git clone <your-repo> aks-ai-lab
cd aks-ai-lab

cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform.tfvars — set subscription_id and location
```

### 2. Check prerequisites

```bash
chmod +x scripts/*.sh
./scripts/00-prereqs.sh
```

### 3. Deploy infrastructure

```bash
./scripts/01-deploy.sh
# Takes ~10 minutes. Creates AKS cluster with NAP, KAITO, KEDA add-ons,
# Key Vault, Service Bus, managed identities, federated credentials.
```

### 4. Store secrets in Key Vault

```bash
# Required for Llama 3 (gated model). Optional for Phi/Mistral.
az keyvault secret set --vault-name <KV_NAME> --name hf-token --value "hf_xxx"
az keyvault secret set --vault-name <KV_NAME> --name foundry-api-key --value "xxx"
```

### 5. Deploy a model

```bash
# Start with Phi-4 Mini — fastest and cheapest (T4 GPU, ~$0.50/hr)
./scripts/02-deploy-model.sh phi4-mini

# Or deploy directly:
kubectl apply -f manifests/kaito/workspace-phi4-mini.yaml

# Watch NAP provision the GPU node:
kubectl get nodes -w
# NAME                                   STATUS   ROLES   AGE   VERSION
# aks-system-xxxxx                       Ready    agent   10m   v1.31
# (after 3-5 min):
# aks-nc4ast4v3-xxxxx                    Ready    agent   1m    v1.31  ← GPU node!
```

### 6. Apply KEDA scaling

```bash
# Update placeholders in the KEDA manifests first:
export SB_NS=$(terraform -chdir=terraform output -raw servicebus_namespace)
sed -i "s|<SERVICEBUS_NAMESPACE>|$SB_NS|g" manifests/keda/2-servicebus-scaledobject.yaml

export AMW=$(az monitor account list -g rg-aks-ai-lab --query '[0].metrics.prometheusQueryEndpoint' -o tsv)
sed -i "s|<AMW_ENDPOINT>|$AMW|g" manifests/keda/3-prometheus-scaledobject.yaml

kubectl apply -f manifests/keda/
```

### 7. Run smoke test

```bash
./scripts/03-smoke-test.sh phi4-mini
```

---

## Useful Commands

```bash
# Watch workspace status
kubectl get workspace -n inference -w

# Check which GPU node NAP provisioned
kubectl get nodes -l karpenter.azure.com/sku-family=NC

# Watch KEDA scaling decisions
kubectl get scaledobject -n inference
kubectl describe scaledobject inference-sb-scaler -n inference

# Check GPU utilization inside a pod
kubectl exec -n inference <pod-name> -- nvidia-smi

# View vLLM metrics (port-forward first)
kubectl port-forward svc/workspace-phi4-mini 5000:5000 -n inference &
curl http://localhost:5000/metrics | grep vllm

# Force scale-to-zero (test cold-start)
kubectl scale deployment workspace-phi4-mini -n inference --replicas=0

# Send a Service Bus message (triggers KEDA scale-up)
az servicebus queue message send \
  --resource-group rg-aks-ai-lab \
  --namespace-name <SB_NAMESPACE> \
  --name inference-requests \
  --body '{"model":"phi-4-mini-instruct","messages":[{"role":"user","content":"Hello"}]}'

# Tear down everything (NAP deprovisions GPU nodes automatically)
cd terraform && terraform destroy
```

---

## Cost Awareness

| Component | When billed | Approx. cost |
|---|---|---|
| System node pool (D4ds_v5 x2) | Always | ~$0.37/hr total |
| NC4as_T4_v3 (Phi-4/Phi-3) | Only when NAP provisions | ~$0.53/hr |
| NC16as_T4_v3 (Mistral 7B) | Only when NAP provisions | ~$1.20/hr |
| NC6s_v3 (Llama 3 8B) | Only when NAP provisions | ~$0.90/hr |
| NC24ads_A100_v4 (Llama 3 70B) | Only when NAP provisions | ~$3.67/hr per node |
| Key Vault | Always (minimal) | ~$5/mo |
| Service Bus (Standard) | Per operation | ~$0.01/mo for lab |

**NAP deprovisioning:** GPU nodes are removed after `consolidateAfter: 2m` of
idle. A dev/test workflow that runs occasional requests will pay for GPU time
only while actively inferencing — often under $5/day.

---

## Troubleshooting

### Workspace stuck in `Pending`
```bash
kubectl describe workspace workspace-phi4-mini -n inference
kubectl get events -n inference --sort-by=.lastTimestamp

# Common causes:
# 1. GPU quota exhausted → request quota increase
# 2. NAP NodePool limits reached → increase limits in gpu-nodepool.yaml
# 3. Feature flags not registered → re-run 00-prereqs.sh
```

### Pod OOMKilled
```bash
kubectl describe pod <pod-name> -n inference
# Reduce max-model-len or max-num-seqs in the KAITO ConfigMap.
# Or upgrade to a larger GPU SKU in the Workspace instanceType.
```

### KEDA not scaling
```bash
kubectl describe scaledobject inference-sb-scaler -n inference
# Check: "READY" = True, "ACTIVE" = True/False
# Common causes:
# 1. TriggerAuthentication misconfigured (wrong client ID)
# 2. KEDA identity missing role on Service Bus / Prometheus
# 3. Service Bus queue name mismatch
```

### NAP not provisioning GPU nodes
```bash
kubectl get nodepool gpu-inference -o yaml
# Check: limits not exceeded, SKU family allowed in requirements
kubectl logs -n kube-system -l app=karpenter --tail=50
```

---

## Why AKS Instead of a VM?

Both run vLLM on an NVIDIA GPU. The difference is everything around it.

| Dimension | VM (single GPU) | AKS + KAITO + NAP |
|---|---|---|
| Setup time | SSH + docker pull — minutes | Full stack — ~10 min first time |
| GPU billing | 24/7, always on | Only while inference runs (NAP scale-to-zero) |
| Multi-model | Manual port juggling | One KAITO Workspace CRD per model |
| Scaling to N replicas | Manual clone + load balancer | KEDA + NAP handles it automatically |
| Model updates | SSH + container restart | `kubectl apply` new Workspace YAML |
| Secrets / auth | `.env` files, SSH keys | Workload Identity — nothing stored |
| Observability | Whatever you install | DCGM + Managed Prometheus built in |
| Cost at idle | Full GPU VM cost | ~$0 — NAP deprovisioned the node |
| Network isolation | NSG rules | Kubernetes NetworkPolicy + private VNet |
| RBAC | OS-level users | Kubernetes RBAC + Azure RBAC |

**The decisive advantage is scale-to-zero cost.** A T4 VM running 24/7 costs
~$380/month. If your lab or dev workload only uses inference 4 hours/day, NAP
deprovisions the node when idle — you pay ~$50/month instead.

**Use a VM when:**
- You're prototyping a single model for yourself
- You need a persistent GPU for fine-tuning (long jobs that can't tolerate interruption)
- You want zero operational complexity

**Use AKS when:**
- Multiple models running (different teams, different use cases)
- Bursty or unpredictable traffic — KEDA handles spikes, NAP handles GPU supply
- Compliance posture: audit logs, RBAC, network policies, Workload Identity
- You already run other workloads on AKS and want to reuse the cluster

---

## Self-Hosted vs Cloud-Provided Model (Azure OpenAI)

Five reasons to self-host. Most organizations need only one to justify it.

### 1. Data sovereignty
When you call Azure OpenAI, your prompts and completions leave your tenant
boundary and transit Microsoft's inference infrastructure. With a self-hosted
model in AKS, the data never leaves your VNet. This is the deciding factor for
HIPAA, PCI-DSS, EU AI Act, and any customer contract that prohibits data
leaving your environment.

### 2. Cost at high volume

Current API pricing vs self-hosted equivalent:

| Model | Input / 1M tokens | Output / 1M tokens |
|---|---|---|
| GPT-4o (Azure OpenAI) | $2.50 | $10.00 |
| GPT-4o-mini (Azure OpenAI) | $0.15 | $0.60 |
| Self-hosted Mistral 7B (1x T4) | ~$0.004 | ~$0.004 |
| Self-hosted Llama 3.3 70B (2x A100) | ~$0.025 | ~$0.025 |

*Self-hosted cost estimated from GPU VM $/hr ÷ throughput (tok/s × 3600)*

Break-even threshold: roughly **50,000 requests/day** for a 7B model vs
GPT-4o-mini. Below that, the API wins on simplicity. Above that, self-hosting
typically saves 25–50%.

### 3. Customization
You can fine-tune open weights on your own domain data. KAITO supports QLoRA
fine-tuning with a single `kubectl apply`. Fine-tuning GPT-4o is restricted,
more expensive, and the resulting model stays on Microsoft's infrastructure.

### 4. Latency control
Cloud APIs share GPU capacity across all tenants. During peak hours your P95
latency is unpredictable. Self-hosted gives you dedicated GPU, predictable
TTFT, and direct control over `max-num-seqs`, `gpu-memory-utilization`, and
tensor parallelism.

### 5. No vendor dependency
Model versions get deprecated on API providers' schedules. Pricing changes.
Rate limits tighten. With open weights, you pin the version you tested and it
runs forever.

**When to stay with Azure OpenAI:**
- Volume under ~10K requests/day — API wins on simplicity and total cost
- You need GPT-4-class multimodal (vision + function calling) and no open model matches
- No dedicated MLOps capacity — self-hosting is 0.25–0.5 FTE to maintain
- You need Microsoft's compliance certifications (SOC 2, HIPAA BAA) without building them yourself

---

## How to Pick a Model

Run through this in order — the first constraint that applies wins.

```
1. What is your available VRAM?
   ├─ 1x T4  (16 GB) → Phi-4 Mini, Phi-3 Mini, Mistral 7B
   ├─ 1x A10 (24 GB) → Mistral 7B, Phi-4 14B
   ├─ 1x A100 (80 GB) → Llama 3.1 8B, Llama 3.1 70B (quantized)
   └─ 2x A100 (160 GB) → Llama 3.3 70B (full precision)

2. What is your primary task?
   ├─ Customer support / chat       → Mistral 7B (fast, cheap, good instruct following)
   ├─ Code generation               → Mistral Large 2 or Llama 3.3 70B
   ├─ Math / STEM / reasoning       → Phi-4 (beats GPT-4o on MATH benchmark: 80.4% vs 74.6%)
   ├─ Long documents / RAG          → Phi-3 Mini 128K or Llama 3.3 70B (128K context)
   ├─ Multi-turn agents / tool use  → Llama 3.3 70B (best open-source tool-use)
   └─ Edge / batch classification   → Phi-3 Mini or Llama 3.2 3B

3. License requirements?
   ├─ Fully unrestricted (MIT)  → Phi family — zero ambiguity, no attribution
   ├─ Apache 2.0                → Mistral 7B / Mixtral — no restrictions
   └─ Llama Community License   → OK for <700M MAU; not for competing foundation models

4. Do you need fine-tuning?
   ├─ Yes → Mistral 7B or Llama 3.1 8B (most tooling, KAITO QLoRA support)
   └─ No  → Any of the above
```

### Model comparison for this lab

| Model | Params | MMLU | License | Best use case | Min GPU |
|---|---|---|---|---|---|
| Phi-4 Mini | 3.8B | ~70% | MIT | Budget testing, math, edge | T4 16GB |
| Phi-3 Mini 128K | 3.8B | ~68% | MIT | Long context RAG, edge | T4 16GB |
| Mistral 7B v0.3 | 7B | ~64% | Apache 2.0 | Customer support, high volume | T4 16GB |
| Llama 3.1 8B | 8B | ~73% | Llama Community | General purpose, RAG | V100 16GB |
| Llama 3.3 70B | 70B | ~86% | Llama Community | Production, agents, complex reasoning | 2x A100 80GB |

**Benchmark context:** Llama 3.3 70B scores 86% on MMLU vs GPT-4o's 88.1%.
The gap between open-source and proprietary models has effectively closed for
most enterprise tasks as of 2026. A fine-tuned smaller model often outperforms
a larger general-purpose one on your specific domain.

**Recommended starting sequence:**
1. Start with **Phi-4 Mini** — validate your pipeline cheaply on a T4
2. Move to **Mistral 7B** — validate real-world quality for your use case
3. Try **Llama 3.3 70B** — set your quality ceiling before deciding if you need GPT-4o
4. If still not enough — **Azure OpenAI GPT-4o** — now you have a concrete comparison

See `docs/sizing-guide.md` for how to translate your chosen model into
the right node size, pod configuration, and replica count.

---

## Ingress & Traffic Architecture

Ingress for LLM inference is not just a routing problem. It sits at the
intersection of network security, API governance, cost control, and GPU
utilization. A Kubernetes Ingress object alone addresses none of those.

### Three Distinct Layers

| Layer | Component | Responsibility |
|---|---|---|
| 1 — Edge / Global | Azure Front Door | WAF · DDoS · geo-filtering · TLS offload |
| 2 — API Management | Azure API Management | Token rate limiting · AAD auth · cost chargeback · Azure OpenAI fallback |
| 3 — In-cluster Ingress | App Gateway for Containers + Istio | Private routing · mTLS · circuit breakers · KV-cache-aware routing |

These are **not alternatives** — in production you run all three. The most
commonly skipped is Layer 2 (APIM). Without it, GPU pods are directly
callable with no token-level rate limiting, no per-consumer visibility,
and no fallback if vLLM is overloaded.

### Why APIM Is Non-Negotiable for LLM

Request-count rate limiting is meaningless for LLM workloads. A client sending
100 one-token requests costs almost nothing. A client sending 10 requests with
10,000-token prompts is your most expensive consumer. APIM's `llm-token-limit`
policy enforces limits on actual token consumption:

```xml
<llm-token-limit
  counter-key="@(context.Subscription.Id)"
  tokens-per-minute="10000"
  token-quota="5000000"
  token-quota-period="Monthly" />
```

APIM also gives you: Azure OpenAI as an automatic fallback backend on vLLM 503,
prompt logging to Application Insights for cost chargeback, and response caching
so identical prompts never hit the GPU.

### Production Network Topology

![Network Topology](docs/network-topology.svg)

### NGINX Is Retiring — Don't Build on It

The community NGINX Ingress controller reached end-of-life March 2026.
Microsoft's App Routing add-on (NGINX-based) is supported through
November 2026 only. Use it for this lab, not for production.

### In-Cluster Options

| Option | Use for |
|---|---|
| App Routing (NGINX) | Lab / dev only — retiring Nov 2026 |
| App Gateway for Containers | External load balancer boundary — managed TLS, connection draining |
| **Cilium CNI + Envoy Gateway** | **Recommended: eBPF NetworkPolicy + WireGuard mTLS, Envoy Gateway hosts the Inference Extension. No sidecars.** |
| Istio Ingress Gateway | When intra-node mTLS is required (PCI-DSS, HIPAA strict) |
| Gateway API Inference Extension | Add on Envoy Gateway or Istio when running 3+ replicas |

**For the lab:** `az aks addon enable --addon web_application_routing`

See `docs/ingress-guide.md` for the full architecture, APIM policy examples,
network topology, security checklist, and ready-to-apply manifests in
`manifests/ingress/`.

### Azure Firewall and Hub-Spoke: What This Lab Omits

This lab uses a single-spoke VNet (AKS, APIM, and AFD in one network). Enterprise
deployments typically add a hub VNet with Azure Firewall between the spokes:

```
Internet → AFD (WAF) → Azure Firewall (hub) → APIM (spoke) → AKS (spoke)
```

**What Azure Firewall adds that this lab lacks:**

| Concern | This lab | With hub firewall |
|---|---|---|
| Egress control | Pods can reach any internet IP | All egress allow-listed and logged |
| East-west isolation | Cilium policies per pod | Firewall enforces spoke-to-spoke rules |
| Threat intelligence | None | Microsoft threat feed blocks malicious IPs |
| Compliance audit trail | No centralized egress log | Every outbound connection in Log Analytics |

**The gap that matters most right now:** the Envoy Gateway LoadBalancer IP is
publicly reachable, meaning anyone can bypass AFD and APIM and call vLLM
directly with no auth or rate limiting. Fix this with an NSG on the AKS subnet
restricting port 80 inbound to the `ApiManagement` service tag only.

**When to add Azure Firewall:**
- Multiple teams sharing the cluster (hub-spoke isolates blast radius per spoke)
- Compliance requirements mandating centralized egress logging (PCI-DSS, HIPAA)
- VNet connected to on-prem via ExpressRoute or VPN

**Cost note:** Azure Firewall Standard runs ~$1.25/hr (~$900/month). Not
justified for a lab. The NSG-based mitigation above closes the most critical
gap at zero cost.
