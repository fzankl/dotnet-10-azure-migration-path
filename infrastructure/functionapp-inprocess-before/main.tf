# BEFORE: a Function App on the in-process model, .NET 8, Windows Consumption.
#
# The "before" half of a minimal pair with
# ../functionapp-isolated-after/main.tf (isolated worker, .NET 10). Not a
# starting point for new deployments -- it exists to be diffed:
#
#   diff infrastructure/functionapp-inprocess-before/main.tf \
#        infrastructure/functionapp-isolated-after/main.tf
#
# What the pair demonstrates is the WORKER MODEL change, not a change of
# hosting plan. Windows Consumption is not itself affected by the November 2026
# cutoff, the in-process model is. The plan type, storage and structure are
# held identical on both sides so the diff shows only the migration.
#
# Linux Consumption is the separate problem, and it is not fixable in a file
# like this one. It will not receive a .NET 10 update, .NET 9 is the last
# version it supports, and Microsoft retires the plan on 30 September 2028. A
# Linux Consumption app that needs .NET 10 moves to a new Function App on Flex
# Consumption: see ../functionapp/main.tf for that target.
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

# Windows Consumption needs no plan sizing. 'Y1' is the whole decision.
# Deliberately the simplest and most common starting point: most in-process
# apps look exactly like this.
#
# Note that Consumption has no deployment slots, so the slot-swap workflow the
# article uses to ship configuration and code together is unavailable here.
# On this plan the migration is an in-place restart.
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
      # Changed in the "after" file: v8.0 -> v10.0
      dotnet_version = "v8.0"
      # THE setting that decides in-process versus isolated worker.
      # Unset (false) means in-process, which loses support on
      # 10 November 2026 along with .NET 8 itself.
    }
  }
}
