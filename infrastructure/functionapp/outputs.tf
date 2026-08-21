output "function_app_name" {
  value = azurerm_function_app_flex_consumption.this.name
}

output "function_app_host_name" {
  value = azurerm_function_app_flex_consumption.this.default_hostname
}
