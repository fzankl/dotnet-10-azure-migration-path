# Azure App Service on .NET 10, with the staging slot the migration runs through.
#
# App Service is the one platform in this repo where the runtime setting means
# something different on Linux than it does on Windows:
#
#   Linux   -- linuxFxVersion selects the platform container image. Point a slot
#              at "DOTNETCORE|10.0" while framework-dependent .NET 8 code is
#              deployed to it and the app does not start. The stack change and
#              the code change have to land in the same slot, together.
#   Windows -- every supported runtime is installed side by side on the worker,
#              so netFrameworkVersion selects nothing on its own. The deployed
#              application's target framework picks the runtime. The portal can
#              read "v10.0" over an app that is still running .NET 8.
#
# That asymmetry is why the inventory script flags Windows sites as VERIFY
# rather than OK: the configuration is not proof. Confirm with
# RuntimeInformation.FrameworkDescription, 
# which src/OrderApi exposes at /version.
resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
}

locals {
  location     = azurerm_resource_group.this.location
  web_app_name = "app-${var.name_prefix}"
  staging_slot = "staging"

  web_app_name_out = coalesce(
    one(azurerm_linux_web_app.this[*].name),
    one(azurerm_windows_web_app.this[*].name),
  )
  default_host_name = coalesce(
    one(azurerm_linux_web_app.this[*].default_hostname),
    one(azurerm_windows_web_app.this[*].default_hostname),
  )
  slot_host_name = coalesce(
    one(azurerm_linux_web_app_slot.staging[*].default_hostname),
    one(azurerm_windows_web_app_slot.staging[*].default_hostname),
  )
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

# Standard is the floor for deployment slots. On Free, Shared and Basic there is
# no slot to deploy to, so the swap workflow this file demonstrates is not
# available and the .NET 10 stack change has to be applied to the live app.
# That is the one case where the article's advice to ship configuration and code
# as one change cannot be satisfied by the platform.
resource "azurerm_service_plan" "appservice" {
  name                = "asp-${var.name_prefix}"
  location            = local.location
  resource_group_name = azurerm_resource_group.this.name
  os_type             = var.use_linux ? "Linux" : "Windows"
  sku_name            = "S1"
}

# ---------------------------------------------------------------------------
# Linux
# ---------------------------------------------------------------------------
resource "azurerm_linux_web_app" "this" {
  count = var.use_linux ? 1 : 0

  name                = local.web_app_name
  location            = local.location
  resource_group_name = azurerm_resource_group.this.name
  service_plan_id     = azurerm_service_plan.appservice.id
  https_only          = true

  site_config {
    application_stack {
      # The provider renders this as linuxFxVersion = "DOTNETCORE|10.0"
      # The same string the Resource Graph query in step 1 projects, and the same
      # one `az webapp config set --linux-fx-version` writes.
      dotnet_version = "10.0"
    }

    health_check_path = "/healthz/live"
  }

  app_settings = {
    APPLICATIONINSIGHTS_CONNECTION_STRING = azurerm_application_insights.this.connection_string
    ASPNETCORE_ENVIRONMENT                = "Production"
  }

  # Settings named here stay with the slot across a swap instead of travelling
  # with the code. Useful for per-environment values and the mechanism behind
  # the Functions trap in step 6, where a sticky FUNCTIONS_WORKER_RUNTIME leaves
  # production on the old worker model while the new code lands on top of it.
  # Nothing in the portal flags the mismatch.
  sticky_settings {
    app_setting_names = ["ASPNETCORE_ENVIRONMENT"]
  }
}

resource "azurerm_linux_web_app_slot" "staging" {
  count = var.use_linux ? 1 : 0

  name           = local.staging_slot
  app_service_id = azurerm_linux_web_app.this[0].id
  https_only     = true

  site_config {
    # Deploy the .NET 10 build into this slot and validate it here before the
    # swap. A slot on the .NET 10 image with .NET 8 code deployed does not
    # start, which is the point of finding out in a slot.
    application_stack {
      dotnet_version = "10.0"
    }

    health_check_path = "/healthz/live"
  }

  app_settings = {
    APPLICATIONINSIGHTS_CONNECTION_STRING = azurerm_application_insights.this.connection_string
    ASPNETCORE_ENVIRONMENT                = "Staging"
  }
}

# ---------------------------------------------------------------------------
# Windows
# ---------------------------------------------------------------------------
resource "azurerm_windows_web_app" "this" {
  count = var.use_linux ? 0 : 1

  name                = local.web_app_name
  location            = local.location
  resource_group_name = azurerm_resource_group.this.name
  service_plan_id     = azurerm_service_plan.appservice.id
  https_only          = true

  site_config {
    application_stack {
      current_stack = "dotnet"
      # Windows keeps the "v" prefix that the Linux resource above drops.
      # Same runtime, different string format per resource type.
      # Unlike on Linux, this setting does not select a runtime. All supported
      # runtimes are installed on the worker and the published application's
      # target framework decides which one binds. A .NET 8 app keeps running on
      # .NET 8 with this set to "v10.0", and the portal will report .NET 10.
      dotnet_version = "v10.0"
    }

    health_check_path = "/healthz/live"
  }

  app_settings = {
    APPLICATIONINSIGHTS_CONNECTION_STRING = azurerm_application_insights.this.connection_string
    ASPNETCORE_ENVIRONMENT                = "Production"
  }

  sticky_settings {
    app_setting_names = ["ASPNETCORE_ENVIRONMENT"]
  }
}

resource "azurerm_windows_web_app_slot" "staging" {
  count = var.use_linux ? 0 : 1

  name           = local.staging_slot
  app_service_id = azurerm_windows_web_app.this[0].id
  https_only     = true

  site_config {
    application_stack {
      current_stack  = "dotnet"
      dotnet_version = "v10.0"
    }

    health_check_path = "/healthz/live"
  }

  app_settings = {
    APPLICATIONINSIGHTS_CONNECTION_STRING = azurerm_application_insights.this.connection_string
    ASPNETCORE_ENVIRONMENT                = "Staging"
  }
}
