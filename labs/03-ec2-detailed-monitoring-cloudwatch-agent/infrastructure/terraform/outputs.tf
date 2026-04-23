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
  value       = aws_instance.monitored[*].id
}

output "instance_public_ips" {
  description = "List of EC2 public IP addresses"
  value       = aws_instance.monitored[*].public_ip
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

# --- SSM ---

output "cw_agent_parameter_name" {
  description = "Name of the SSM parameter containing CloudWatch Agent config"
  value       = aws_ssm_parameter.cw_agent_config.name
}

# --- CloudWatch ---

output "dashboard_name" {
  description = "Name of the CloudWatch dashboard"
  value       = aws_cloudwatch_dashboard.detailed_vs_agent.dashboard_name
}

output "log_group_name" {
  description = "Name of the CloudWatch log group for agent logs"
  value       = aws_cloudwatch_log_group.agent_logs.name
}

output "memory_alarm_names" {
  description = "Names of the high memory alarms"
  value       = aws_cloudwatch_metric_alarm.high_memory[*].alarm_name
}

output "high_cpu_stop_alarm_names" {
  description = "Names of the high-CPU alarms that issue an EC2 stop action"
  value       = aws_cloudwatch_metric_alarm.high_cpu_stop[*].alarm_name
}

output "cw_agent_namespace" {
  description = "Custom namespace for CloudWatch Agent metrics"
  value       = local.cw_namespace
}

# --- SNS ---

output "sns_topic_arn" {
  description = "ARN of the SNS topic for alarm notifications"
  value       = aws_sns_topic.cw_alerts.arn
}
