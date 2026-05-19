variable "name" {
  description = "VPC name prefix"
  type        = string
}

variable "cidr" {
  description = "VPC CIDR block"
  type        = string
}

variable "private_subnets" {
  description = "Map of subnet key → { cidr, az }"
  type = map(object({
    cidr = string
    az   = string
  }))
}

variable "tags" {
  type    = map(string)
  default = {}
}
