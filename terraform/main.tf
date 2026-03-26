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
  name                = var.cluster_name
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version
  tags                = var.tags

  # Private cluster — API server not reachable from public internet
  private_cluster_enabled             = var.private_cluster
  private_dns_zone_id                 = var.private_cluster ? "System" : null
  private_cluster_public_fqdn_enabled = false

  # Workload Identity prerequisites
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  default_node_pool {
    name                    = "system"
    vm_size                 = "Standard_D4ds_v5"
    auto_scaling_enabled    = false
    node_count              = 2
    os_disk_size_gb         = 128
    vnet_subnet_id          = azurerm_subnet.aks.id
    temporary_name_for_rotation = "systemtmp"

    upgrade_settings {
      max_surge = "33%"
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
# Key Vault
###############################################################################

resource "azurerm_key_vault" "lab" {
  name                       = substr("${var.cluster_name}-kv-${random_string.kv_suffix.result}", 0, 24)
  resource_group_name        = azurerm_resource_group.lab.name
  location                   = azurerm_resource_group.lab.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = false
  soft_delete_retention_days = 7
  tags                       = var.tags
}

# Grant current operator access
resource "azurerm_role_assignment" "kv_operator" {
  scope                = azurerm_key_vault.lab.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Grant workload identity access to read secrets
resource "azurerm_role_assignment" "kv_workload" {
  scope                = azurerm_key_vault.lab.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.workload.principal_id
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
  name                = "${var.cluster_name}-bus"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_servicebus_queue" "inference" {
  name         = "inference-requests"
  namespace_id = azurerm_servicebus_namespace.lab.id

  max_size_in_megabytes = 1024
  lock_duration         = "PT1M"
}

# Grant workload identity data access to Service Bus
resource "azurerm_role_assignment" "sb_workload_sender" {
  scope                = azurerm_servicebus_namespace.lab.id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = azurerm_user_assigned_identity.workload.principal_id
}

resource "azurerm_role_assignment" "sb_workload_receiver" {
  scope                = azurerm_servicebus_namespace.lab.id
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = azurerm_user_assigned_identity.workload.principal_id
}

resource "azurerm_role_assignment" "sb_keda_receiver" {
  scope                = azurerm_servicebus_namespace.lab.id
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

  security_rule {
    name                       = "AllowFrontDoor"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "AzureFrontDoor.Backend"
    destination_address_prefix = "VirtualNetwork"
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

# Backend pointing to the Envoy Gateway internal service on AKS.
# Update the URL after the inference service is deployed.
resource "azurerm_api_management_backend" "inference" {
  name                = "aks-inference-backend"
  resource_group_name = azurerm_resource_group.lab.name
  api_management_name = azurerm_api_management.lab.name
  protocol            = "http"
  url                 = "http://inference-gateway.inference.svc.cluster.local/v1"

  tls {
    validate_certificate_chain = false
    validate_certificate_name  = false
  }
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

resource "azurerm_api_management_api_policy" "inference" {
  api_name            = azurerm_api_management_api.inference.name
  resource_group_name = azurerm_resource_group.lab.name
  api_management_name = azurerm_api_management.lab.name

  xml_content = <<-XML
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
