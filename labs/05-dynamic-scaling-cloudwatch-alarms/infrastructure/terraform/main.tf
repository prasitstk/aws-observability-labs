# -----------------------------------------------------------------------------
# Lab 05: Dynamic Scaling with CloudWatch Alarms
# Deploys: cw-vpc (2 AZ) + cw-instance-profile + launch template + ASG,
# all three dynamic scaling policy types (TargetTracking, StepScaling,
# SimpleScaling), CloudWatch alarms on two trigger sources (EC2 CPU
# utilization + SQS queue depth), an SQS financial-orders queue, a
# systemd-managed worker on each instance that drains the queue,
# a CloudWatch dashboard, SNS notifications, and ASG lifecycle events.
# -----------------------------------------------------------------------------

locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
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

# --- VPC (shared module — 2 AZ for ASG) ---

module "cw_vpc" {
  source = "../../../../shared/modules/cw-vpc"

  project_name                = var.project_name
  vpc_cidr                    = var.vpc_cidr
  public_subnet_cidr          = var.public_subnet_cidr
  public_subnet_cidr_2        = var.public_subnet_cidr_2
  enable_second_public_subnet = true

  common_tags = local.common_tags
}

# --- Security Group Rule (HTTP ingress) ---

resource "aws_security_group_rule" "http_ingress" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Allow inbound HTTP for health checks"
  security_group_id = module.cw_vpc.instance_sg_id
}

# --- SQS Queue (financial orders) ---

resource "aws_sqs_queue" "orders" {
  name                       = "${var.project_name}-${var.queue_name_suffix}"
  visibility_timeout_seconds = 30
  message_retention_seconds  = 345600

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.queue_name_suffix}"
  })
}

# --- IAM policy for the in-instance worker ---

resource "aws_iam_policy" "sqs_worker" {
  name        = "${var.project_name}-sqs-worker-policy"
  description = "Allows ASG instances to consume messages from the orders queue."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:ChangeMessageVisibility",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
        ]
        Resource = aws_sqs_queue.orders.arn
      },
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-sqs-worker-policy"
  })
}

# --- Instance Profile (shared module) ---

module "cw_instance_profile" {
  source = "../../../../shared/modules/cw-instance-profile"

  project_name           = var.project_name
  additional_policy_arns = [aws_iam_policy.sqs_worker.arn]
  common_tags            = local.common_tags
}

# --- Launch Template ---

resource "aws_launch_template" "asg" {
  name_prefix   = "${var.project_name}-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.instance_type

  iam_instance_profile {
    name = module.cw_instance_profile.instance_profile_name
  }

  vpc_security_group_ids = [module.cw_vpc.instance_sg_id]

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    queue_url                    = aws_sqs_queue.orders.url
    aws_region                   = var.aws_region
    worker_process_delay_seconds = var.worker_process_delay_seconds
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, {
      Name = "${var.project_name}-asg-instance"
    })
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-launch-template"
  })
}

# --- Auto Scaling Group ---

resource "aws_autoscaling_group" "main" {
  name                = "${var.project_name}-asg"
  min_size            = var.asg_min_size
  max_size            = var.asg_max_size
  desired_capacity    = var.asg_desired_capacity
  vpc_zone_identifier = [module.cw_vpc.public_subnet_id, module.cw_vpc.public_subnet_id_2]

  launch_template {
    id      = aws_launch_template.asg.id
    version = "$Latest"
  }

  enabled_metrics = [
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupPendingInstances",
    "GroupTerminatingInstances",
    "GroupTotalInstances",
    "GroupMinSize",
    "GroupMaxSize",
  ]

  tag {
    key                 = "Project"
    value               = var.project_name
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = var.environment
    propagate_at_launch = true
  }

  tag {
    key                 = "ManagedBy"
    value               = "terraform"
    propagate_at_launch = true
  }
}

# --- Target Tracking Scaling Policy (CPU) ---

resource "aws_autoscaling_policy" "target_tracking_cpu" {
  name                   = "${var.project_name}-target-tracking-cpu"
  autoscaling_group_name = aws_autoscaling_group.main.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = var.target_cpu_value
  }
}

# --- Step Scaling Policy (scale out on high CPU) ---

resource "aws_autoscaling_policy" "step_scale_out" {
  name                   = "${var.project_name}-step-scale-out"
  autoscaling_group_name = aws_autoscaling_group.main.name
  policy_type            = "StepScaling"
  adjustment_type        = "ChangeInCapacity"

  step_adjustment {
    scaling_adjustment          = 1
    metric_interval_lower_bound = 0
    metric_interval_upper_bound = 20
  }

  step_adjustment {
    scaling_adjustment          = 2
    metric_interval_lower_bound = 20
  }
}

# --- Step Scaling Policy (scale in on low CPU) ---

resource "aws_autoscaling_policy" "step_scale_in" {
  name                   = "${var.project_name}-step-scale-in"
  autoscaling_group_name = aws_autoscaling_group.main.name
  policy_type            = "StepScaling"
  adjustment_type        = "ChangeInCapacity"

  step_adjustment {
    scaling_adjustment          = -1
    metric_interval_upper_bound = 0
  }
}

# --- CloudWatch Alarms for Step Scaling ---

resource "aws_cloudwatch_metric_alarm" "step_high_cpu" {
  alarm_name          = "${var.project_name}-step-high-cpu"
  alarm_description   = "Scale out when ASG average CPU > 70%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 70
  treat_missing_data  = "missing"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.main.name
  }

  alarm_actions = [
    aws_autoscaling_policy.step_scale_out.arn,
    aws_sns_topic.scaling_notifications.arn,
  ]
  ok_actions = [aws_sns_topic.scaling_notifications.arn]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-step-high-cpu-alarm"
  })
}

resource "aws_cloudwatch_metric_alarm" "step_low_cpu" {
  alarm_name          = "${var.project_name}-step-low-cpu"
  alarm_description   = "Scale in when ASG average CPU < 25%"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 25
  treat_missing_data  = "missing"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.main.name
  }

  alarm_actions = [
    aws_autoscaling_policy.step_scale_in.arn,
    aws_sns_topic.scaling_notifications.arn,
  ]
  ok_actions = [aws_sns_topic.scaling_notifications.arn]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-step-low-cpu-alarm"
  })
}

# --- Simple Scaling Policies (driven by SQS queue depth) ---

resource "aws_autoscaling_policy" "simple_scale_out" {
  name                   = "${var.project_name}-simple-scale-out"
  autoscaling_group_name = aws_autoscaling_group.main.name
  policy_type            = "SimpleScaling"
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = 1
  cooldown               = 60
}

resource "aws_autoscaling_policy" "simple_scale_in" {
  name                   = "${var.project_name}-simple-scale-in"
  autoscaling_group_name = aws_autoscaling_group.main.name
  policy_type            = "SimpleScaling"
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = -1
  cooldown               = 120
}

# --- CloudWatch Alarms on SQS queue depth ---

resource "aws_cloudwatch_metric_alarm" "queue_high" {
  alarm_name          = "${var.project_name}-queue-high"
  alarm_description   = "Scale out when orders queue depth exceeds ${var.queue_scale_out_threshold} messages."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Average"
  threshold           = var.queue_scale_out_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.orders.name
  }

  alarm_actions = [
    aws_autoscaling_policy.simple_scale_out.arn,
    aws_sns_topic.scaling_notifications.arn,
  ]
  ok_actions = [aws_sns_topic.scaling_notifications.arn]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-queue-high-alarm"
  })
}

resource "aws_cloudwatch_metric_alarm" "queue_low" {
  alarm_name          = "${var.project_name}-queue-low"
  alarm_description   = "Scale in when orders queue depth drops below ${var.queue_scale_in_threshold} messages."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Average"
  threshold           = var.queue_scale_in_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.orders.name
  }

  alarm_actions = [
    aws_autoscaling_policy.simple_scale_in.arn,
    aws_sns_topic.scaling_notifications.arn,
  ]
  ok_actions = [aws_sns_topic.scaling_notifications.arn]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-queue-low-alarm"
  })
}

# --- SNS Topic ---

resource "aws_sns_topic" "scaling_notifications" {
  name = "${var.project_name}-scaling-notifications"

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-scaling-notifications"
  })
}

resource "aws_sns_topic_policy" "cloudwatch_publish" {
  arn = aws_sns_topic.scaling_notifications.arn

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
        Resource = aws_sns_topic.scaling_notifications.arn
      },
    ]
  })
}

resource "aws_sns_topic_subscription" "email" {
  count = var.notification_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.scaling_notifications.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# --- ASG Lifecycle Notifications ---

resource "aws_autoscaling_notification" "asg_events" {
  group_names = [aws_autoscaling_group.main.name]
  topic_arn   = aws_sns_topic.scaling_notifications.arn

  notifications = [
    "autoscaling:EC2_INSTANCE_LAUNCH",
    "autoscaling:EC2_INSTANCE_TERMINATE",
    "autoscaling:EC2_INSTANCE_LAUNCH_ERROR",
    "autoscaling:EC2_INSTANCE_TERMINATE_ERROR",
  ]
}

# --- CloudWatch Dashboard ---

resource "aws_cloudwatch_dashboard" "scaling" {
  dashboard_name = "${var.project_name}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      # Row 1: ASG capacity
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "ASG Capacity"
          view   = "timeSeries"
          region = var.aws_region
          period = 60
          stat   = "Average"
          metrics = [
            ["AWS/AutoScaling", "GroupDesiredCapacity", "AutoScalingGroupName", aws_autoscaling_group.main.name, { label = "Desired" }],
            ["AWS/AutoScaling", "GroupInServiceInstances", "AutoScalingGroupName", aws_autoscaling_group.main.name, { label = "In Service" }],
            ["AWS/AutoScaling", "GroupTotalInstances", "AutoScalingGroupName", aws_autoscaling_group.main.name, { label = "Total" }],
          ]
        }
      },
      # Row 1: CPU Utilization (ASG aggregate)
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "ASG Average CPU Utilization"
          view   = "timeSeries"
          region = var.aws_region
          period = 60
          stat   = "Average"
          yAxis = {
            left = { min = 0, max = 100 }
          }
          metrics = [
            ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", aws_autoscaling_group.main.name, { label = "Avg CPU" }],
          ]
          annotations = {
            horizontal = [
              { label = "Scale Out (70%)", value = 70, color = "#d62728" },
              { label = "Target (${var.target_cpu_value}%)", value = var.target_cpu_value, color = "#ff7f0e" },
              { label = "Scale In (25%)", value = 25, color = "#2ca02c" },
            ]
          }
        }
      },
      # Row 2: Network traffic
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "ASG Network I/O"
          view   = "timeSeries"
          region = var.aws_region
          period = 300
          stat   = "Sum"
          metrics = [
            ["AWS/EC2", "NetworkIn", "AutoScalingGroupName", aws_autoscaling_group.main.name, { label = "Network In" }],
            ["AWS/EC2", "NetworkOut", "AutoScalingGroupName", aws_autoscaling_group.main.name, { label = "Network Out" }],
          ]
        }
      },
      # Row 2: Scaling summary (single value)
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Current Fleet Status"
          view   = "singleValue"
          region = var.aws_region
          period = 60
          stat   = "Average"
          metrics = [
            ["AWS/AutoScaling", "GroupDesiredCapacity", "AutoScalingGroupName", aws_autoscaling_group.main.name, { label = "Desired" }],
            ["AWS/AutoScaling", "GroupInServiceInstances", "AutoScalingGroupName", aws_autoscaling_group.main.name, { label = "In Service" }],
            ["AWS/AutoScaling", "GroupMinSize", "AutoScalingGroupName", aws_autoscaling_group.main.name, { label = "Min" }],
            ["AWS/AutoScaling", "GroupMaxSize", "AutoScalingGroupName", aws_autoscaling_group.main.name, { label = "Max" }],
          ]
        }
      },
      # Row 3: Queue depth with scale-out / scale-in annotations
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "Orders Queue Depth (ApproximateNumberOfMessagesVisible)"
          view   = "timeSeries"
          region = var.aws_region
          period = 60
          stat   = "Average"
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.orders.name, { label = "Depth" }],
          ]
          annotations = {
            horizontal = [
              { label = "Scale Out (>${var.queue_scale_out_threshold})", value = var.queue_scale_out_threshold, color = "#d62728" },
              { label = "Scale In (<${var.queue_scale_in_threshold})", value = var.queue_scale_in_threshold, color = "#2ca02c" },
            ]
          }
        }
      },
      # Row 3: SQS throughput
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "SQS Throughput (per 1 min)"
          view   = "timeSeries"
          region = var.aws_region
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/SQS", "NumberOfMessagesSent", "QueueName", aws_sqs_queue.orders.name, { label = "Sent" }],
            ["AWS/SQS", "NumberOfMessagesReceived", "QueueName", aws_sqs_queue.orders.name, { label = "Received" }],
            ["AWS/SQS", "NumberOfMessagesDeleted", "QueueName", aws_sqs_queue.orders.name, { label = "Deleted" }],
          ]
        }
      },
      # Row 4: Alarm status (CPU + SQS)
      {
        type   = "alarm"
        x      = 0
        y      = 18
        width  = 24
        height = 3
        properties = {
          title = "Scaling Alarm Status (CPU + Queue)"
          alarms = [
            aws_cloudwatch_metric_alarm.step_high_cpu.arn,
            aws_cloudwatch_metric_alarm.step_low_cpu.arn,
            aws_cloudwatch_metric_alarm.queue_high.arn,
            aws_cloudwatch_metric_alarm.queue_low.arn,
          ]
        }
      },
    ]
  })
}
