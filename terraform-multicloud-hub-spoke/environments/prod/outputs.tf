output "hub_vnet_id" {
  value = module.hub_vnet.vnet_id
}

output "spoke_aks_vnet_id" {
  value = module.spoke_vnet_aks.vnet_id
}

output "aks_cluster_id" {
  value = module.aks.cluster_id
}

output "aks_oidc_issuer_url" {
  description = "OIDC issuer URL for Workload Identity federation"
  value       = module.aks.oidc_issuer_url
}

output "aws_vpc_id" {
  value = module.aws_vpc.vpc_id
}

output "aws_private_subnet_ids" {
  value = module.aws_vpc.private_subnet_ids
}
