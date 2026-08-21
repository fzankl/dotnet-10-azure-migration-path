output "container_app_fqdn" {
  value = azurerm_container_app.this.latest_revision_fqdn
}

output "new_revision_name" {
  value = local.new_revision_name
}
