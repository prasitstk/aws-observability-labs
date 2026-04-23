variable "project_name" {
  description = "Project name used for resource naming."
  type        = string
}

variable "role_name_suffix" {
  description = "Suffix appended to the IAM role name. Useful when multiple profiles exist in one lab."
  type        = string
  default     = "cw-instance"
}

variable "additional_policy_arns" {
  description = "List of additional IAM policy ARNs to attach to the role (e.g., PutMetricData, custom policies)."
  type        = list(string)
  default     = []
}

variable "common_tags" {
  description = "Tags to apply to all resources created by this module."
  type        = map(string)
  default     = {}
}
