variable "name" {
  description = "VNet name"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group name"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
}

variable "address_space" {
  description = "VNet address space"
  type        = list(string)
}

variable "subnets" {
  description = "Map of subnet name → { cidr = string }"
  type = map(object({
    cidr = string
  }))
}

variable "hub_vnet_id" {
  description = "Hub VNet resource ID for peering (null if this IS the hub)"
  type        = string
  default     = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
