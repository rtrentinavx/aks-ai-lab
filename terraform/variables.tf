###############################################################################
# Variables
###############################################################################

variable "resource_group_name" {
  description = "Resource group name"
  type        = string
  default     = "rg-aks-ai-lab"
}

variable "location" {
  description = "Azure region. Choose one with NC-series GPU quota: eastus, eastus2, westus2, westeurope"
  type        = string
  default     = "eastus2"
}

variable "cluster_name" {
  description = "AKS cluster name (also used as prefix for related resources)"
  type        = string
  default     = "aks-ai-lab"
}

variable "kubernetes_version" {
  description = "AKS Kubernetes version"
  type        = string
  default     = "1.32"
}

variable "apim_publisher_name" {
  description = "APIM publisher display name"
  type        = string
}

variable "apim_publisher_email" {
  description = "APIM publisher email address"
  type        = string
}

variable "apim_sku" {
  description = "APIM SKU. Developer_1 for lab, Premium_1 for production (required for zone redundancy)"
  type        = string
  default     = "Developer_1"
}

variable "private_cluster" {
  description = "Enable private AKS cluster (API server not publicly reachable) with NAT Gateway egress. Requires kubectl/terraform to run from within the VNet."
  type        = bool
  default     = false
}

variable "operator_ip" {
  description = "Your public IPv4 address. Required — used in NSG rules and Key Vault ACL. Find it with: curl -s -4 ifconfig.me"
  type        = string

  validation {
    condition     = can(regex("^(\\d{1,3}\\.){3}\\d{1,3}$", var.operator_ip))
    error_message = "operator_ip must be a valid IPv4 address (e.g. 23.124.126.28)."
  }
}

variable "envoy_gateway_ip" {
  description = "External IP of the Envoy Gateway LoadBalancer service (inference-gateway in the inference namespace). Set after cluster bootstrap: terraform apply -var envoy_gateway_ip=<IP>"
  type        = string
  default     = ""
}

variable "enable_foundry_fallback" {
  description = "Deploy Azure OpenAI (Foundry) resource and enable APIM circuit breaker failover to it. Creates azurerm_cognitive_account, a gpt-4o-mini deployment, stores the API key in Key Vault, and configures the APIM retry policy. Default true."
  type        = bool
  default     = true
}

variable "foundry_deployment" {
  description = "Name of the Azure OpenAI model deployment used as the APIM fallback. Must be a model available in the cluster region."
  type        = string
  default     = "gpt-4o-mini"
}

variable "foundry_capacity" {
  description = "Azure OpenAI deployment capacity in thousands of tokens per minute (TPM). 10 = 10K TPM."
  type        = number
  default     = 10
}

variable "enable_service_bus" {
  description = "Deploy Azure Service Bus and configure KEDA Service Bus trigger authentication. Set to true to enable async inference via queue. Default false — HTTP-based KEDA scaling works without it."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default = {
    env     = "lab"
    project = "aks-ai-lab"
  }
}
