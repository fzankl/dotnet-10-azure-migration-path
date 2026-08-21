# Azure Functions on Flex Consumption, running the .NET 10 isolated worker.
#
# The migration-relevant part is that on Flex Consumption the runtime is NOT
# configured through the FUNCTIONS_WORKER_RUNTIME and FUNCTIONS_EXTENSION_VERSION
# app settings you may be carrying over from a Consumption or Premium plan. It
# lives in runtime_name / runtime_version on azurerm_function_app_flex_consumption
# instead. A dedicated resource, not azurerm_linux_function_app with a flag.
# Setting the old app settings here is either ignored or rejected, which is a
# common source of "I changed it and nothing happened" during this migration.
resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
}

locals {
  location             = azurerm_resource_group.this.location
  storage_account_name = lower("st${replace(var.name_prefix, "-", "")}")
  plan_name            = "asp-${var.name_prefix}"
  function_app_name    = "func-${var.name_prefix}"
}

resource "azurerm_storage_account" "this" {
  name                            = local.storage_account_name
  location                        = local.location
  resource_group_name             = azurerm_resource_group.this.name
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"
}

resource "azurerm_storage_container" "deployment" {
  name                  = var.deployment_container_name
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${var.name_prefix}"
  location            = local.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_application_insights" "this" {
  name                = "appi-${var.name_prefix}"
  location            = local.location
  resource_group_name = azurerm_resource_group.this.name
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.this.id
}

resource "azurerm_service_plan" "flex" {
  name                = local.plan_name
  location            = local.location
  resource_group_name = azurerm_resource_group.this.name
  os_type             = "Linux"
  sku_name            = "FC1"
}

resource "azurerm_function_app_flex_consumption" "this" {
  name                = local.function_app_name
  location            = local.location
  resource_group_name = azurerm_resource_group.this.name
  service_plan_id     = azurerm_service_plan.flex.id

  # Identity-based storage access. The older AzureWebJobsStorage connection
  # string still works via storage_authentication_type = "StorageAccountConnectionString", 
  # but a migration is a good moment to stop shipping keys in app settings.
  storage_container_type      = "blobContainer"
  storage_container_endpoint  = "${azurerm_storage_account.this.primary_blob_endpoint}${azurerm_storage_container.deployment.name}"
  storage_authentication_type = "SystemAssignedIdentity"

  # This replaces FUNCTIONS_WORKER_RUNTIME and FUNCTIONS_EXTENSION_VERSION.
  runtime_name    = "dotnet-isolated"
  runtime_version = "10.0"

  maximum_instance_count = 40
  instance_memory_in_mb  = 2048

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_insights_connection_string = azurerm_application_insights.this.connection_string
  }
}

# The function app's managed identity needs data-plane access to the deployment
# container. Storage Blob Data Owner is required for one-deploy on Flex Consumption.
resource "azurerm_role_assignment" "function_storage_blob_data_owner" {
  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azurerm_function_app_flex_consumption.this.identity[0].principal_id
}
