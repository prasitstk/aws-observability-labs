variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used for resource naming and tagging."
  type        = string
  default     = "custom-metrics-logging"
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

variable "orders_api_allowed_cidr" {
  description = "CIDR allowed to reach the Flask API on port 5000. Default is 0.0.0.0/0 for lab convenience — tighten for non-lab use."
  type        = string
  default     = "0.0.0.0/0"
}

variable "notification_email" {
  description = "Email address for SNS alarm notifications. Leave empty to skip subscription."
  type        = string
  default     = ""
}

variable "cloudwatch_log_retention_days" {
  description = "Number of days to retain application logs in CloudWatch Logs."
  type        = number
  default     = 30
}

variable "request_latency_threshold_ms" {
  description = "Threshold (milliseconds) for the p90 RequestLatency alarm."
  type        = number
  default     = 2000
}
