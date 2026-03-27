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

variable "envoy_gateway_ip" {
  description = "External IP of the Envoy Gateway LoadBalancer service (inference-gateway in the inference namespace). Set after cluster bootstrap: terraform apply -var envoy_gateway_ip=<IP>"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default = {
    env     = "lab"
    project = "aks-ai-lab"
  }
}
