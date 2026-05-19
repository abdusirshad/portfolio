resource "azurerm_kubernetes_cluster" "this" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version

  # Kubenet networking — single shared route table topology
  network_profile {
    network_plugin    = "kubenet"
    load_balancer_sku = "standard"
    pod_cidr          = var.pod_cidr
    service_cidr      = var.service_cidr
    dns_service_ip    = var.dns_service_ip
  }

  # User-assigned managed identity — no credential rotation required
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }

  default_node_pool {
    name                 = "system"
    vm_size              = var.node_pools["system"].vm_size
    vnet_subnet_id       = var.vnet_subnet_ids[0]
    min_count            = var.node_pools["system"].min
    max_count            = var.node_pools["system"].max
    enable_auto_scaling  = true
    os_disk_type         = "Ephemeral"
    type                 = "VirtualMachineScaleSets"
    only_critical_addons_enabled = true
  }

  # ACR integration — AcrPull role on user-assigned identity for zero-credential image pulls
  kubelet_identity {
    client_id                 = azurerm_user_assigned_identity.aks_kubelet.client_id
    object_id                 = azurerm_user_assigned_identity.aks_kubelet.principal_id
    user_assigned_identity_id = azurerm_user_assigned_identity.aks_kubelet.id
  }

  api_server_access_profile {
    authorized_ip_ranges = var.api_server_authorized_ip_ranges
  }

  azure_active_directory_role_based_access_control {
    managed            = true
    azure_rbac_enabled = true
  }

  oms_agent {
    log_analytics_workspace_id      = var.log_analytics_workspace_id
    msi_auth_for_monitoring_enabled = true
  }

  maintenance_window {
    allowed {
      day   = "Sunday"
      hours = [2, 4]
    }
  }

  lifecycle {
    ignore_changes = [default_node_pool[0].node_count]
  }

  tags = var.tags
}

# Additional node pools (AI workloads, app tier)
resource "azurerm_kubernetes_cluster_node_pool" "extra" {
  for_each = { for k, v in var.node_pools : k => v if k != "system" }

  name                  = each.key
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = each.value.vm_size
  vnet_subnet_id        = var.vnet_subnet_ids[each.value.subnet_index]
  min_count             = each.value.min
  max_count             = each.value.max
  enable_auto_scaling   = true
  os_disk_type          = "Ephemeral"
  mode                  = "User"

  node_labels = {
    "workload-type" = each.key
  }

  node_taints = each.key == "ai" ? ["nvidia.com/gpu=true:NoSchedule"] : []

  tags = var.tags
}

# User-assigned identity for AKS control plane
resource "azurerm_user_assigned_identity" "aks" {
  name                = "id-${var.cluster_name}-cp"
  resource_group_name = var.resource_group_name
  location            = var.location
}

# User-assigned identity for kubelet (used for ACR pulls)
resource "azurerm_user_assigned_identity" "aks_kubelet" {
  name                = "id-${var.cluster_name}-kubelet"
  resource_group_name = var.resource_group_name
  location            = var.location
}

# AcrPull role assignment — zero-credential image pulls
resource "azurerm_role_assignment" "acr_pull" {
  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.aks_kubelet.principal_id
}

# Kubenet shared route table — elect primary subnet's RT and associate all AKS subnets
locals {
  primary_rt_id = azurerm_kubernetes_cluster.this.network_profile[0].load_balancer_profile[0].effective_outbound_ips[0].id
}

resource "azurerm_subnet_route_table_association" "aks_subnets" {
  for_each       = toset(var.vnet_subnet_ids)
  subnet_id      = each.value
  route_table_id = azurerm_route_table.aks_kubenet.id
}

resource "azurerm_route_table" "aks_kubenet" {
  name                          = "rt-${var.cluster_name}-kubenet"
  location                      = var.location
  resource_group_name           = var.resource_group_name
  disable_bgp_route_propagation = false
  tags                          = var.tags
}
