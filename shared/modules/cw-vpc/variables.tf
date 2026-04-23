variable "project_name" {
  description = "Project name used for resource naming and tagging."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the first public subnet."
  type        = string
  default     = "10.0.1.0/24"
}

variable "public_subnet_cidr_2" {
  description = "CIDR block for the second public subnet (used when enable_second_public_subnet is true)."
  type        = string
  default     = "10.0.2.0/24"
}

variable "enable_second_public_subnet" {
  description = "Whether to create a second public subnet in a different AZ. Required for ASG multi-AZ deployments (Lab 05)."
  type        = bool
  default     = false
}

variable "common_tags" {
  description = "Tags to apply to all resources created by this module."
  type        = map(string)
  default     = {}
}
