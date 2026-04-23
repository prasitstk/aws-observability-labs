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

output "orders_api_instance_id" {
  description = "ID of the Orders API EC2 instance"
  value       = aws_instance.orders_api.id
}

output "orders_api_public_ip" {
  description = "Public IP of the Orders API instance (send POST /orders here on port 5000)"
  value       = aws_instance.orders_api.public_ip
}

output "orders_api_url" {
  description = "Full URL to the Orders API /orders endpoint"
  value       = "http://${aws_instance.orders_api.public_ip}:5000/orders"
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
  value       = aws_cloudwatch_dashboard.orders.dashboard_name
}

output "emf_log_group_name" {
  description = "CloudWatch Log group for EMF records"
  value       = aws_cloudwatch_log_group.orders_emf.name
}

output "sdk_log_group_name" {
  description = "CloudWatch Log group for PutMetricData audit records"
  value       = aws_cloudwatch_log_group.orders_sdk.name
}

output "emf_namespace" {
  description = "CloudWatch custom namespace populated by EMF"
  value       = local.emf_namespace
}

output "sdk_namespace" {
  description = "CloudWatch custom namespace populated by PutMetricData"
  value       = local.sdk_namespace
}

output "alarm_name" {
  description = "Name of the request-latency alarm"
  value       = aws_cloudwatch_metric_alarm.request_latency.alarm_name
}

# --- SNS ---

output "sns_topic_arn" {
  description = "ARN of the SNS topic for order alerts"
  value       = aws_sns_topic.orders_alerts.arn
}

# --- CW Agent / SSM ---

output "cw_agent_config_param" {
  description = "SSM Parameter Store name holding the CloudWatch Agent config"
  value       = aws_ssm_parameter.cw_agent_config.name
}
