variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used for resource naming and tagging."
  type        = string
  default     = "governance-monitoring"
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
  description = "CIDR block for the first public subnet."
  type        = string
  default     = "10.0.1.0/24"
}

variable "public_subnet_cidr_2" {
  description = "CIDR block for the second public subnet."
  type        = string
  default     = "10.0.2.0/24"
}

variable "instance_type" {
  description = "EC2 instance type for ASG launch template."
  type        = string
  default     = "t2.micro"
}

variable "asg_min_size" {
  description = "Minimum number of instances in the ASG."
  type        = number
  default     = 1
}

variable "asg_max_size" {
  description = "Maximum number of instances in the ASG."
  type        = number
  default     = 2
}

variable "asg_desired_capacity" {
  description = "Desired number of instances in the ASG."
  type        = number
  default     = 1
}

variable "cpu_alarm_threshold" {
  description = "CPU utilization percentage threshold for scaling alarms."
  type        = number
  default     = 20
}

variable "cloudtrail_bucket_name" {
  description = "Globally unique S3 bucket name for CloudTrail logs."
  type        = string
}

variable "notification_email" {
  description = "Email address for SNS notifications. Leave empty to skip subscription."
  type        = string
  default     = ""
}

variable "lambda_timeout" {
  description = "Lambda function timeout in seconds (must exceed CloudTrail settle time)."
  type        = number
  default     = 240
}

variable "lambda_log_retention_days" {
  description = "CloudWatch log group retention for Lambda function logs."
  type        = number
  default     = 7
}

variable "lookback_minutes" {
  description = "How many minutes back Lambda queries CloudTrail for RunInstances events."
  type        = number
  default     = 10
}
