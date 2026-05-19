output "vnet_id" {
  value = azurerm_virtual_network.this.id
}

output "vnet_name" {
  value = azurerm_virtual_network.this.name
}

output "subnet_ids" {
  value = { for k, v in azurerm_subnet.this : k => v.id }
}

output "resource_group_name" {
  value = azurerm_resource_group.this.name
}
