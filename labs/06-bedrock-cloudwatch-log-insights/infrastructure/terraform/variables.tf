variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "bedrock-log-insights"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "bucket_name_override" {
  type        = string
  default     = ""
  description = "Optional explicit S3 bucket name. Auto-generated from project + account + region if empty."
}

variable "trade_input_prefix" {
  type        = string
  default     = "trade-input/"
  description = "S3 key prefix that triggers the trade-processor Lambda."
}

variable "trade_output_prefix" {
  type        = string
  default     = "trade-output/"
  description = "S3 key prefix where classified trade CSVs are written."
}

variable "trade_processor_timeout" {
  type    = number
  default = 60
}

variable "log_analyzer_timeout" {
  type        = number
  default     = 300
  description = "Analyzer Lambda timeout. Bedrock + Logs cold path can take up to a few minutes."
}

variable "log_analyzer_memory_size" {
  type    = number
  default = 256
}

variable "bedrock_model_id" {
  type        = string
  default     = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
  description = "Bedrock cross-region inference profile ID for log summarisation."
}

variable "bedrock_foundation_model_arn" {
  type        = string
  default     = "arn:aws:bedrock:*::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0"
  description = "Underlying foundation-model ARN granted alongside the inference profile (cross-region routing needs both)."
}

variable "cloudwatch_log_retention_days" {
  type        = number
  default     = 30
  description = "CloudWatch Logs retention for the trade-processor and log-analyzer Lambdas. 30 days gives a longer post-mortem window for Bedrock-assisted analysis."
}

variable "notification_email" {
  description = "Email address for SNS alarm notifications. Leave empty to skip subscription."
  type        = string
  default     = ""
}

variable "analyzer_duration_p90_threshold_ms" {
  description = "p90 threshold for the log-analyzer Lambda duration alarm. Bedrock invocations are slow; tune after observing real traffic."
  type        = number
  default     = 25000
}

variable "grant_processor_putmetric" {
  type        = bool
  default     = false
  description = "When false (the default), the trade-processor cannot publish CloudWatch metrics — this produces a controlled AccessDeniedException the analyzer then summarises. Flip to true to 'fix' the role and see a clean summary."
}

variable "recent_events_limit" {
  type        = number
  default     = 50
  description = "Number of most-recent CloudWatch log events the analyzer forwards to Bedrock."
}
