###############################################################################
# AKS AI Lab — Terraform Main
# Components: AKS + NAP (Karpenter), KAITO, KEDA, Workload Identity, Key Vault
###############################################################################

terraform {
  required_version = ">= 1.7"

  backend "azurerm" {
    # Values injected via backend.hcl (local) or -backend-config env vars (CI).
    # Run scripts/00-bootstrap-state.sh to provision the storage and generate backend.hcl.
  }

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

resource "random_string" "kv_suffix" {
  length  = 4
  upper   = false
  special = false
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = false
    }
  }
  # Authentication is read from environment variables:
  #   ARM_SUBSCRIPTION_ID, ARM_TENANT_ID
  #   ARM_CLIENT_ID + ARM_CLIENT_SECRET  (service principal)
  #   or ARM_USE_CLI=true                (Azure CLI / managed identity)
}

provider "azapi" {}

###############################################################################
# Data Sources
###############################################################################

data "azurerm_client_config" "current" {}

###############################################################################
# Resource Group
###############################################################################

resource "azurerm_resource_group" "lab" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

###############################################################################
# Managed Identity for KAITO GPU Provisioner
###############################################################################

resource "azurerm_user_assigned_identity" "kaito" {
  name                = "${var.cluster_name}-kaito-identity"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = var.tags
}

resource "azurerm_user_assigned_identity" "workload" {
  name                = "${var.cluster_name}-workload-identity"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = var.tags
}

###############################################################################
# VNet + Subnet
###############################################################################

resource "azurerm_virtual_network" "lab" {
  name                = "${var.cluster_name}-vnet"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  address_space       = ["10.0.0.0/8"]
  tags                = var.tags
}

resource "azurerm_subnet" "aks" {
  name                 = "aks-subnet"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = ["10.240.0.0/16"]
}

# NSG for the AKS subnet.
# Locks down the Envoy Gateway LoadBalancer (port 80) to APIM + operator only.
# All other internet inbound is denied at priority 4000.
resource "azurerm_network_security_group" "aks" {
  name                = "${var.cluster_name}-aks-nsg"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = var.tags

  # ── Inbound ──────────────────────────────────────────────────────────────

  # AKS control plane → nodes (required for managed AKS)
  security_rule {
    name                       = "AllowAKSControlPlane"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["443", "10250"]
    source_address_prefix      = "AzureCloud"
    destination_address_prefix = "VirtualNetwork"
  }

  # Azure Load Balancer health probes (required)
  security_rule {
    name                       = "AllowAzureLoadBalancer"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "VirtualNetwork"
  }

  # Intra-VNet (pod-to-pod, node-to-node, APIM → Envoy)
  security_rule {
    name                       = "AllowVnetInbound"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  # Operator IP — port 80 direct access to Envoy Gateway for testing
  security_rule {
    name                       = "AllowOperatorHTTP"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "${var.operator_ip}/32"
    destination_address_prefix = "VirtualNetwork"
  }

  # Block all other internet inbound
  security_rule {
    name                       = "DenyInternetInbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "VirtualNetwork"
  }

  # ── Outbound ─────────────────────────────────────────────────────────────

  # ── Outbound — Azure service tags ────────────────────────────────────────

  # AKS nodes → API server, OIDC issuer, Azure management plane
  security_rule {
    name                       = "AllowAzureCloud"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "AzureCloud"
  }

  # MCR (mcr.microsoft.com) + ACR (*.azurecr.io) — KAITO model images, ALB controller
  security_rule {
    name                       = "AllowAzureContainerRegistry"
    priority                   = 110
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "AzureContainerRegistry"
  }

  # Azure Monitor + Log Analytics (*.ods.opinsights.azure.com, *.monitoring.azure.com)
  security_rule {
    name                       = "AllowAzureMonitor"
    priority                   = 120
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["443", "1886"]
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "AzureMonitor"
  }

  # Key Vault (*.vault.azure.net) — Secrets Store CSI, Workload Identity
  security_rule {
    name                       = "AllowAzureKeyVault"
    priority                   = 130
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "AzureKeyVault"
  }

  # Azure Active Directory (login.microsoftonline.com) — Workload Identity OIDC token exchange
  security_rule {
    name                       = "AllowAzureActiveDirectory"
    priority                   = 140
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "AzureActiveDirectory"
  }

  # Service Bus (*.servicebus.windows.net) — KEDA Service Bus trigger
  security_rule {
    name                       = "AllowServiceBus"
    priority                   = 150
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["443", "5671", "5672"]
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "ServiceBus"
  }

  # Azure Storage (*.blob.core.windows.net) — Terraform state, AKS bootstrap
  security_rule {
    name                       = "AllowStorage"
    priority                   = 160
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "Storage"
  }

  # Intra-VNet (pod-to-pod, node-to-node, KEDA operator, Envoy, etc.)
  security_rule {
    name                       = "AllowVnetOutbound"
    priority                   = 170
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  # ── Outbound — Internet (no Azure service tag available) ─────────────────
  # Required FQDNs (FQDN-level filtering requires Azure Firewall):
  #   docker.io, registry-1.docker.io  — vLLM image, python:3.12-slim, busybox
  #   nvcr.io                          — NVIDIA DCGM exporter image
  #   ghcr.io                          — KEDA HTTP add-on image
  #   github.com, raw.githubusercontent.com, objects.githubusercontent.com
  #                                    — Gateway API CRDs, Inference Extension manifests,
  #                                      Helm chart indexes (kedacore, nvidia)
  #   huggingface.co, cdn-lfs.huggingface.co
  #                                    — Model weights (vLLM standalone only;
  #                                      KAITO uses MCR-hosted images instead)
  security_rule {
    name                       = "AllowInternetEgress"
    priority                   = 200
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "Internet"
  }
}

resource "azurerm_subnet_network_security_group_association" "aks" {
  subnet_id                 = azurerm_subnet.aks.id
  network_security_group_id = azurerm_network_security_group.aks.id
}

###############################################################################
# NAT Gateway — centralized egress for all cluster nodes
###############################################################################

resource "azurerm_public_ip" "nat_gw" {
  count               = var.private_cluster ? 1 : 0
  name                = "${var.cluster_name}-natgw-pip"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = var.tags
}

resource "azurerm_nat_gateway" "lab" {
  count                   = var.private_cluster ? 1 : 0
  name                    = "${var.cluster_name}-natgw"
  resource_group_name     = azurerm_resource_group.lab.name
  location                = azurerm_resource_group.lab.location
  sku_name                = "Standard"
  idle_timeout_in_minutes = 4
  zones                   = ["1", "2", "3"]
  tags                    = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "lab" {
  count                = var.private_cluster ? 1 : 0
  nat_gateway_id       = azurerm_nat_gateway.lab[0].id
  public_ip_address_id = azurerm_public_ip.nat_gw[0].id
}

resource "azurerm_subnet_nat_gateway_association" "aks" {
  count          = var.private_cluster ? 1 : 0
  subnet_id      = azurerm_subnet.aks.id
  nat_gateway_id = azurerm_nat_gateway.lab[0].id
}

###############################################################################
# AKS Cluster
# - OIDC Issuer + Workload Identity (required for KAITO + KEDA auth)
# - Node Auto Provisioning (NAP / Karpenter) enabled
# - AI Toolchain Operator (KAITO) managed add-on enabled
# - KEDA managed add-on enabled
# - Azure Monitor + Managed Prometheus for GPU metrics
###############################################################################

resource "azurerm_kubernetes_cluster" "lab" {
  #checkov:skip=CKV_AZURE_6: API server authorized IP ranges conflict with private_cluster=false lab default; use private_cluster=true for production
  #checkov:skip=CKV_AZURE_116: Azure Policy add-on not required for this lab; add for production compliance enforcement
  #checkov:skip=CKV_AZURE_115: Private cluster controlled by var.private_cluster; default false for lab accessibility
  #checkov:skip=CKV_AZURE_117: Disk encryption set adds cost and complexity not justified for a lab
  #checkov:skip=CKV_AZURE_170: Free SLA tier acceptable for lab; use Standard or Premium for production
  #checkov:skip=CKV_AZURE_226: Ephemeral OS disks require VM SKU support; managed disks used for compatibility with NAP
  #checkov:skip=CKV_AZURE_227: Host-based encryption requires subscription feature registration; not enabled in lab
  #checkov:skip=CKV_AZURE_232: only_critical_addons_enabled disabled — lab has a single system node pool; enabling it blocks KEDA HTTP add-on and other user add-ons. Add a separate user node pool in production and re-enable.
  #trivy:ignore:AVD-AZU-0041: API server authorized IP ranges conflict with private_cluster=false lab default
  #trivy:ignore:AVD-AZU-0042: RBAC enabled via azure_active_directory_role_based_access_control block; false positive
  #tfsec:ignore:AVD-AZU-0041: API server authorized IP ranges conflict with private_cluster=false lab default
  #tfsec:ignore:AVD-AZU-0042: RBAC enabled via azure_active_directory_role_based_access_control block; false positive
  name                = var.cluster_name
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version
  tags                = var.tags

  # AKS-managed Azure AD integration — required for local_account_disabled.
  # Azure RBAC replaces Kubernetes RBAC for access control.
  azure_active_directory_role_based_access_control {
    tenant_id          = data.azurerm_client_config.current.tenant_id
    azure_rbac_enabled = true
  }

  local_account_disabled    = true
  automatic_upgrade_channel = "stable"

  # Private cluster — API server not reachable from public internet
  private_cluster_enabled             = var.private_cluster
  private_dns_zone_id                 = var.private_cluster ? "System" : null
  private_cluster_public_fqdn_enabled = false

  # Workload Identity prerequisites
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  default_node_pool {
    name                         = "system"
    vm_size                      = "Standard_D4ds_v5"
    auto_scaling_enabled         = false
    node_count                   = 2
    os_disk_size_gb              = 128
    max_pods                     = 50
    vnet_subnet_id               = azurerm_subnet.aks.id
    temporary_name_for_rotation  = "systemtmp"
    # only_critical_addons_enabled is intentionally disabled for this lab.
    # Enabling it adds CriticalAddonsOnly:NoSchedule taint to system nodes,
    # which blocks user add-ons (KEDA HTTP, ALB controller, etc.) that don't
    # tolerate it. Production clusters should add a separate user node pool
    # and re-enable this to isolate system from user workloads.

    upgrade_settings {
      # max_surge = "0" avoids provisioning surge nodes during node pool updates.
      # AKS uses maxUnavailable=1 internally — one node drains at a time with no
      # extra capacity needed. Required when vCPU quota is tight.
      max_surge = "0"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  # Enable NAP (Node Auto Provisioning = Karpenter on AKS)
  node_provisioning_profile {
    mode = "Auto"
  }

  # Networking — Azure CNI Overlay is recommended with NAP
  # outbound_type = userAssignedNATGateway routes all egress through the NAT GW
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "cilium"
    network_data_plane  = "cilium"
    pod_cidr            = "192.168.0.0/16"
    service_cidr        = "10.0.0.0/16"
    dns_service_ip      = "10.0.0.10"
    outbound_type       = var.private_cluster ? "userAssignedNATGateway" : "loadBalancer"
  }

  # Azure Monitor + Managed Prometheus (needed for KEDA Prometheus trigger)
  monitor_metrics {
    annotations_allowed = "*"
    labels_allowed      = "*"
  }

  oms_agent {
    log_analytics_workspace_id      = azurerm_log_analytics_workspace.lab.id
    msi_auth_for_monitoring_enabled = true
  }

  # KEDA managed add-on
  workload_autoscaler_profile {
    keda_enabled = true
  }

  # KAITO AI Toolchain Operator managed add-on
  ai_toolchain_operator_enabled = true

  # Istio service mesh (Envoy-based) managed add-on
  service_mesh_profile {
    mode                             = "Istio"
    revisions                        = ["asm-1-28"]
    external_ingress_gateway_enabled = true
    internal_ingress_gateway_enabled = false
  }

  key_vault_secrets_provider {
    secret_rotation_enabled = true
  }
}

###############################################################################
# Log Analytics Workspace
###############################################################################

resource "azurerm_log_analytics_workspace" "lab" {
  name                = "${var.cluster_name}-law"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

###############################################################################
# Azure Monitor Workspace (Managed Prometheus)
###############################################################################

resource "azapi_resource" "azure_monitor_workspace" {
  type      = "Microsoft.Monitor/accounts@2023-04-03"
  name      = "${var.cluster_name}-amw"
  location  = azurerm_resource_group.lab.location
  parent_id = azurerm_resource_group.lab.id
  tags      = var.tags

  body = {
    properties = {}
  }
}

###############################################################################
# Azure Managed Grafana
###############################################################################

resource "azurerm_dashboard_grafana" "lab" {
  name                              = "${var.cluster_name}-grafana"
  resource_group_name               = azurerm_resource_group.lab.name
  location                          = azurerm_resource_group.lab.location
  grafana_major_version             = 11
  # Public access is required; access control is enforced via Azure AD RBAC
  # (Grafana Admin role assignment below). Managed Grafana has no IP firewall.
  public_network_access_enabled     = true
  zone_redundancy_enabled           = false

  identity {
    type = "SystemAssigned"
  }

  azure_monitor_workspace_integrations {
    resource_id = azapi_resource.azure_monitor_workspace.id
  }

  tags = var.tags
}

# Allow Grafana to read from the Managed Prometheus workspace
resource "azurerm_role_assignment" "grafana_prometheus_reader" {
  scope                = azapi_resource.azure_monitor_workspace.id
  role_definition_name = "Monitoring Data Reader"
  principal_id         = azurerm_dashboard_grafana.lab.identity[0].principal_id
}

# Allow the current user/SP to access the Grafana instance
resource "azurerm_role_assignment" "grafana_admin" {
  scope                = azurerm_dashboard_grafana.lab.id
  role_definition_name = "Grafana Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}

###############################################################################
# Key Vault
###############################################################################

#trivy:ignore:AVD-AZU-0013: network_acls block sets default_action=Deny; trivy static analysis does not evaluate the conditional ip_rules expression
resource "azurerm_key_vault" "lab" {
  name                       = substr("${var.cluster_name}-kv-${random_string.kv_suffix.result}", 0, 24)
  resource_group_name        = azurerm_resource_group.lab.name
  location                   = azurerm_resource_group.lab.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 7
  tags                       = var.tags

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
    # VNet subnet rules are added post-deploy when subnet IDs are known.
    # To allow temporary operator access from a known IP, set var.operator_ip.
    ip_rules = var.operator_ip != "" ? [var.operator_ip] : []
  }
}

# Grant current operator access to Key Vault
resource "azurerm_role_assignment" "kv_operator" {
  scope                = azurerm_key_vault.lab.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Grant current operator kubectl access via Azure RBAC.
# Required when azure_active_directory_role_based_access_control is enabled —
# local kubeconfig credentials are no longer sufficient; kubelogin + this
# role assignment is needed to run kubectl commands.
resource "azurerm_role_assignment" "aks_operator_admin" {
  scope                = azurerm_kubernetes_cluster.lab.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Grant workload identity access to read secrets
resource "azurerm_role_assignment" "kv_workload" {
  scope                = azurerm_key_vault.lab.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.workload.principal_id
}

# Grant APIM managed identity access to read Key Vault secrets.
# Required for azurerm_api_management_named_value with value_from_key_vault.
resource "azurerm_role_assignment" "kv_apim" {
  scope                = azurerm_key_vault.lab.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_api_management.lab.identity[0].principal_id
}

###############################################################################
# KAITO GPU Provisioner — Role Assignments
# Requires Contributor on the AKS cluster resource + Reader on the RG
###############################################################################

resource "azurerm_role_assignment" "kaito_contributor" {
  scope                = azurerm_kubernetes_cluster.lab.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.kaito.principal_id
}

resource "azurerm_role_assignment" "kaito_rg_reader" {
  scope                = azurerm_resource_group.lab.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.kaito.principal_id
}

###############################################################################
# KEDA — Monitoring Data Reader for Azure Managed Prometheus
###############################################################################

resource "azurerm_user_assigned_identity" "keda" {
  name                = "${var.cluster_name}-keda-identity"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = var.tags
}

resource "azurerm_role_assignment" "keda_monitoring" {
  scope                = azapi_resource.azure_monitor_workspace.id
  role_definition_name = "Monitoring Data Reader"
  principal_id         = azurerm_user_assigned_identity.keda.principal_id
}

###############################################################################
# Federated Credentials for Workload Identity
###############################################################################

# KAITO GPU Provisioner federated credential
resource "azurerm_federated_identity_credential" "kaito" {
  name                = "kaito-gpu-provisioner"
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.lab.oidc_issuer_url
  user_assigned_identity_id =azurerm_user_assigned_identity.kaito.id
  subject             = "system:serviceaccount:kube-system:gpu-provisioner"
}

# Workload (inference app) federated credential
resource "azurerm_federated_identity_credential" "workload" {
  name                = "workload-inference"
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.lab.oidc_issuer_url
  user_assigned_identity_id =azurerm_user_assigned_identity.workload.id
  subject             = "system:serviceaccount:inference:inference-sa"
}

# KEDA federated credential (for Prometheus TriggerAuthentication)
resource "azurerm_federated_identity_credential" "keda" {
  name                = "keda-prometheus"
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.lab.oidc_issuer_url
  user_assigned_identity_id =azurerm_user_assigned_identity.keda.id
  subject             = "system:serviceaccount:keda:keda-operator"
}

###############################################################################
# Azure Service Bus (for KEDA Service Bus trigger)
###############################################################################

resource "azurerm_servicebus_namespace" "lab" {
  count = var.enable_service_bus ? 1 : 0

  #checkov:skip=CKV_AZURE_199: Double encryption not supported on Standard SKU; upgrade to Premium for production
  #checkov:skip=CKV_AZURE_201: CMK encryption not supported on Standard SKU; upgrade to Premium for production
  #checkov:skip=CKV_AZURE_202: Managed identity provider not available on Standard SKU
  #checkov:skip=CKV_AZURE_204: Public network access required for KEDA operator connectivity in this lab topology
  name                = "${var.cluster_name}-bus"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  sku                 = "Standard"
  local_auth_enabled  = false
  minimum_tls_version = "1.2"
  tags                = var.tags
}

resource "azurerm_servicebus_queue" "inference" {
  count = var.enable_service_bus ? 1 : 0

  name         = "inference-requests"
  namespace_id = azurerm_servicebus_namespace.lab[0].id

  max_size_in_megabytes = 1024
  lock_duration         = "PT1M"
}

# Grant workload identity data access to Service Bus
resource "azurerm_role_assignment" "sb_workload_sender" {
  count = var.enable_service_bus ? 1 : 0

  scope                = azurerm_servicebus_namespace.lab[0].id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = azurerm_user_assigned_identity.workload.principal_id
}

resource "azurerm_role_assignment" "sb_workload_receiver" {
  count = var.enable_service_bus ? 1 : 0

  scope                = azurerm_servicebus_namespace.lab[0].id
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = azurerm_user_assigned_identity.workload.principal_id
}

resource "azurerm_role_assignment" "sb_keda_receiver" {
  count = var.enable_service_bus ? 1 : 0

  scope                = azurerm_servicebus_namespace.lab[0].id
  role_definition_name = "Azure Service Bus Data Owner"
  principal_id         = azurerm_user_assigned_identity.keda.principal_id
}

###############################################################################
# App Gateway for Containers — ALB Controller Identity + Subnet
###############################################################################

resource "azurerm_subnet" "agfc" {
  name                 = "agfc-subnet"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = ["10.241.0.0/24"]

  delegation {
    name = "agfc"
    service_delegation {
      name    = "Microsoft.ServiceNetworking/trafficControllers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_user_assigned_identity" "alb_controller" {
  name                = "${var.cluster_name}-alb-identity"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = var.tags
}

resource "azurerm_role_assignment" "alb_config_manager" {
  scope                = azurerm_resource_group.lab.id
  role_definition_name = "AppGw for Containers Configuration Manager"
  principal_id         = azurerm_user_assigned_identity.alb_controller.principal_id
}

resource "azurerm_role_assignment" "alb_subnet_contributor" {
  scope                = azurerm_subnet.agfc.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.alb_controller.principal_id
}

resource "azurerm_federated_identity_credential" "alb_controller" {
  name                = "alb-controller"
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.lab.oidc_issuer_url
  user_assigned_identity_id =azurerm_user_assigned_identity.alb_controller.id
  subject             = "system:serviceaccount:azure-alb-system:alb-controller-sa"
}

###############################################################################
# APIM — Subnet + NSG
###############################################################################

resource "azurerm_network_security_group" "apim" {
  name                = "${var.cluster_name}-apim-nsg"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  tags                = var.tags

  # ── Inbound (required by Azure for APIM VNet injection) ──────────────────
  security_rule {
    name                       = "AllowAPIMManagement"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3443"
    source_address_prefix      = "ApiManagement"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "AllowAzureLB"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "6390"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "VirtualNetwork"
  }

  # External mode: gateway must be reachable from AFD (restrict to AFD tag only)
  security_rule {
    name                       = "AllowFrontDoor"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443"]
    source_address_prefix      = "AzureFrontDoor.Backend"
    destination_address_prefix = "VirtualNetwork"
  }

  # Operator IP — direct APIM portal access and API testing
  security_rule {
    name                       = "AllowOperatorHTTPS"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "${var.operator_ip}/32"
    destination_address_prefix = "VirtualNetwork"
  }

  # Deny all other internet inbound
  security_rule {
    name                       = "DenyInternetInbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "VirtualNetwork"
  }

  # ── Outbound (required for APIM activation / runtime) ────────────────────
  security_rule {
    name                       = "AllowStorageOutbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "Storage"
  }

  security_rule {
    name                       = "AllowSQLOutbound"
    priority                   = 110
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "1433"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "Sql"
  }

  security_rule {
    name                       = "AllowAADOutbound"
    priority                   = 120
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "AzureActiveDirectory"
  }

  security_rule {
    name                       = "AllowEventHubOutbound"
    priority                   = 130
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["5671", "5672", "443"]
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "EventHub"
  }

  security_rule {
    name                       = "AllowMonitorOutbound"
    priority                   = 140
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["443", "1886"]
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "AzureMonitor"
  }
}

resource "azurerm_subnet" "apim" {
  name                 = "apim-subnet"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = ["10.242.0.0/27"]
}

resource "azurerm_subnet_network_security_group_association" "apim" {
  subnet_id                 = azurerm_subnet.apim.id
  network_security_group_id = azurerm_network_security_group.apim.id
}

resource "azurerm_public_ip" "apim" {
  name                = "${var.cluster_name}-apim-pip"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = "${var.cluster_name}-apim"
  tags                = var.tags
}

###############################################################################
# API Management — External VNet mode, fronted by Azure Front Door Premium
# External mode: gateway has a public endpoint but is still VNet-injected,
# so APIM can reach AKS services internally. The NSG restricts inbound 443
# to AzureFrontDoor.Backend only — direct access is blocked.
# NOTE: Developer_1 SKU takes ~30-45 min to provision
###############################################################################

resource "azurerm_api_management" "lab" {
  #checkov:skip=CKV_AZURE_174: Public endpoint intentional in External VNet mode; NSG restricts inbound 443 to AzureFrontDoor.Backend service tag only
  name                = "${var.cluster_name}-apim"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  publisher_name      = var.apim_publisher_name
  publisher_email     = var.apim_publisher_email
  sku_name            = var.apim_sku

  virtual_network_type = "External"
  virtual_network_configuration {
    subnet_id = azurerm_subnet.apim.id
  }

  public_ip_address_id = azurerm_public_ip.apim.id

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

###############################################################################
# APIM Backends — vLLM (primary) + Azure AI Foundry (circuit breaker fallback)
###############################################################################

# Backend pointing to the Envoy Gateway internal service on AKS.
# Update the URL after the inference service is deployed.
resource "azurerm_api_management_backend" "inference" {
  #checkov:skip=CKV_AZURE_215: HTTP used for internal LB backend; TLS termination at APIM; add TLS on internal LB for production (see ingress-guide.md)
  name                = "aks-inference-backend"
  resource_group_name = azurerm_resource_group.lab.name
  api_management_name = azurerm_api_management.lab.name
  protocol            = "http"
  # Use a valid placeholder when envoy_gateway_ip is not yet known (fresh deploy).
  # Update after cluster bootstrap: terraform apply -var envoy_gateway_ip=<IP>
  url                 = var.envoy_gateway_ip != "" ? "http://${var.envoy_gateway_ip}/v1" : "http://0.0.0.0/v1"

  tls {
    validate_certificate_chain = false
    validate_certificate_name  = false
  }
}

###############################################################################
# Azure OpenAI (AI Foundry) — circuit breaker fallback for vLLM
# All resources gated on enable_foundry_fallback (default: true).
###############################################################################

resource "azurerm_cognitive_account" "foundry" {
  count                 = var.enable_foundry_fallback ? 1 : 0
  name                  = "${var.cluster_name}-foundry"
  resource_group_name   = azurerm_resource_group.lab.name
  location              = azurerm_resource_group.lab.location
  kind                  = "OpenAI"
  sku_name              = "S0"
  custom_subdomain_name = "${var.cluster_name}-foundry"
  tags                  = var.tags

  network_acls {
    default_action = "Allow"
  }
}

resource "azurerm_cognitive_deployment" "fallback" {
  count                = var.enable_foundry_fallback ? 1 : 0
  name                 = var.foundry_deployment
  cognitive_account_id = azurerm_cognitive_account.foundry[0].id

  model {
    format  = "OpenAI"
    name    = "gpt-4o-mini"
    version = "2024-07-18"
  }

  sku {
    name     = "Standard"
    capacity = var.foundry_capacity
  }
}

# Store the Azure OpenAI API key in Key Vault automatically.
# APIM pulls this via Named Value — the key never appears in Terraform state outputs.
resource "azurerm_key_vault_secret" "foundry_api_key" {
  count        = var.enable_foundry_fallback ? 1 : 0
  name         = "foundry-api-key"
  value        = azurerm_cognitive_account.foundry[0].primary_access_key
  key_vault_id = azurerm_key_vault.lab.id

  depends_on = [azurerm_role_assignment.kv_operator]
}

# APIM backend pointing to the Azure OpenAI deployment endpoint.
# URL is derived from the created cognitive account — no manual endpoint variable needed.
resource "azurerm_api_management_backend" "foundry" {
  count               = var.enable_foundry_fallback ? 1 : 0
  name                = "azure-foundry-backend"
  resource_group_name = azurerm_resource_group.lab.name
  api_management_name = azurerm_api_management.lab.name
  protocol            = "http"
  # Backend base URL — no query string (APIM rejects query strings in backend URL).
  # The api-version and path suffix are appended in the circuit breaker policy
  # via rewrite-uri when the fallback fires.
  url                 = "${azurerm_cognitive_account.foundry[0].endpoint}openai/deployments/${var.foundry_deployment}"

  tls {
    validate_certificate_chain = true
    validate_certificate_name  = true
  }

  depends_on = [azurerm_cognitive_account.foundry]
}

# APIM Named Value — references the Key Vault secret at runtime.
# APIM fetches the value on each policy evaluation via its system-assigned identity.
resource "azurerm_api_management_named_value" "foundry_api_key" {
  count               = var.enable_foundry_fallback ? 1 : 0
  name                = "foundry-api-key"
  resource_group_name = azurerm_resource_group.lab.name
  api_management_name = azurerm_api_management.lab.name
  display_name        = "foundry-api-key"
  secret              = true

  value_from_key_vault {
    secret_id = azurerm_key_vault_secret.foundry_api_key[0].versionless_id
  }

  depends_on = [
    azurerm_key_vault_secret.foundry_api_key,
    azurerm_role_assignment.kv_apim,
  ]
}

resource "azurerm_api_management_api" "inference" {
  name                  = "inference-api"
  resource_group_name   = azurerm_resource_group.lab.name
  api_management_name   = azurerm_api_management.lab.name
  revision              = "1"
  display_name          = "Inference API"
  path                  = "inference"
  protocols             = ["https"]
  subscription_required = true
}

resource "azurerm_api_management_api_operation" "chat_completions" {
  operation_id        = "chat-completions"
  api_name            = azurerm_api_management_api.inference.name
  api_management_name = azurerm_api_management.lab.name
  resource_group_name = azurerm_resource_group.lab.name
  display_name        = "Chat Completions"
  method              = "POST"
  url_template        = "/chat/completions"
}

locals {
  # Heredocs cannot be used in ternary expressions in Terraform, so both
  # policy variants are defined as locals and selected via the conditional.

  apim_policy_simple = <<-XML
    <policies>
      <inbound>
        <base />
        <set-backend-service backend-id="${azurerm_api_management_backend.inference.name}" />
        <rate-limit calls="60" renewal-period="60" />
        <cors>
          <allowed-origins><origin>*</origin></allowed-origins>
          <allowed-methods><method>POST</method><method>OPTIONS</method></allowed-methods>
          <allowed-headers><header>*</header></allowed-headers>
        </cors>
      </inbound>
      <backend><base /></backend>
      <outbound><base /></outbound>
      <on-error><base /></on-error>
    </policies>
  XML

  apim_policy_with_fallback = <<-XML
    <policies>
      <inbound>
        <base />
        <rate-limit calls="60" renewal-period="60" />
        <cors>
          <allowed-origins><origin>*</origin></allowed-origins>
          <allowed-methods><method>POST</method><method>OPTIONS</method></allowed-methods>
          <allowed-headers><header>*</header></allowed-headers>
        </cors>
        <set-variable name="vllm-attempted" value="@(false)" />
        <set-backend-service backend-id="${azurerm_api_management_backend.inference.name}" />
      </inbound>

      <!--
        Circuit breaker: attempt vLLM first. On 502/503/504, retry once against
        Azure AI Foundry. If Foundry also fails the error is returned to the caller.

        Triggers:
          502 Bad Gateway         - Envoy cannot reach the vLLM pod (terminating, OOM)
          503 Service Unavailable - KEDA scaled to zero, interceptor buffering timeout
          504 Gateway Timeout     - vLLM generation exceeded the backend timeout

        On failover the request is transparently rewritten for Foundry:
          - Backend switched to azure-foundry-backend
          - api-key header injected from the APIM Named Value (Key Vault reference)
          - model field rewritten to the Foundry deployment name so the caller
            does not need to know a fallback occurred
      -->
      <backend>
        <retry condition="@(context.Response.StatusCode == 502 || context.Response.StatusCode == 503 || context.Response.StatusCode == 504)"
               count="1" interval="0" first-fast-retry="true">
          <choose>
            <when condition="@((bool)context.Variables[&quot;vllm-attempted&quot;])">
              <set-backend-service backend-id="azure-foundry-backend" />
              <set-header name="api-key" exists-action="override">
                <value>{{foundry-api-key}}</value>
              </set-header>
              <!--
                The Foundry backend URL is {endpoint}/openai/deployments/{deployment}.
                APIM appends the request path (/chat/completions) automatically.
                set-query-parameter injects the required api-version.
                rewrite-uri is NOT allowed in the backend section.
              -->
              <set-query-parameter name="api-version" exists-action="override">
                <value>2024-08-01-preview</value>
              </set-query-parameter>
              <set-body>@{
                var body = context.Request.Body.As&lt;JObject&gt;(preserveContent: true);
                body["model"] = "${var.foundry_deployment}";
                return body.ToString();
              }</set-body>
            </when>
            <otherwise>
              <set-variable name="vllm-attempted" value="@(true)" />
            </otherwise>
          </choose>
          <forward-request timeout="180" />
        </retry>
      </backend>

      <outbound>
        <base />
        <set-header name="X-Inference-Backend" exists-action="override">
          <value>@((bool)context.Variables.GetValueOrDefault&lt;bool&gt;("vllm-attempted") ? "vllm" : "azure-foundry")</value>
        </set-header>
      </outbound>
      <on-error><base /></on-error>
    </policies>
  XML
}

resource "azurerm_api_management_api_policy" "inference" {
  api_name            = azurerm_api_management_api.inference.name
  resource_group_name = azurerm_resource_group.lab.name
  api_management_name = azurerm_api_management.lab.name

  xml_content = var.enable_foundry_fallback ? local.apim_policy_with_fallback : local.apim_policy_simple
}

###############################################################################
# Azure Front Door Premium — global entry point → APIM (External VNet mode)
# AFD connects to APIM's public gateway; NSG blocks all non-AFD inbound 443.
###############################################################################

resource "azurerm_cdn_frontdoor_profile" "lab" {
  name                = "${var.cluster_name}-afd"
  resource_group_name = azurerm_resource_group.lab.name
  sku_name            = "Premium_AzureFrontDoor"
  tags                = var.tags
}

resource "azurerm_cdn_frontdoor_endpoint" "inference" {
  name                     = "${var.cluster_name}-inference"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.lab.id
  tags                     = var.tags
}

resource "azurerm_cdn_frontdoor_origin_group" "apim" {
  name                     = "apim-origin-group"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.lab.id

  load_balancing {
    sample_size                        = 4
    successful_samples_required        = 3
    additional_latency_in_milliseconds = 50
  }

  health_probe {
    path                = "/status-0123456789abcdef"
    protocol            = "Https"
    interval_in_seconds = 30
    request_type        = "HEAD"
  }
}

resource "azurerm_cdn_frontdoor_origin" "apim" {
  name                          = "apim-origin"
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.apim.id
  enabled                       = true

  host_name                      = "${azurerm_api_management.lab.name}.azure-api.net"
  origin_host_header             = "${azurerm_api_management.lab.name}.azure-api.net"
  https_port                     = 443
  http_port                      = 80
  certificate_name_check_enabled = true
  priority                       = 1
  weight                         = 1000
}

resource "azurerm_cdn_frontdoor_route" "inference" {
  name                          = "inference-route"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.inference.id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.apim.id
  cdn_frontdoor_origin_ids      = [azurerm_cdn_frontdoor_origin.apim.id]
  forwarding_protocol           = "HttpsOnly"
  https_redirect_enabled        = true
  patterns_to_match             = ["/*"]
  supported_protocols           = ["Http", "Https"]
  link_to_default_domain        = true

  depends_on = [azurerm_cdn_frontdoor_origin.apim]
}

# WAF policy — detection mode (switch to Prevention for production)
resource "azurerm_cdn_frontdoor_firewall_policy" "lab" {
  name                = "${replace(var.cluster_name, "-", "")}waf"
  resource_group_name = azurerm_resource_group.lab.name
  sku_name            = azurerm_cdn_frontdoor_profile.lab.sku_name
  mode                = "Detection"
  tags                = var.tags

  managed_rule {
    type    = "DefaultRuleSet"
    version = "1.0"
    action  = "Block"
  }
}


resource "azurerm_cdn_frontdoor_security_policy" "lab" {
  name                     = "inference-security-policy"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.lab.id

  security_policies {
    firewall {
      cdn_frontdoor_firewall_policy_id = azurerm_cdn_frontdoor_firewall_policy.lab.id
      association {
        domain {
          cdn_frontdoor_domain_id = azurerm_cdn_frontdoor_endpoint.inference.id
        }
        patterns_to_match = ["/*"]
      }
    }
  }
}
