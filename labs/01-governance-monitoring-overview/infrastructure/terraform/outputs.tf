# --- VPC ---

output "vpc_id" {
  description = "ID of the VPC"
  value       = module.cw_vpc.vpc_id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets (2 AZ)"
  value       = [module.cw_vpc.public_subnet_id, module.cw_vpc.public_subnet_id_2]
}

# --- ASG ---

output "asg_name" {
  description = "Name of the Auto Scaling Group"
  value       = aws_autoscaling_group.main.name
}

output "launch_template_id" {
  description = "ID of the launch template"
  value       = aws_launch_template.asg.id
}

# --- Scaling ---

output "scale_out_alarm_name" {
  description = "Name of the scale-out CloudWatch alarm"
  value       = aws_cloudwatch_metric_alarm.scale_out.alarm_name
}

output "scale_in_alarm_name" {
  description = "Name of the scale-in CloudWatch alarm"
  value       = aws_cloudwatch_metric_alarm.scale_in.alarm_name
}

# --- SNS ---

output "trigger_topic_arn" {
  description = "ARN of the SNS trigger topic (alarm -> Lambda)"
  value       = aws_sns_topic.trigger.arn
}

output "email_topic_arn" {
  description = "ARN of the SNS email topic (Lambda -> email)"
  value       = aws_sns_topic.email.arn
}

# --- Lambda ---

output "lambda_function_name" {
  description = "Name of the Lambda event processor function"
  value       = aws_lambda_function.event_processor.function_name
}

output "lambda_function_arn" {
  description = "ARN of the Lambda event processor function"
  value       = aws_lambda_function.event_processor.arn
}

output "lambda_log_group" {
  description = "CloudWatch log group for Lambda function"
  value       = aws_cloudwatch_log_group.lambda.name
}

# --- CloudTrail ---

output "cloudtrail_name" {
  description = "Name of the CloudTrail trail"
  value       = aws_cloudtrail.main.name
}

output "cloudtrail_bucket" {
  description = "Name of the S3 bucket for CloudTrail logs"
  value       = aws_s3_bucket.cloudtrail.id
}

# --- CloudWatch ---

output "dashboard_name" {
  description = "Name of the CloudWatch dashboard"
  value       = aws_cloudwatch_dashboard.governance.dashboard_name
}

# --- Convenience ---

output "stress_test_command" {
  description = "AWS CLI command to run stress test on ASG instances via SSM"
  value       = "aws ssm send-command --document-name AWS-RunShellScript --targets Key=tag:Project,Values=${var.project_name} --parameters 'commands=[\"stress-ng --cpu $(nproc) --timeout 300s\"]' --region ${var.aws_region}"
}
