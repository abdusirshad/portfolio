terraform {
  required_version = ">= 1.7.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }

  # Dual remote state backends — Azure Blob (primary) + AWS S3 (secondary)
  # Switch active backend via TF_BACKEND env var in CI
  backend "azurerm" {
    resource_group_name  = "rg-tfstate-prod"
    storage_account_name = "siriusaitfstateprod"
    container_name       = "tfstate"
    key                  = "multicloud/prod/terraform.tfstate"
    use_azuread_auth     = true
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
    key_vault {
      purge_soft_delete_on_destroy = false
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = local.common_tags
  }
}

locals {
  env = "prod"
  common_tags = {
    environment = local.env
    project     = "siriusai-platform"
    managed_by  = "terraform"
    owner       = "platform-team"
  }
}

# ── Azure Hub VNet ────────────────────────────────────────────────────────────
module "hub_vnet" {
  source              = "../../modules/azure-vnet"
  name                = "vnet-hub-${local.env}"
  resource_group_name = "rg-hub-${local.env}"
  location            = var.azure_location
  address_space       = ["10.0.0.0/16"]
  subnets = {
    GatewaySubnet  = { cidr = "10.0.0.0/27" }
    AzureFirewallSubnet = { cidr = "10.0.1.0/26" }
    mgmt           = { cidr = "10.0.2.0/24" }
  }
  tags = local.common_tags
}

# ── Azure Spoke VNet (AKS) ────────────────────────────────────────────────────
module "spoke_vnet_aks" {
  source              = "../../modules/azure-vnet"
  name                = "vnet-spoke-aks-${local.env}"
  resource_group_name = "rg-spoke-aks-${local.env}"
  location            = var.azure_location
  address_space       = ["10.10.0.0/22"]
  subnets = {
    aks-system = { cidr = "10.10.0.0/24" }
    aks-user   = { cidr = "10.10.1.0/24" }
    aks-gpu    = { cidr = "10.10.2.0/24" }
  }
  hub_vnet_id = module.hub_vnet.vnet_id
  tags        = local.common_tags
}

# ── AKS Cluster ───────────────────────────────────────────────────────────────
module "aks" {
  source              = "../../modules/azure-aks"
  cluster_name        = "aks-siriusai-${local.env}"
  resource_group_name = module.spoke_vnet_aks.resource_group_name
  location            = var.azure_location
  dns_prefix          = "siriusai-${local.env}"
  subnet_id           = module.spoke_vnet_aks.subnet_ids["aks-system"]
  acr_id              = var.acr_id
  api_server_authorized_ip_ranges = var.api_server_authorized_ip_ranges
  tags = local.common_tags
}

# ── AWS VPC (us-east-1) ───────────────────────────────────────────────────────
module "aws_vpc" {
  source = "../../modules/aws-vpc"
  name   = "siriusai-${local.env}"
  cidr   = "10.20.0.0/16"
  private_subnets = {
    a = { cidr = "10.20.0.0/24", az = "${var.aws_region}a" }
    b = { cidr = "10.20.1.0/24", az = "${var.aws_region}b" }
    c = { cidr = "10.20.2.0/24", az = "${var.aws_region}c" }
  }
  tags = local.common_tags
}
