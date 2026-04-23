# --- VPC ---

output "vpc_id" {
  description = "ID of the VPC"
  value       = module.cw_vpc.vpc_id
}

output "public_subnet_id" {
  description = "ID of the public subnet"
  value       = module.cw_vpc.public_subnet_id
}

# --- EC2 ---

output "instance_ids" {
  description = "List of EC2 instance IDs"
  value       = aws_instance.web[*].id
}

output "instance_public_ips" {
  description = "List of EC2 public IP addresses"
  value       = aws_instance.web[*].public_ip
}

output "instance_profile_name" {
  description = "Name of the instance profile"
  value       = module.cw_instance_profile.instance_profile_name
}

# --- AMI ---

output "ami_id" {
  description = "ID of the AL2023 AMI used"
  value       = data.aws_ami.al2023.id
}

# --- CloudWatch ---

output "dashboard_name" {
  description = "Name of the CloudWatch dashboard"
  value       = aws_cloudwatch_dashboard.metrics.dashboard_name
}

output "high_cpu_alarm_names" {
  description = "Names of the high CPU alarms"
  value       = aws_cloudwatch_metric_alarm.high_cpu[*].alarm_name
}

output "low_cpu_stop_alarm_names" {
  description = "Names of the low CPU stop alarms"
  value       = aws_cloudwatch_metric_alarm.low_cpu_stop[*].alarm_name
}

output "cpu_anomaly_alarm_names" {
  description = "Names of the CPU anomaly detection alarms"
  value       = aws_cloudwatch_metric_alarm.cpu_anomaly[*].alarm_name
}

output "composite_alarm_name" {
  description = "Name of the composite alarm"
  value       = aws_cloudwatch_composite_alarm.critical.alarm_name
}

# --- DynamoDB ---

output "dynamodb_table_name" {
  description = "Name of the DynamoDB trade executions table"
  value       = aws_dynamodb_table.trade_executions.name
}

output "dynamodb_table_arn" {
  description = "ARN of the DynamoDB trade executions table"
  value       = aws_dynamodb_table.trade_executions.arn
}

# --- S3 ---

output "trade_reports_bucket_name" {
  description = "Name of the S3 trade reports bucket"
  value       = aws_s3_bucket.trade_reports.id
}

output "trade_reports_bucket_arn" {
  description = "ARN of the S3 trade reports bucket"
  value       = aws_s3_bucket.trade_reports.arn
}

# --- New Alarms ---

output "dynamodb_high_writes_alarm_name" {
  description = "Name of the DynamoDB high writes alarm"
  value       = aws_cloudwatch_metric_alarm.dynamodb_high_writes.alarm_name
}

output "s3_delete_requests_alarm_name" {
  description = "Name of the S3 delete requests alarm"
  value       = aws_cloudwatch_metric_alarm.s3_delete_requests.alarm_name
}

# --- SNS ---

output "sns_topic_arn" {
  description = "ARN of the SNS topic for alarm notifications"
  value       = aws_sns_topic.cw_alerts.arn
}
