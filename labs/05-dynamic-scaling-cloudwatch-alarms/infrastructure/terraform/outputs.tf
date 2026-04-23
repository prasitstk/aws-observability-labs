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

output "instance_profile_name" {
  description = "Name of the instance profile"
  value       = module.cw_instance_profile.instance_profile_name
}

# --- Scaling Policies ---

output "target_tracking_policy_name" {
  description = "Name of the target tracking scaling policy"
  value       = aws_autoscaling_policy.target_tracking_cpu.name
}

output "step_scale_out_policy_name" {
  description = "Name of the step scale-out policy"
  value       = aws_autoscaling_policy.step_scale_out.name
}

output "step_scale_in_policy_name" {
  description = "Name of the step scale-in policy"
  value       = aws_autoscaling_policy.step_scale_in.name
}

# --- CloudWatch ---

output "dashboard_name" {
  description = "Name of the CloudWatch dashboard"
  value       = aws_cloudwatch_dashboard.scaling.dashboard_name
}

output "step_high_cpu_alarm_name" {
  description = "Name of the step scaling high CPU alarm"
  value       = aws_cloudwatch_metric_alarm.step_high_cpu.alarm_name
}

output "step_low_cpu_alarm_name" {
  description = "Name of the step scaling low CPU alarm"
  value       = aws_cloudwatch_metric_alarm.step_low_cpu.alarm_name
}

# --- SNS ---

output "sns_topic_arn" {
  description = "ARN of the SNS topic for scaling notifications"
  value       = aws_sns_topic.scaling_notifications.arn
}

# --- SQS ---

output "queue_url" {
  description = "URL of the financial orders SQS queue"
  value       = aws_sqs_queue.orders.url
}

output "queue_arn" {
  description = "ARN of the financial orders SQS queue"
  value       = aws_sqs_queue.orders.arn
}

output "queue_name" {
  description = "Name of the financial orders SQS queue"
  value       = aws_sqs_queue.orders.name
}

output "simple_scale_out_policy_name" {
  description = "Name of the SQS-driven simple scale-out policy"
  value       = aws_autoscaling_policy.simple_scale_out.name
}

output "simple_scale_in_policy_name" {
  description = "Name of the SQS-driven simple scale-in policy"
  value       = aws_autoscaling_policy.simple_scale_in.name
}

output "queue_high_alarm_name" {
  description = "Name of the CloudWatch alarm that triggers simple scale-out"
  value       = aws_cloudwatch_metric_alarm.queue_high.alarm_name
}

output "queue_low_alarm_name" {
  description = "Name of the CloudWatch alarm that triggers simple scale-in"
  value       = aws_cloudwatch_metric_alarm.queue_low.alarm_name
}

# --- Convenience ---

output "stress_test_command" {
  description = "AWS CLI command to run CPU stress test on ASG instances (drives CPU alarms)"
  value       = "aws ssm send-command --document-name AWS-RunShellScript --targets Key=tag:Project,Values=${var.project_name} --parameters 'commands=[\"stress-ng --cpu $(nproc) --timeout 300s\"]' --region ${var.aws_region}"
}

output "load_generator_command" {
  description = "Command to seed the queue and drive SQS-based scaling"
  value       = "python src/generate_load.py --queue-url ${aws_sqs_queue.orders.url} --region ${var.aws_region} --count 20"
}
