output "vm_public_ip" {
  description = "Public IP of the API VM"
  value       = azurerm_public_ip.vm.ip_address
}

output "domain_name" {
  description = "Azure DNS label FQDN for the VM"
  value       = azurerm_public_ip.vm.fqdn
}

output "app_url" {
  description = "HTTPS URL for the LearningSteps API (Nginx + Let's Encrypt)"
  value       = azurerm_public_ip.vm.fqdn != null ? "https://${azurerm_public_ip.vm.fqdn}" : null
}

output "postgresql_fqdn" {
  description = "Fully qualified domain name of the PostgreSQL server"
  value       = azurerm_postgresql_flexible_server.main.fqdn
}

output "resource_group_name" {
  description = "Name of the resource group"
  value       = azurerm_resource_group.main.name
}

output "ssh_command" {
  description = "Command to SSH into the VM using the generated key"
  value       = "ssh ${var.vm_admin_username}@${azurerm_public_ip.vm.ip_address}"
}

output "vm_name" {
  description = "Name of the virtual machine"
  value       = azurerm_linux_virtual_machine.vm.name
}

output "az_ssh_command" {
  description = "Azure AD SSH command (no key file needed, requires VM Administrator Login role)"
  value       = "az ssh vm --resource-group ${azurerm_resource_group.main.name} --name ${azurerm_linux_virtual_machine.vm.name}"
}

output "sentinel_workspace_id" {
  description = "Log Analytics Workspace ID (for Sentinel queries)"
  value       = azurerm_log_analytics_workspace.main.id
}

output "sentinel_portal_url" {
  description = "Direct link to Microsoft Sentinel"
  value       = "https://portal.azure.com/#blade/Microsoft_Azure_Security_Insights/MainMenuBlade/0/id/%2Fsubscriptions%2F${data.azurerm_client_config.current.subscription_id}%2FresourceGroups%2F${azurerm_resource_group.main.name}%2Fproviders%2FMicrosoft.OperationalInsights%2Fworkspaces%2F${azurerm_log_analytics_workspace.main.name}"
}

output "playbook_name" {
  description = "Name of the auto-block Logic App playbook"
  value       = "playbook-block-ip-${var.prefix}"
}
