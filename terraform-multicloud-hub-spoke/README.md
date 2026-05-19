# terraform-multicloud-hub-spoke

[![Terraform](https://img.shields.io/badge/Terraform-1.7.5-7B42BC?style=flat-square&logo=terraform)](https://terraform.io)
[![Azure](https://img.shields.io/badge/Azure-Hub--Spoke-0078D4?style=flat-square&logo=microsoftazure)](https://azure.microsoft.com)
[![AWS](https://img.shields.io/badge/AWS-VPC-FF9900?style=flat-square&logo=amazonaws)](https://aws.amazon.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](LICENSE)

> Production-grade **multi-cloud (Azure + AWS) hub-and-spoke** infrastructure provisioned with **Terraform 1.7.5** and deployed via **9-stage Azure DevOps pipelines** across 9 environments. Eliminates ~80% of manual Terraform invocations through parameterized, reusable modules.

---

## Architecture

```
                          ┌─────────────────────────────────────┐
                          │          Azure Hub VNet              │
                          │  ┌──────────┐  ┌──────────────────┐ │
                          │  │  Bastion │  │  Azure Firewall  │ │
                          │  │   Host   │  │   (optional)     │ │
                          │  └──────────┘  └──────────────────┘ │
                          └──────────┬──────────────────────────┘
                                     │ VNet Peering / VPN
              ┌──────────────────────┼───────────────────────┐
              │                      │                       │
   ┌──────────▼──────┐    ┌──────────▼──────┐    ┌──────────▼──────┐
   │  Azure Spoke 1  │    │  Azure Spoke 2  │    │    AWS VPC      │
   │  (AKS Cluster)  │    │   (App Tier)    │    │  (EKS / RDS)   │
   └─────────────────┘    └─────────────────┘    └─────────────────┘
```

---

## Features

- **9 environments** provisioned from a single pipeline (dev, qa, staging, uat, prod, ...)
- **9-stage Azure DevOps pipeline** with parameterized `component` selection: `vnet | bastion | aks | all`
- **Actions**: `plan_only`, `plan_and_apply`, `destroy` (with dependency-ordered teardown)
- **Remote state**: Azure Blob Storage + AWS S3 + DynamoDB locking (workload-isolated per env)
- **Zero-trust networking**: NSGs, NACLs, Bastion Host (SSH-key-only), allow-listed AKS API access
- **AWS Client VPN**: SAML-federated SSO via Azure AD, split-tunnel UDP/443
- **Manual approval gates** on production environment; branch-locked applies (`main` only)

---

## Repository Structure

```
terraform-multicloud-hub-spoke/
├── modules/
│   ├── azure-vnet/          # Hub + spoke VNet, peering, NSG rules
│   ├── azure-aks/           # AKS cluster, Kubenet, managed identity, ACR RBAC
│   ├── azure-bastion/       # Linux jump-box, SSH-key auth, NSG
│   ├── aws-vpc/             # VPC, subnets, NACLs, route tables
│   └── aws-client-vpn/      # Client VPN, SAML/Azure AD, split tunnel
├── environments/
│   ├── dev/
│   ├── staging/
│   └── prod/
├── pipelines/
│   └── azure-devops.yml     # 9-stage Azure DevOps pipeline
├── backend/
│   ├── azure-backend.tf
│   └── aws-backend.tf
├── main.tf
├── variables.tf
├── outputs.tf
└── README.md
```

---

## Usage

### 1. Configure backends

```bash
# Azure state backend
export ARM_SUBSCRIPTION_ID="<your-subscription-id>"
export ARM_TENANT_ID="<your-tenant-id>"
export ARM_CLIENT_ID="<your-sp-client-id>"
export ARM_CLIENT_SECRET="<your-sp-secret>"

# AWS state backend
export AWS_ACCESS_KEY_ID="<your-access-key>"
export AWS_SECRET_ACCESS_KEY="<your-secret-key>"
```

### 2. Initialize

```bash
cd environments/prod
terraform init \
  -backend-config="resource_group_name=rg-terraform-state" \
  -backend-config="storage_account_name=siriusaiterraformstate" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=prod/hub-spoke.tfstate"
```

### 3. Plan & Apply (component-level)

```bash
# Deploy only VNet
terraform apply -var="component=vnet" -var="environment=prod"

# Deploy AKS only (VNet must exist)
terraform apply -var="component=aks" -var="environment=prod"

# Deploy everything
terraform apply -var="component=all" -var="environment=prod"
```

### 4. Pipeline (Azure DevOps)

Trigger the pipeline with parameters:

| Parameter | Values |
|---|---|
| `component` | `vnet`, `bastion`, `aks`, `all` |
| `action` | `plan_only`, `plan_and_apply`, `destroy` |
| `environment` | `dev`, `qa`, `staging`, `uat`, `prod`, ... |

---

## Modules

### `azure-vnet`

```hcl
module "hub_vnet" {
  source              = "../../modules/azure-vnet"
  name                = "vnet-hub-prod"
  resource_group_name = azurerm_resource_group.hub.name
  location            = var.location
  address_space       = ["10.0.0.0/16"]
  subnets = {
    aks-subnet-1 = { cidr = "10.0.1.0/22", private = true }
    aks-subnet-2 = { cidr = "10.0.5.0/22", private = true }
    aks-subnet-3 = { cidr = "10.0.9.0/22", private = true }
    bastion      = { cidr = "10.0.13.0/28", private = false }
  }
}
```

### `azure-aks`

```hcl
module "aks" {
  source                    = "../../modules/azure-aks"
  cluster_name              = "aks-prod-001"
  resource_group_name       = azurerm_resource_group.spoke.name
  location                  = var.location
  kubernetes_version        = "1.29"
  network_plugin            = "kubenet"
  vnet_subnet_ids           = module.hub_vnet.subnet_ids
  acr_id                    = azurerm_container_registry.acr.id
  node_pools = {
    system = { vm_size = "Standard_D4s_v3", min = 1, max = 3, subnet_index = 0 }
    ai     = { vm_size = "Standard_NC6s_v3", min = 0, max = 5, subnet_index = 1 }
    app    = { vm_size = "Standard_D8s_v3",  min = 2, max = 10, subnet_index = 2 }
  }
}
```

---

## CI/CD Pipeline — Azure DevOps

```yaml
# azure-devops.yml (excerpt)
stages:
  - stage: Validate
    jobs:
      - job: TerraformValidate
        steps:
          - script: terraform fmt -check -recursive
          - script: terraform validate

  - stage: Plan
    jobs:
      - job: TerraformPlan
        steps:
          - script: terraform plan -out=tfplan -var="component=$(component)" -var="environment=$(environment)"
          - publish: tfplan

  - stage: Apply
    condition: and(succeeded(), eq(variables['action'], 'plan_and_apply'), eq(variables['Build.SourceBranch'], 'refs/heads/main'))
    jobs:
      - deployment: TerraformApply
        environment: $(environment)   # manual approval gate on prod
        steps:
          - script: terraform apply tfplan
```

---

## Security Controls

| Control | Implementation |
|---|---|
| Zero-trust ingress | NSG deny-all-inbound default; explicit allow SSH(22), HTTP(80), Postgres(5432) |
| AKS API access | Restricted to allow-listed IPs + VPN client CIDR (10.100.0.0/24) |
| Bastion access | SSH-key-only auth, no password login |
| Secrets | Service Principal credentials as pipeline secret variables only |
| State locking | DynamoDB + Azure Blob lease — prevents concurrent corrupt applies |
| VPN authentication | SAML-federated SSO via Azure AD, 24h session timeout |

---

## Related Repos

- [aks-production-platform](../02-aks-production-platform) — deep-dive AKS config
- [devsecops-pipeline](../08-devsecops-pipeline) — Trivy + OPA security gates
