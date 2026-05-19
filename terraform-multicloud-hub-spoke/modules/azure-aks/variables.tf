variable "cluster_name" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "kubernetes_version" {
  type    = string
  default = "1.29"
}

variable "dns_prefix" {
  type = string
}

variable "subnet_id" {
  description = "Subnet ID for the default node pool"
  type        = string
}

variable "pod_cidr" {
  description = "Kubenet pod CIDR (must not overlap VNet)"
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_cidr" {
  type    = string
  default = "10.100.0.0/16"
}

variable "dns_service_ip" {
  type    = string
  default = "10.100.0.10"
}

variable "system_node_pool" {
  type = object({
    vm_size    = string
    node_count = number
    min_count  = number
    max_count  = number
  })
  default = {
    vm_size    = "Standard_D4s_v5"
    node_count = 3
    min_count  = 2
    max_count  = 5
  }
}

variable "acr_id" {
  description = "ACR resource ID to grant AcrPull"
  type        = string
}

variable "api_server_authorized_ip_ranges" {
  description = "CIDR ranges allowed to reach the AKS API server"
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
