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

variable "use_linux" {
  description = "Set to true for a Linux plan, false for Windows."
  type        = bool
  default     = true
}
