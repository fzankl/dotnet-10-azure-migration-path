# Container App with two revisions active at once, which is what makes a runtime
# migration reversible: rolling back is a traffic weight change, not a redeploy.
locals {
  app_name          = "ca-${var.name_prefix}"
  new_revision_name = "${local.app_name}--${var.revision_suffix}"
}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${var.name_prefix}"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
}

resource "azurerm_container_app_environment" "this" {
  name                       = "cae-${var.name_prefix}"
  location                   = var.location
  resource_group_name        = azurerm_resource_group.this.name
  logs_destination           = "log-analytics"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
}

resource "azurerm_container_app" "this" {
  name                         = local.app_name
  resource_group_name          = azurerm_resource_group.this.name
  container_app_environment_id = azurerm_container_app_environment.this.id

  # Multiple revisions is the setting that makes a weighted rollout possible.
  # The default, 'Single', deactivates the previous revision immediately.
  revision_mode = "Multiple"

  identity {
    type = "SystemAssigned"
  }

  ingress {
    external_enabled = true
    target_port       = 8080

    # One traffic_weight block on first deploy, two once 
    # there's a previous revision to shift weight away from.
    dynamic "traffic_weight" {
      for_each = var.current_revision_suffix == "" ? [
        {
          revision_suffix = var.revision_suffix
          percentage      = 100
        }
        ] : [
        {
          revision_suffix = var.current_revision_suffix
          percentage      = 100 - var.new_revision_traffic_weight
        },
        {
          revision_suffix = var.revision_suffix
          percentage      = var.new_revision_traffic_weight
        }
      ]

      content {
        revision_suffix = traffic_weight.value.revision_suffix
        percentage      = traffic_weight.value.percentage
      }
    }
  }

  template {
    revision_suffix = var.revision_suffix

    container {
      name   = "orderapi"
      image  = var.container_image
      cpu    = 0.5
      memory = "1Gi"

      startup_probe {
        transport = "HTTP"
        port      = 8080
        path      = "/healthz/live"
        initial_delay            = 5
        interval_seconds         = 5
        failure_count_threshold  = 12
      }

      readiness_probe {
        transport = "HTTP"
        port      = 8080
        path      = "/healthz/ready"

        interval_seconds         = 10
        failure_count_threshold  = 3
      }
    }

    min_replicas = 1
    max_replicas = 10
  }
}
