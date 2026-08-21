variable "resource_group_name" {
  description = "Name of the resource group to create."
  type        = string
}

variable "name_prefix" {
  description = "Base name used to derive resource names."
  type        = string
}

variable "location" {
  description = "Location for the resource group and all resources."
  type        = string
}

variable "container_image" {
  description = "Fully qualified image reference, e.g. myregistry.azurecr.io/orderapi:10.0"
  type        = string
}

variable "revision_suffix" {
  description = "Suffix identifying this revision, e.g. net10."
  type        = string
  default     = "net10"
}

variable "new_revision_traffic_weight" {
  description = "Percentage of traffic sent to the new revision. Start at 10."
  type        = number
  default     = 10

  validation {
    condition     = var.new_revision_traffic_weight >= 0 && var.new_revision_traffic_weight <= 100
    error_message = "new_revision_traffic_weight must be between 0 and 100."
  }
}

variable "current_revision_suffix" {
  # Note this is a suffix, not the full revision name. The ARM traffic array
  # took a full revisionName like "app--net8". azurerm_container_app's 
  # traffic_weight block only wants the part after "--" and derives the rest itself
  # Passing the full name here silently targets a revision that doesn't exist.
  #
  # With name_prefix = "orderapi-dev" the app is "ca-orderapi-dev" and the old
  # revision is "ca-orderapi-dev--net8", so:
  #   current_revision_suffix = "net8"                    - correct
  #   current_revision_suffix = "ca-orderapi-dev--net8"   - wrong, expands to "ca-orderapi-dev--ca-orderapi-dev--net8"
  description = "Suffix of the revision currently serving production traffic (the revision_suffix from the previous apply). Leave empty on first deploy."
  type        = string
  default     = ""
}
