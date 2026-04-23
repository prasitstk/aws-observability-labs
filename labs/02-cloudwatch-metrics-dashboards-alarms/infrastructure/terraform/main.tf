# -----------------------------------------------------------------------------
# Lab 02: CloudWatch Metrics, Dashboards & Alarms — Multi-Service Monitoring
# Deploys: cw-vpc + cw-instance-profile + 2x EC2, DynamoDB table, S3 bucket,
# multi-widget dashboard (9 widgets), 5 alarm types (high CPU, low CPU stop,
# anomaly detection, DynamoDB write spike, S3 deletion), composite alarm, and
# SNS notifications.
# Demonstrates CloudWatch fundamentals across multiple AWS services: EC2 (basic
# 5-min metrics), DynamoDB (on-demand capacity), and S3 (request metrics).
# Financial domain theme: EC2 = trade execution engine, DynamoDB = trade
# records, S3 = settlement reports.
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

data "aws_caller_identity" "current" {}

# --- VPC (shared module) ---

module "cw_vpc" {
  source = "../../../../shared/modules/cw-vpc"

  project_name       = var.project_name
  vpc_cidr           = var.vpc_cidr
  public_subnet_cidr = var.public_subnet_cidr

  common_tags = local.common_tags
}

# --- Instance Profile (shared module) ---

module "cw_instance_profile" {
  source = "../../../../shared/modules/cw-instance-profile"

  project_name = var.project_name
  common_tags  = local.common_tags
}

# --- EC2 Instances (basic monitoring — 5-min resolution) ---

resource "aws_instance" "web" {
  count = var.instance_count

  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = module.cw_vpc.public_subnet_id
  vpc_security_group_ids      = [module.cw_vpc.instance_sg_id]
  iam_instance_profile        = module.cw_instance_profile.instance_profile_name
  associate_public_ip_address = true

  user_data = <<-EOF
  #!/bin/bash
  dnf install -y stress-ng
  EOF

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-web-${count.index + 1}"
  })
}

# --- DynamoDB Table (trade execution records) ---

resource "aws_dynamodb_table" "trade_executions" {
  name         = "${var.project_name}-trade-executions"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "trade_id"
  range_key    = "execution_timestamp"

  attribute {
    name = "trade_id"
    type = "S"
  }

  attribute {
    name = "execution_timestamp"
    type = "S"
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-trade-executions"
  })
}

# --- S3 Bucket (trade settlement reports) ---

resource "aws_s3_bucket" "trade_reports" {
  bucket = var.trade_reports_bucket_name

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-trade-reports"
  })
}

resource "aws_s3_bucket_versioning" "trade_reports" {
  bucket = aws_s3_bucket.trade_reports.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "trade_reports" {
  bucket = aws_s3_bucket.trade_reports.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "trade_reports" {
  bucket = aws_s3_bucket.trade_reports.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# S3 request metrics — required for CloudWatch to report request-level metrics.
# Note: Metrics take 15-30 minutes to appear after creation.
resource "aws_s3_bucket_metric" "trade_reports" {
  bucket = aws_s3_bucket.trade_reports.id
  name   = "EntireBucket"
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

# --- Alarm 1: High CPU (threshold) ---

resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  count = var.instance_count

  alarm_name          = "${var.project_name}-high-cpu-${count.index + 1}"
  alarm_description   = "Alarm when CPU exceeds 80% for 2 consecutive periods on instance ${count.index + 1}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "missing"

  dimensions = {
    InstanceId = aws_instance.web[count.index].id
  }

  alarm_actions = [aws_sns_topic.cw_alerts.arn]
  ok_actions    = [aws_sns_topic.cw_alerts.arn]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-high-cpu-alarm-${count.index + 1}"
  })
}

# --- Alarm 2: Low CPU with EC2 stop action ---

resource "aws_cloudwatch_metric_alarm" "low_cpu_stop" {
  count = var.instance_count

  alarm_name          = "${var.project_name}-low-cpu-stop-${count.index + 1}"
  alarm_description   = "Stop instance when CPU is below 5% for 3 consecutive hours"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 36
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 5
  treat_missing_data  = "missing"

  dimensions = {
    InstanceId = aws_instance.web[count.index].id
  }

  alarm_actions = [
    "arn:aws:automate:${var.aws_region}:ec2:stop",
    aws_sns_topic.cw_alerts.arn,
  ]
  ok_actions = [aws_sns_topic.cw_alerts.arn]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-low-cpu-stop-alarm-${count.index + 1}"
  })
}

# --- Alarm 3: Anomaly detection on CPU ---

resource "aws_cloudwatch_metric_alarm" "cpu_anomaly" {
  count = var.instance_count

  alarm_name          = "${var.project_name}-cpu-anomaly-${count.index + 1}"
  alarm_description   = "Alarm when CPU deviates from expected band on instance ${count.index + 1}"
  comparison_operator = "GreaterThanUpperThreshold"
  evaluation_periods  = 2
  threshold_metric_id = "ad1"
  treat_missing_data  = "missing"

  metric_query {
    id          = "m1"
    return_data = true

    metric {
      metric_name = "CPUUtilization"
      namespace   = "AWS/EC2"
      period      = 300
      stat        = "Average"

      dimensions = {
        InstanceId = aws_instance.web[count.index].id
      }
    }
  }

  metric_query {
    id          = "ad1"
    expression  = "ANOMALY_DETECTION_BAND(m1, 2)"
    label       = "CPU Anomaly Band"
    return_data = true
  }

  alarm_actions = [aws_sns_topic.cw_alerts.arn]
  ok_actions    = [aws_sns_topic.cw_alerts.arn]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-cpu-anomaly-alarm-${count.index + 1}"
  })
}

# --- Alarm 4: DynamoDB high write capacity ---

resource "aws_cloudwatch_metric_alarm" "dynamodb_high_writes" {
  alarm_name          = "${var.project_name}-dynamodb-high-writes"
  alarm_description   = "Alarm when DynamoDB consumed write capacity exceeds threshold"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ConsumedWriteCapacityUnits"
  namespace           = "AWS/DynamoDB"
  period              = 300
  statistic           = "Sum"
  threshold           = var.dynamodb_write_alarm_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    TableName = aws_dynamodb_table.trade_executions.name
  }

  alarm_actions = [aws_sns_topic.cw_alerts.arn]
  ok_actions    = [aws_sns_topic.cw_alerts.arn]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-dynamodb-high-writes-alarm"
  })
}

# --- Alarm 5: S3 delete requests ---

resource "aws_cloudwatch_metric_alarm" "s3_delete_requests" {
  alarm_name          = "${var.project_name}-s3-delete-requests"
  alarm_description   = "Alarm when S3 delete requests detected — settlement reports should be immutable"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "DeleteRequests"
  namespace           = "AWS/S3"
  period              = 86400
  statistic           = "Sum"
  threshold           = var.s3_delete_alarm_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    BucketName = aws_s3_bucket.trade_reports.id
    FilterId   = "EntireBucket"
  }

  alarm_actions = [aws_sns_topic.cw_alerts.arn]
  ok_actions    = [aws_sns_topic.cw_alerts.arn]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-s3-delete-requests-alarm"
  })
}

# --- Composite Alarm (multi-service: EC2 + DynamoDB + S3) ---

resource "aws_cloudwatch_composite_alarm" "critical" {
  alarm_name        = "${var.project_name}-critical-composite"
  alarm_description = "Fires on EC2 CPU anomaly (high CPU AND anomaly), DynamoDB write spike, or S3 deletions"

  alarm_rule = join(" OR ", concat(
    [
      for i in range(var.instance_count) :
      "(ALARM(\"${var.project_name}-high-cpu-${i + 1}\") AND ALARM(\"${var.project_name}-cpu-anomaly-${i + 1}\"))"
    ],
    [
      "ALARM(\"${var.project_name}-dynamodb-high-writes\")",
      "ALARM(\"${var.project_name}-s3-delete-requests\")",
    ],
  ))

  alarm_actions = [aws_sns_topic.cw_alerts.arn]
  ok_actions    = [aws_sns_topic.cw_alerts.arn]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-critical-composite"
  })

  depends_on = [
    aws_cloudwatch_metric_alarm.high_cpu,
    aws_cloudwatch_metric_alarm.cpu_anomaly,
    aws_cloudwatch_metric_alarm.dynamodb_high_writes,
    aws_cloudwatch_metric_alarm.s3_delete_requests,
  ]
}

# --- CloudWatch Dashboard ---

resource "aws_cloudwatch_dashboard" "metrics" {
  dashboard_name = "${var.project_name}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      # Row 1: CPU Utilization per instance
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "CPU Utilization per Instance"
          view   = "timeSeries"
          region = var.aws_region
          period = 300
          stat   = "Average"
          metrics = [
            for i, inst in aws_instance.web : [
              "AWS/EC2", "CPUUtilization",
              "InstanceId", inst.id,
              { label = "Web ${i + 1}" }
            ]
          ]
        }
      },
      # Row 1: Network traffic
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Network I/O per Instance"
          view   = "timeSeries"
          region = var.aws_region
          period = 300
          stat   = "Sum"
          metrics = concat(
            [for i, inst in aws_instance.web : [
              "AWS/EC2", "NetworkIn",
              "InstanceId", inst.id,
              { label = "Web ${i + 1} - In" }
            ]],
            [for i, inst in aws_instance.web : [
              "AWS/EC2", "NetworkOut",
              "InstanceId", inst.id,
              { label = "Web ${i + 1} - Out" }
            ]],
          )
        }
      },
      # Row 2: Disk I/O
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Disk Read/Write Operations"
          view   = "timeSeries"
          region = var.aws_region
          period = 300
          stat   = "Sum"
          metrics = concat(
            [for i, inst in aws_instance.web : [
              "AWS/EC2", "DiskReadOps",
              "InstanceId", inst.id,
              { label = "Web ${i + 1} - Read" }
            ]],
            [for i, inst in aws_instance.web : [
              "AWS/EC2", "DiskWriteOps",
              "InstanceId", inst.id,
              { label = "Web ${i + 1} - Write" }
            ]],
          )
        }
      },
      # Row 2: Status checks
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Status Check Failures"
          view   = "timeSeries"
          region = var.aws_region
          period = 300
          stat   = "Maximum"
          metrics = concat(
            [for i, inst in aws_instance.web : [
              "AWS/EC2", "StatusCheckFailed_Instance",
              "InstanceId", inst.id,
              { label = "Web ${i + 1} - Instance" }
            ]],
            [for i, inst in aws_instance.web : [
              "AWS/EC2", "StatusCheckFailed_System",
              "InstanceId", inst.id,
              { label = "Web ${i + 1} - System" }
            ]],
          )
        }
      },
      # Row 3: DynamoDB consumed capacity
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "DynamoDB Consumed Capacity (Trade Executions)"
          view   = "timeSeries"
          region = var.aws_region
          period = 300
          metrics = [
            [
              "AWS/DynamoDB", "ConsumedReadCapacityUnits",
              "TableName", aws_dynamodb_table.trade_executions.name,
              { stat = "Sum", label = "Read Capacity" }
            ],
            [
              "AWS/DynamoDB", "ConsumedWriteCapacityUnits",
              "TableName", aws_dynamodb_table.trade_executions.name,
              { stat = "Sum", label = "Write Capacity" }
            ],
          ]
        }
      },
      # Row 3: S3 request metrics
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "S3 Request Metrics (Trade Reports)"
          view   = "timeSeries"
          region = var.aws_region
          period = 86400
          stat   = "Sum"
          metrics = [
            [
              "AWS/S3", "GetRequests",
              "BucketName", aws_s3_bucket.trade_reports.id,
              "FilterId", "EntireBucket",
              { label = "GET Requests" }
            ],
            [
              "AWS/S3", "PutRequests",
              "BucketName", aws_s3_bucket.trade_reports.id,
              "FilterId", "EntireBucket",
              { label = "PUT Requests" }
            ],
            [
              "AWS/S3", "DeleteRequests",
              "BucketName", aws_s3_bucket.trade_reports.id,
              "FilterId", "EntireBucket",
              { label = "DELETE Requests" }
            ],
          ]
        }
      },
      # Row 4: Alarm status (all services)
      {
        type   = "alarm"
        x      = 0
        y      = 18
        width  = 24
        height = 3
        properties = {
          title = "Alarm Status"
          alarms = concat(
            [for a in aws_cloudwatch_metric_alarm.high_cpu : a.arn],
            [for a in aws_cloudwatch_metric_alarm.cpu_anomaly : a.arn],
            [aws_cloudwatch_metric_alarm.dynamodb_high_writes.arn],
            [aws_cloudwatch_metric_alarm.s3_delete_requests.arn],
            [aws_cloudwatch_composite_alarm.critical.arn],
          )
        }
      },
    ]
  })
}
