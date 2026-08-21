output "function_app_name" {
  description = "Name of the function app that was created."
  value = coalesce(
    one(azurerm_linux_function_app.this[*].name),
    one(azurerm_windows_function_app.this[*].name),
  )
}
