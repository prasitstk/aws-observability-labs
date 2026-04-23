variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used for resource naming and tagging."
  type        = string
  default     = "cw-metrics-alarms"
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

# --- DynamoDB & S3 (multi-service monitoring) ---

variable "trade_reports_bucket_name" {
  description = "Globally unique S3 bucket name for trade settlement reports."
  type        = string
}

variable "dynamodb_write_alarm_threshold" {
  description = "Consumed write capacity units threshold (sum over 5 min) for DynamoDB alarm."
  type        = number
  default     = 5
}

variable "s3_delete_alarm_threshold" {
  description = "Number of S3 delete requests in 24 hours to trigger alarm."
  type        = number
  default     = 1
}
