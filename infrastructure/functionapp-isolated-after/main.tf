# AFTER: the same Function App as ../functionapp-inprocess-before/main.tf,
# now on the isolated worker and .NET 10.
#
# Held as a minimal pair with the "before" file -- plan type, storage and
# structure are identical on both sides:
#
#   diff infrastructure/functionapp-inprocess-before/main.tf \
#        infrastructure/functionapp-isolated-after/main.tf
#
# Five lines differ, and only two of them are the migration:
# dotnet_version moves from 'v8.0' to 'v10.0', and use_dotnet_isolated_runtime
# moves from unset (in-process) to true.
#
# Note that this file changes the hosting configuration only. The application
# itself still has to move to the isolated worker in the same deployment: a
# Function App with this configuration and in-process code deployed to it
# registers no functions. See src/OrderFunctions for the shape of the code
# after that change.
#
# For Linux-specific or Elastic-Premium-specific differences see
# ../functionapp-premium/main.tf instead, which also switches the plan type and
# is therefore no longer a minimal pair.
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

resource "azurerm_service_plan" "consumption" {
  name                = local.plan_name
  location            = local.location
  resource_group_name = azurerm_resource_group.this.name
  os_type             = "Windows"
  sku_name            = "Y1"
}

resource "azurerm_windows_function_app" "this" {
  name                       = local.function_app_name
  location                   = local.location
  resource_group_name        = azurerm_resource_group.this.name
  service_plan_id            = azurerm_service_plan.consumption.id
  storage_account_name       = azurerm_storage_account.this.name
  storage_account_access_key = azurerm_storage_account.this.primary_access_key
  https_only                 = true

  app_settings = {
    FUNCTIONS_EXTENSION_VERSION = "~4"
  }

  site_config {
    application_stack {
      # Changed: v8.0 -> v10.0
      dotnet_version = "v10.0"
      # Changed: unset -> true. This is the one setting that decides
      # in-process versus isolated worker.
      use_dotnet_isolated_runtime = true
    }
  }
}
