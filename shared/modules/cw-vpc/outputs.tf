output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_id" {
  description = "ID of the first public subnet"
  value       = aws_subnet.public.id
}

output "public_subnet_id_2" {
  description = "ID of the second public subnet (null if disabled)"
  value       = var.enable_second_public_subnet ? aws_subnet.public_2[0].id : null
}

output "igw_id" {
  description = "ID of the internet gateway"
  value       = aws_internet_gateway.this.id
}

output "instance_sg_id" {
  description = "ID of the instance security group"
  value       = aws_security_group.instance.id
}

output "public_rt_id" {
  description = "ID of the public route table"
  value       = aws_route_table.public.id
}
