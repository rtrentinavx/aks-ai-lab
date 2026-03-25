###############################################################################
# Outputs
###############################################################################

output "aks_cluster_name" {
  value = azurerm_kubernetes_cluster.lab.name
}

output "resource_group_name" {
  value = azurerm_resource_group.lab.name
}

output "oidc_issuer_url" {
  value       = azurerm_kubernetes_cluster.lab.oidc_issuer_url
  description = "OIDC issuer URL — used when creating federated credentials"
}

output "kaito_identity_client_id" {
  value       = azurerm_user_assigned_identity.kaito.client_id
  description = "Client ID for KAITO GPU provisioner managed identity"
}

output "workload_identity_client_id" {
  value       = azurerm_user_assigned_identity.workload.client_id
  description = "Client ID for workload (inference app) managed identity"
}

output "keda_identity_client_id" {
  value       = azurerm_user_assigned_identity.keda.client_id
  description = "Client ID for KEDA managed identity"
}

output "key_vault_uri" {
  value = azurerm_key_vault.lab.vault_uri
}

output "servicebus_namespace" {
  value = azurerm_servicebus_namespace.lab.name
}

output "servicebus_fqdn" {
  value = "${azurerm_servicebus_namespace.lab.name}.servicebus.windows.net"
}

output "apim_gateway_url" {
  value       = "https://${azurerm_api_management.lab.name}.azure-api.net"
  description = "APIM gateway URL (internal — reachable from VNet or via Front Door)"
}

output "frontdoor_endpoint_hostname" {
  value       = azurerm_cdn_frontdoor_endpoint.inference.host_name
  description = "Front Door public hostname — use this as the inference API entry point"
}


output "nat_gateway_public_ip" {
  value       = var.private_cluster ? azurerm_public_ip.nat_gw[0].ip_address : null
  description = "Static egress IP (only set when private_cluster = true)"
}

output "get_credentials_cmd" {
  value = "az aks get-credentials --resource-group ${azurerm_resource_group.lab.name} --name ${azurerm_kubernetes_cluster.lab.name} --overwrite-existing"
}

output "alb_identity_client_id" {
  value       = azurerm_user_assigned_identity.alb_controller.client_id
  description = "Client ID for App Gateway for Containers ALB controller managed identity"
}

output "agfc_subnet_id" {
  value       = azurerm_subnet.agfc.id
  description = "Resource ID of the AGfC delegated subnet — used in ApplicationLoadBalancer manifest"
}
