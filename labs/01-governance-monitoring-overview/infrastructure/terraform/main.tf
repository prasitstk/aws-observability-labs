# -----------------------------------------------------------------------------
# Lab 01: Governance Monitoring Overview
# Deploys: cw-vpc (2 AZ) + cw-instance-profile + launch template + ASG
# (min 1, max 2, desired 1), CloudWatch CPU alarms (scale out / scale in),
# simple scaling policies, two SNS topics (trigger + email), Lambda function
# that queries CloudTrail for RunInstances events, CloudTrail trail + S3,
# and a CloudWatch dashboard.
# Demonstrates how AWS management and governance services integrate:
# CloudWatch alarms drive Auto Scaling, SNS triggers Lambda, and Lambda
# enriches notifications with CloudTrail API activity data.
# -----------------------------------------------------------------------------

locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  lambda_function_name = "${var.project_name}-event-processor"
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

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/../../src/event_processor.py"
  output_path = "${path.module}/../../src/event_processor.zip"
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

# --- Instance Profile (shared module) ---

module "cw_instance_profile" {
  source = "../../../../shared/modules/cw-instance-profile"

  project_name = var.project_name
  common_tags  = local.common_tags
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

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {}))

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

# --- Simple Scaling Policies ---

resource "aws_autoscaling_policy" "scale_out" {
  name                   = "${var.project_name}-scale-out"
  autoscaling_group_name = aws_autoscaling_group.main.name
  policy_type            = "SimpleScaling"
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = 1
  cooldown               = 60
}

resource "aws_autoscaling_policy" "scale_in" {
  name                   = "${var.project_name}-scale-in"
  autoscaling_group_name = aws_autoscaling_group.main.name
  policy_type            = "SimpleScaling"
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = -1
  cooldown               = 60
}

# --- CloudWatch Alarms (CPU utilization) ---

resource "aws_cloudwatch_metric_alarm" "scale_out" {
  alarm_name          = "${var.project_name}-scale-out"
  alarm_description   = "Scale out when ASG CPU utilization >= ${var.cpu_alarm_threshold}%"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = var.cpu_alarm_threshold
  treat_missing_data  = "missing"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.main.name
  }

  alarm_actions = [
    aws_autoscaling_policy.scale_out.arn,
    aws_sns_topic.trigger.arn,
  ]
  ok_actions = [aws_sns_topic.trigger.arn]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-scale-out-alarm"
  })
}

resource "aws_cloudwatch_metric_alarm" "scale_in" {
  alarm_name          = "${var.project_name}-scale-in"
  alarm_description   = "Scale in when ASG CPU utilization < ${var.cpu_alarm_threshold}%"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = var.cpu_alarm_threshold
  treat_missing_data  = "missing"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.main.name
  }

  alarm_actions = [aws_autoscaling_policy.scale_in.arn]
  ok_actions    = [aws_sns_topic.trigger.arn]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-scale-in-alarm"
  })
}

# --- SNS Topics (two-topic pattern) ---

resource "aws_sns_topic" "trigger" {
  name = "${var.project_name}-trigger"

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-trigger-topic"
  })
}

resource "aws_sns_topic_policy" "cloudwatch_publish" {
  arn = aws_sns_topic.trigger.arn

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
        Resource = aws_sns_topic.trigger.arn
      },
    ]
  })
}

resource "aws_sns_topic" "email" {
  name = "${var.project_name}-email"

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-email-topic"
  })
}

resource "aws_sns_topic_subscription" "email" {
  count = var.notification_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.email.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# --- SNS → Lambda subscription ---

resource "aws_sns_topic_subscription" "lambda" {
  topic_arn = aws_sns_topic.trigger.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.event_processor.arn
}

# --- CloudTrail (S3-only) ---

resource "aws_s3_bucket" "cloudtrail" {
  bucket = var.cloudtrail_bucket_name

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-cloudtrail-bucket"
  })
}

resource "aws_s3_bucket_versioning" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.cloudtrail.arn
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      },
    ]
  })
}

resource "aws_cloudtrail" "main" {
  name                       = "${var.project_name}-trail"
  s3_bucket_name             = aws_s3_bucket.cloudtrail.id
  is_multi_region_trail      = false
  enable_log_file_validation = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-trail"
  })

  depends_on = [aws_s3_bucket_policy.cloudtrail]
}

# --- Lambda Function ---

resource "aws_iam_role" "lambda_exec" {
  name = "${var.project_name}-lambda-exec"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      },
    ]
  })

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-lambda-exec-role"
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_permissions" {
  name = "${var.project_name}-lambda-permissions"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "CloudTrailLookup"
        Effect   = "Allow"
        Action   = ["cloudtrail:LookupEvents"]
        Resource = "*"
      },
      {
        Sid      = "SNSPublish"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.email.arn
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.lambda_function_name}"
  retention_in_days = var.lambda_log_retention_days

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-lambda-logs"
  })
}

resource "aws_lambda_function" "event_processor" {
  function_name    = local.lambda_function_name
  role             = aws_iam_role.lambda_exec.arn
  handler          = "event_processor.handler"
  runtime          = "python3.12"
  timeout          = var.lambda_timeout
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  environment {
    variables = {
      EMAIL_TOPIC_ARN  = aws_sns_topic.email.arn
      LOOKBACK_MINUTES = tostring(var.lookback_minutes)
      SETTLE_SECONDS   = "130"
    }
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-event-processor"
  })

  depends_on = [aws_cloudwatch_log_group.lambda]
}

resource "aws_lambda_permission" "sns_invoke" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.event_processor.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.trigger.arn
}

# --- CloudWatch Dashboard ---

resource "aws_cloudwatch_dashboard" "governance" {
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
      # Row 1: CPU Utilization
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
              { label = "Alarm Threshold (${var.cpu_alarm_threshold}%)", value = var.cpu_alarm_threshold, color = "#d62728" },
            ]
          }
        }
      },
      # Row 2: Lambda invocations and errors
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Lambda Event Processor"
          view   = "timeSeries"
          region = var.aws_region
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", local.lambda_function_name, { label = "Invocations", color = "#2ca02c" }],
            ["AWS/Lambda", "Errors", "FunctionName", local.lambda_function_name, { label = "Errors", color = "#d62728" }],
            ["AWS/Lambda", "Duration", "FunctionName", local.lambda_function_name, { label = "Duration (ms)", stat = "Average", yAxis = "right" }],
          ]
        }
      },
      # Row 2: Alarm status
      {
        type   = "alarm"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title = "Scaling Alarm Status"
          alarms = [
            aws_cloudwatch_metric_alarm.scale_out.arn,
            aws_cloudwatch_metric_alarm.scale_in.arn,
          ]
        }
      },
    ]
  })
}
