output "vpc_id" {
  value = aws_vpc.this.id
}

output "private_subnet_ids" {
  value = { for k, v in aws_subnet.private : k => v.id }
}

output "nat_gateway_id" {
  value = aws_nat_gateway.this.id
}

output "private_route_table_id" {
  value = aws_route_table.private.id
}
