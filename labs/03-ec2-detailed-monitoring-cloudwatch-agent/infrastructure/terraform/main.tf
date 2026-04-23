# -----------------------------------------------------------------------------
# Lab 03: EC2 Detailed Monitoring + CloudWatch Agent
# Deploys: cw-vpc + cw-instance-profile + 2x EC2 (monitoring=true),
# CloudWatch Agent config via SSM Parameter Store, CloudWatch log group,
# side-by-side dashboard (built-in 1-min vs Agent OS-level metrics),
# memory alarm, and SNS notifications.
# Demonstrates the difference between EC2 detailed monitoring (1-min
# built-in metrics) and CloudWatch Agent (OS-level: memory, disk, etc.).
# -----------------------------------------------------------------------------

locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  cw_agent_config_param_name = "AmazonCloudWatch-${var.project_name}"
  cw_namespace               = "${var.project_name}/OS"
  cw_log_group_name          = "/aws/cw-agent/${var.project_name}"
}

# --- Data Sources ---

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# --- VPC (shared module) ---

module "cw_vpc" {
  source = "../../../../shared/modules/cw-vpc"

  project_name       = var.project_name
  vpc_cidr           = var.vpc_cidr
  public_subnet_cidr = var.public_subnet_cidr

  common_tags = local.common_tags
}

# --- IAM Policy (CloudWatch Logs + SSM parameter read) ---

resource "aws_iam_policy" "cw_agent_extra" {
  name        = "${var.project_name}-cw-agent-extra"
  description = "Allow CW Agent to write logs and read SSM parameter"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogsWrite"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:log-group:${local.cw_log_group_name}:*"
      },
      {
        Sid    = "SSMParameterRead"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
        ]
        Resource = "arn:aws:ssm:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:parameter/${local.cw_agent_config_param_name}"
      },
      {
        Sid    = "EC2DescribeForCWAgent"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeTags",
        ]
        Resource = "*"
      },
    ]
  })

  tags = local.common_tags
}

# --- Instance Profile (shared module) ---

module "cw_instance_profile" {
  source = "../../../../shared/modules/cw-instance-profile"

  project_name = var.project_name
  additional_policy_arns = [
    aws_iam_policy.cw_agent_extra.arn,
  ]
  common_tags = local.common_tags
}

# --- CloudWatch Agent Config via SSM Parameter Store ---

resource "aws_ssm_parameter" "cw_agent_config" {
  name = local.cw_agent_config_param_name
  type = "String"
  tier = "Standard"
  value = templatefile("${path.module}/cw_agent_config.json.tftpl", {
    collection_interval = var.cw_agent_collection_interval
    namespace           = local.cw_namespace
    log_group_name      = local.cw_log_group_name
  })

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-cw-agent-config"
  })
}

# --- CloudWatch Log Group ---

resource "aws_cloudwatch_log_group" "agent_logs" {
  name              = local.cw_log_group_name
  retention_in_days = var.cloudwatch_log_retention_days

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-agent-logs"
  })
}

# --- EC2 Instances (detailed monitoring enabled) ---

resource "aws_instance" "monitored" {
  count = var.instance_count

  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = module.cw_vpc.public_subnet_id
  vpc_security_group_ids      = [module.cw_vpc.instance_sg_id]
  iam_instance_profile        = module.cw_instance_profile.instance_profile_name
  associate_public_ip_address = true
  monitoring                  = true

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    cw_agent_config_param = local.cw_agent_config_param_name
    aws_region            = var.aws_region
  })

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-node-${count.index + 1}"
  })
}

# --- SNS Topic ---

resource "aws_sns_topic" "cw_alerts" {
  name = "${var.project_name}-alerts"

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-alerts"
  })
}

resource "aws_sns_topic_policy" "cloudwatch_publish" {
  arn = aws_sns_topic.cw_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudWatchPublish"
        Effect = "Allow"
        Principal = {
          Service = "cloudwatch.amazonaws.com"
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.cw_alerts.arn
      },
    ]
  })
}

resource "aws_sns_topic_subscription" "email" {
  count = var.notification_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.cw_alerts.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# --- High-CPU Alarm (built-in detailed metric, 1-min Maximum) ---
# Fires when CPUUtilization >= 75% (single period) and triggers BOTH an
# EC2 "stop" action AND the SNS topic. Demonstrates reactive
# auto-remediation using a CloudWatch EC2 action alarm (no Lambda required).
# Reference: AWS docs "Create alarms to stop, terminate, reboot, or recover
# an EC2 instance".

resource "aws_cloudwatch_metric_alarm" "high_cpu_stop" {
  count = var.instance_count

  alarm_name          = "${var.project_name}-high-cpu-stop-${count.index + 1}"
  alarm_description   = "Stop instance ${count.index + 1} when CPUUtilization >= ${var.high_cpu_threshold}% (Maximum, 1-min)."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.high_cpu_evaluation_periods
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = var.high_cpu_threshold
  treat_missing_data  = "missing"

  dimensions = {
    InstanceId = aws_instance.monitored[count.index].id
  }

  alarm_actions = [
    "arn:aws:automate:${var.aws_region}:ec2:stop",
    aws_sns_topic.cw_alerts.arn,
  ]
  ok_actions = [aws_sns_topic.cw_alerts.arn]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-high-cpu-stop-alarm-${count.index + 1}"
  })
}

# --- Memory Alarm (CloudWatch Agent metric) ---

resource "aws_cloudwatch_metric_alarm" "high_memory" {
  count = var.instance_count

  alarm_name          = "${var.project_name}-high-memory-${count.index + 1}"
  alarm_description   = "Alarm when memory usage exceeds 85% on instance ${count.index + 1}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "mem_used_percent"
  namespace           = local.cw_namespace
  period              = 300
  statistic           = "Average"
  threshold           = 85
  treat_missing_data  = "missing"

  dimensions = {
    InstanceId = aws_instance.monitored[count.index].id
  }

  alarm_actions = [aws_sns_topic.cw_alerts.arn]
  ok_actions    = [aws_sns_topic.cw_alerts.arn]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-high-memory-alarm-${count.index + 1}"
  })
}

# --- CloudWatch Dashboard (side-by-side: built-in vs agent) ---

resource "aws_cloudwatch_dashboard" "detailed_vs_agent" {
  dashboard_name = "${var.project_name}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      # Row 1: Built-in EC2 metrics (1-min detailed monitoring)
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Built-in: CPU Utilization (1-min Detailed)"
          view   = "timeSeries"
          region = var.aws_region
          period = 60
          stat   = "Average"
          metrics = [
            for i, inst in aws_instance.monitored : [
              "AWS/EC2", "CPUUtilization",
              "InstanceId", inst.id,
              { label = "Node ${i + 1}" }
            ]
          ]
        }
      },
      # Row 1: CW Agent CPU metrics
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Agent: CPU Usage (User/System/Idle)"
          view   = "timeSeries"
          region = var.aws_region
          period = 60
          stat   = "Average"
          metrics = concat(
            [for i, inst in aws_instance.monitored : [
              local.cw_namespace, "cpu_usage_user",
              "InstanceId", inst.id,
              "cpu", "cpu-total",
              { label = "Node ${i + 1} - User" }
            ]],
            [for i, inst in aws_instance.monitored : [
              local.cw_namespace, "cpu_usage_system",
              "InstanceId", inst.id,
              "cpu", "cpu-total",
              { label = "Node ${i + 1} - System" }
            ]],
          )
        }
      },
      # Row 2: Agent memory + disk
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Agent: Memory Used %"
          view   = "timeSeries"
          region = var.aws_region
          period = 60
          stat   = "Average"
          metrics = [
            for i, inst in aws_instance.monitored : [
              local.cw_namespace, "mem_used_percent",
              "InstanceId", inst.id,
              { label = "Node ${i + 1}" }
            ]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Agent: Disk Used %"
          view   = "timeSeries"
          region = var.aws_region
          period = 60
          stat   = "Average"
          metrics = [
            for i, inst in aws_instance.monitored : [
              local.cw_namespace, "disk_used_percent",
              "InstanceId", inst.id,
              "path", "/",
              "device", "xvda1",
              "fstype", "xfs",
              { label = "Node ${i + 1}" }
            ]
          ]
        }
      },
      # Row 3: Network and alarm status
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "Agent: Network Bytes"
          view   = "timeSeries"
          region = var.aws_region
          period = 60
          stat   = "Sum"
          metrics = concat(
            [for i, inst in aws_instance.monitored : [
              { expression = "SEARCH('{${local.cw_namespace},InstanceId,interface} MetricName=\"net_bytes_sent\" InstanceId=\"${inst.id}\"', 'Sum', 60)", id = "sent${i}", label = "Node ${i + 1} - Sent" }
            ]],
            [for i, inst in aws_instance.monitored : [
              { expression = "SEARCH('{${local.cw_namespace},InstanceId,interface} MetricName=\"net_bytes_recv\" InstanceId=\"${inst.id}\"', 'Sum', 60)", id = "recv${i}", label = "Node ${i + 1} - Recv" }
            ]],
          )
        }
      },
      {
        type   = "alarm"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title = "Alarms: High CPU (→ Stop) & High Memory"
          alarms = concat(
            [for a in aws_cloudwatch_metric_alarm.high_cpu_stop : a.arn],
            [for a in aws_cloudwatch_metric_alarm.high_memory : a.arn],
          )
        }
      },
    ]
  })
}
