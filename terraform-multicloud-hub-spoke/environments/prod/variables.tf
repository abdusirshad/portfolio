variable "azure_location" {
  description = "Primary Azure region"
  type        = string
  default     = "eastus"
}

variable "aws_region" {
  description = "Primary AWS region"
  type        = string
  default     = "us-east-1"
}

variable "acr_id" {
  description = "Azure Container Registry resource ID"
  type        = string
}

variable "api_server_authorized_ip_ranges" {
  description = "CIDRs allowed to reach the AKS API server (bastion + VPN egress IPs)"
  type        = list(string)
  default     = []
}
