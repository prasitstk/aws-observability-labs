variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used for resource naming and tagging."
  type        = string
  default     = "ec2-detailed-cw-agent"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)."
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet."
  type        = string
  default     = "10.0.1.0/24"
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t2.micro"
}

variable "instance_count" {
  description = "Number of EC2 instances to launch."
  type        = number
  default     = 2
}

variable "notification_email" {
  description = "Email address for SNS alarm notifications. Leave empty to skip subscription."
  type        = string
  default     = ""
}

variable "cw_agent_collection_interval" {
  description = "CloudWatch Agent metrics collection interval in seconds."
  type        = number
  default     = 60
}

variable "cloudwatch_log_retention_days" {
  description = "Number of days to retain logs in CloudWatch Logs."
  type        = number
  default     = 30
}

variable "high_cpu_threshold" {
  description = "CPUUtilization (%) threshold that triggers the stop-action alarm."
  type        = number
  default     = 75
}

variable "high_cpu_evaluation_periods" {
  description = "Number of consecutive 1-minute periods above the threshold before the alarm fires."
  type        = number
  default     = 1
}
