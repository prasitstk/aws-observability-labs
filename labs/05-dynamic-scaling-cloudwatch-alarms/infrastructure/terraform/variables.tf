variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used for resource naming and tagging."
  type        = string
  default     = "dynamic-scaling"
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
  default     = 4
}

variable "asg_desired_capacity" {
  description = "Desired number of instances in the ASG."
  type        = number
  default     = 2
}

variable "target_cpu_value" {
  description = "Target CPU utilization percentage for target tracking scaling."
  type        = number
  default     = 50
}

variable "notification_email" {
  description = "Email address for SNS notifications. Leave empty to skip subscription."
  type        = string
  default     = ""
}

variable "queue_name_suffix" {
  description = "Suffix appended to the queue name: final name is '<project_name>-<suffix>'."
  type        = string
  default     = "orders"
}

variable "queue_scale_out_threshold" {
  description = "ApproximateNumberOfMessagesVisible threshold that triggers simple scale-out."
  type        = number
  default     = 3
}

variable "queue_scale_in_threshold" {
  description = "ApproximateNumberOfMessagesVisible threshold that triggers simple scale-in."
  type        = number
  default     = 1
}

variable "worker_process_delay_seconds" {
  description = "Simulated processing delay (seconds) per message in the in-instance worker."
  type        = number
  default     = 2
}
