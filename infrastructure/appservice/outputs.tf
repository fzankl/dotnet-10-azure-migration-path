output "web_app_name" {
  description = "Name of the production App Service."
  value       = local.web_app_name_out
}

output "web_app_default_hostname" {
  description = "Production hostname. Check GET /version to confirm the runtime that is actually loaded."
  value       = local.default_host_name
}

output "staging_slot_hostname" {
  description = "Staging slot hostname. Deploy and validate the .NET 10 build here before swapping."
  value       = local.slot_host_name
}

output "swap_command" {
  description = "The swap to run once the staging slot has been validated."
  value = join(" ", [
    "az webapp deployment slot swap",
    "--name ${local.web_app_name_out}",
    "--resource-group ${azurerm_resource_group.this.name}",
    "--slot ${local.staging_slot}",
    "--target-slot production",
  ])
}
