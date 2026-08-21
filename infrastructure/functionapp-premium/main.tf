# Alternative: Azure Functions on an Elastic Premium plan.
#
# Included because most estates migrating off in-process are not on Flex
# Consumption yet, and on every plan other than Flex the runtime IS still
# configured through a typed application_stack block rather than
# functionAppConfig.runtime. Contrast this file with functionapp/main.tf
# before copying either one.
resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
}

locals {
  location             = azurerm_resource_group.this.location
  storage_account_name = lower("st${replace(var.name_prefix, "-", "")}")
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

resource "azurerm_service_plan" "premium" {
  name                = "asp-${var.name_prefix}"
  location            = local.location
  resource_group_name = azurerm_resource_group.this.name
  os_type             = var.use_linux ? "Linux" : "Windows"
  sku_name            = "EP1"

  maximum_elastic_worker_count = 20
}

resource "azurerm_linux_function_app" "this" {
  count = var.use_linux ? 1 : 0

  name                       = local.function_app_name
  location                   = local.location
  resource_group_name        = azurerm_resource_group.this.name
  service_plan_id            = azurerm_service_plan.premium.id
  storage_account_name       = azurerm_storage_account.this.name
  storage_account_access_key = azurerm_storage_account.this.primary_access_key
  https_only                 = true

  site_config {
    application_stack {
      # Linux dotnet_version drops the "v" prefix that the Windows resource uses below.
      # Same runtime, different string format per resource type.
      dotnet_version              = "10.0"
      use_dotnet_isolated_runtime = true
    }
  }
}

resource "azurerm_windows_function_app" "this" {
  count = var.use_linux ? 0 : 1

  name                       = local.function_app_name
  location                   = local.location
  resource_group_name        = azurerm_resource_group.this.name
  service_plan_id            = azurerm_service_plan.premium.id
  storage_account_name       = azurerm_storage_account.this.name
  storage_account_access_key = azurerm_storage_account.this.primary_access_key
  https_only                 = true

  site_config {
    application_stack {
      # Windows keeps the "v" prefix that the Linux resource above drops.
      # Same runtime, different string format per resource type.
      dotnet_version = "v10.0"
      # The single setting that decides in-process versus isolated worker.
      # false (or the block omitted) means in-process, and in-process stops
      # being a supported value on 10 November 2026. Gate your pipeline on
      # this rather than on netFrameworkVersion, which changes independently.
      use_dotnet_isolated_runtime = true
    }
  }
}
