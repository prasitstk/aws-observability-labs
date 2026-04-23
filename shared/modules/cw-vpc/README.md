# cw-vpc

Reusable Terraform module for a public-subnet VPC configured for AWS CloudWatch labs.

## Features

- VPC with configurable CIDR block
- Public subnet with internet gateway
- Optional second public subnet in a different AZ (for ASG multi-AZ deployments)
- Security group for monitored instances (egress-only by default)
- No NAT gateway or private subnets — CloudWatch Agent uses HTTPS to public endpoints

## Usage

```hcl
module "cw_vpc" {
  source = "../../../../shared/modules/cw-vpc"

  project_name                = "my-cw-lab"
  vpc_cidr                    = "10.0.0.0/16"
  enable_second_public_subnet = false  # Set true for ASG multi-AZ

  common_tags = local.common_tags
}
```

## Inputs

| Name | Description | Type | Default | Required |
|---|---|---|---|---|
| `project_name` | Project name used for resource naming and tagging | `string` | — | yes |
| `vpc_cidr` | CIDR block for the VPC | `string` | `"10.0.0.0/16"` | no |
| `public_subnet_cidr` | CIDR block for the first public subnet | `string` | `"10.0.1.0/24"` | no |
| `public_subnet_cidr_2` | CIDR block for the second public subnet | `string` | `"10.0.2.0/24"` | no |
| `enable_second_public_subnet` | Whether to create a second public subnet in a different AZ | `bool` | `false` | no |
| `common_tags` | Tags to apply to all resources created by this module | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|---|---|
| `vpc_id` | ID of the VPC |
| `vpc_cidr_block` | CIDR block of the VPC |
| `public_subnet_id` | ID of the first public subnet |
| `public_subnet_id_2` | ID of the second public subnet (null if disabled) |
| `igw_id` | ID of the internet gateway |
| `instance_sg_id` | ID of the instance security group |
| `public_rt_id` | ID of the public route table |
