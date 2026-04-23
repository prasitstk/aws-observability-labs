# -----------------------------------------------------------------------------
# Lab 04: Custom Metrics + Structured Logging (EMF + PutMetricData)
# Deploys: cw-vpc + cw-instance-profile (+ PutMetricData/Logs policy) +
# 1x EC2 running a Flask Orders API, CloudWatch Agent config via SSM
# Parameter Store, two CloudWatch log groups (EMF + SDK), a p90 latency
# alarm, SNS topic, and a mixed dashboard that blends CloudWatch Metrics
# Insights, Logs Insights, and an alarm-status widget.
#
# Custom metric flows demonstrated:
#   1. EMF — Flask writes CloudWatch-native JSON to a log file; the
#      CloudWatch Agent ships it to /cw-labs/.../orders-emf; CloudWatch
#      auto-extracts metrics into namespace CWLabs/OrderServiceEMF.
#   2. PutMetricData SDK — Flask calls cloudwatch.put_metric_data() when
#      the request payload sets useSDK=true; metrics land in namespace
#      CWLabs/OrderServiceSDK and an audit line lands in the SDK log
#      group.
#
# Reference docs:
#   - EMF spec: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch_Embedded_Metric_Format_Specification.html
#   - CW Agent config: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-Agent-Configuration-File-Details.html
#   - PutMetricData: https://docs.aws.amazon.com/AmazonCloudWatch/latest/APIReference/API_PutMetricData.html
# -----------------------------------------------------------------------------

locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  emf_namespace              = "CWLabs/OrderServiceEMF"
  sdk_namespace              = "CWLabs/OrderServiceSDK"
  emf_log_group_name         = "/cw-labs/${var.project_name}/orders-emf"
  sdk_log_group_name         = "/cw-labs/${var.project_name}/orders-sdk"
  emf_log_path               = "/home/ec2-user/logs-emf-orders.log"
  sdk_log_path               = "/home/ec2-user/logs-sdk-orders.log"
  cw_agent_config_param_name = "AmazonCloudWatch-${var.project_name}"
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

# Lab-specific ingress: open port 5000 for the Flask API so the
# load generator can reach it. The shared SG only defines egress;
# we layer this rule on without changing the shared module.
resource "aws_vpc_security_group_ingress_rule" "orders_api" {
  security_group_id = module.cw_vpc.instance_sg_id
  description       = "Orders API (Flask) from load generator"
  ip_protocol       = "tcp"
  from_port         = 5000
  to_port           = 5000
  cidr_ipv4         = var.orders_api_allowed_cidr

  tags = local.common_tags
}

# --- IAM Policy (PutMetricData + Logs + SSM param read + EC2 describe) ---

resource "aws_iam_policy" "custom_metrics" {
  name        = "${var.project_name}-custom-metrics"
  description = "Allow EC2 to publish custom CloudWatch metrics, write EMF/SDK logs, and read the CW Agent config parameter"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchPutMetricData"
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData",
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchLogsWrite"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
        ]
        Resource = [
          "arn:aws:logs:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:log-group:${local.emf_log_group_name}:*",
          "arn:aws:logs:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:log-group:${local.sdk_log_group_name}:*",
        ]
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
    aws_iam_policy.custom_metrics.arn,
  ]
  common_tags = local.common_tags
}

# --- CloudWatch Log Groups (EMF + SDK) ---

resource "aws_cloudwatch_log_group" "orders_emf" {
  name              = local.emf_log_group_name
  retention_in_days = var.cloudwatch_log_retention_days

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-orders-emf"
  })
}

resource "aws_cloudwatch_log_group" "orders_sdk" {
  name              = local.sdk_log_group_name
  retention_in_days = var.cloudwatch_log_retention_days

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-orders-sdk"
  })
}

# --- CloudWatch Agent Config via SSM Parameter Store ---

resource "aws_ssm_parameter" "cw_agent_config" {
  name = local.cw_agent_config_param_name
  type = "String"
  tier = "Standard"
  value = templatefile("${path.module}/cw_agent_config.json.tftpl", {
    emf_log_path  = local.emf_log_path
    sdk_log_path  = local.sdk_log_path
    emf_log_group = local.emf_log_group_name
    sdk_log_group = local.sdk_log_group_name
  })

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-cw-agent-config"
  })
}

# --- EC2 Instance (Flask Orders API) ---

resource "aws_instance" "orders_api" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = module.cw_vpc.public_subnet_id
  vpc_security_group_ids      = [module.cw_vpc.instance_sg_id]
  iam_instance_profile        = module.cw_instance_profile.instance_profile_name
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    aws_region            = var.aws_region
    emf_namespace         = local.emf_namespace
    sdk_namespace         = local.sdk_namespace
    emf_log_path          = local.emf_log_path
    sdk_log_path          = local.sdk_log_path
    cw_agent_config_param = local.cw_agent_config_param_name
    app_code              = file("${path.module}/../../src/app.py")
  })

  # Re-launch the instance when the app or agent config changes so the
  # new user_data takes effect.
  user_data_replace_on_change = true

  depends_on = [
    aws_ssm_parameter.cw_agent_config,
    aws_cloudwatch_log_group.orders_emf,
    aws_cloudwatch_log_group.orders_sdk,
  ]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-orders-api"
  })
}

# --- SNS Topic ---

resource "aws_sns_topic" "orders_alerts" {
  name = "${var.project_name}-orders-alerts"

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-orders-alerts"
  })
}

resource "aws_sns_topic_policy" "cloudwatch_publish" {
  arn = aws_sns_topic.orders_alerts.arn

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
        Resource = aws_sns_topic.orders_alerts.arn
      },
    ]
  })
}

resource "aws_sns_topic_subscription" "email" {
  count = var.notification_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.orders_alerts.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# --- Alarm: request-latency-alarm (p90 RequestLatency > threshold) ---
#
# EMF publishes RequestLatency in milliseconds — we alarm when the p90
# over two consecutive 1-min periods exceeds the threshold. This is
# the Educative lab's "p90 > 2s" concept, kept explicit in ms to match
# the app code.

resource "aws_cloudwatch_metric_alarm" "request_latency" {
  alarm_name          = "request-latency-alarm"
  alarm_description   = "p90 RequestLatency exceeds ${var.request_latency_threshold_ms} ms (EMF)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "RequestLatency"
  namespace           = local.emf_namespace
  period              = 60
  extended_statistic  = "p90"
  threshold           = var.request_latency_threshold_ms
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.orders_alerts.arn]
  ok_actions    = [aws_sns_topic.orders_alerts.arn]

  tags = merge(local.common_tags, {
    Name = "request-latency-alarm"
  })
}

# --- Contributor Insights: top orderType by failure count (EMF log group) ---
#
# The EMF log group emits one structured JSON event per order with keys
# orderType, region, symbol, RequestLatency, SuccessCount, FailureCount.
# This rule surfaces which orderType contributes the most failures over
# the selected time range — a natural drill-down from the p90 alarm.

resource "aws_cloudwatch_contributor_insight_rule" "orders_error_contributors" {
  rule_name  = "${var.project_name}-orders-error-contributors"
  rule_state = "ENABLED"

  rule_definition = jsonencode({
    Schema = {
      Name    = "CloudWatchLogRule"
      Version = 1
    }
    AggregateOn = "Count"
    Contribution = {
      Keys = ["$.orderType"]
      Filters = [
        {
          Match       = "$.FailureCount"
          GreaterThan = 0
        },
      ]
    }
    LogFormat     = "JSON"
    LogGroupNames = [aws_cloudwatch_log_group.orders_emf.name]
  })

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-orders-error-contributors"
  })
}

# --- CloudWatch Dashboard ---

resource "aws_cloudwatch_dashboard" "orders" {
  dashboard_name = "${var.project_name}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      # Row 1 (left): Metrics Insights — avg RequestLatency by region (EMF)
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 16
        height = 6
        properties = {
          title  = "Avg RequestLatency by region (Metrics Insights, EMF)"
          view   = "timeSeries"
          region = var.aws_region
          period = 60
          stat   = "Average"
          metrics = [
            [{
              expression = "SELECT AVG(RequestLatency) FROM SCHEMA(\"${local.emf_namespace}\", orderType, region) GROUP BY region"
              label      = "avg(RequestLatency) by region"
              id         = "q1"
            }]
          ]
        }
      },
      # Row 1 (right): Failure count KPI number
      {
        type   = "metric"
        x      = 16
        y      = 0
        width  = 8
        height = 6
        properties = {
          title  = "FailureCount (last 1h)"
          view   = "singleValue"
          region = var.aws_region
          period = 3600
          stat   = "Sum"
          metrics = [
            [{
              expression = "SELECT SUM(FailureCount) FROM SCHEMA(\"${local.emf_namespace}\", orderType, region)"
              label      = "failures"
              id         = "q2"
            }]
          ]
        }
      },
      # Row 2 (left): request-latency-alarm status
      {
        type   = "alarm"
        x      = 0
        y      = 6
        width  = 8
        height = 6
        properties = {
          title = "Request Latency Alarm (p90)"
          alarms = [
            aws_cloudwatch_metric_alarm.request_latency.arn,
          ]
        }
      },
      # Row 2 (right): Logs Insights — success vs failure bar
      {
        type   = "log"
        x      = 8
        y      = 6
        width  = 16
        height = 6
        properties = {
          title  = "Success vs Failure totals (Logs Insights, EMF)"
          region = var.aws_region
          view   = "bar"
          query  = "SOURCE '${local.emf_log_group_name}' | filter ispresent(SuccessCount) or ispresent(FailureCount) | stats sum(SuccessCount) as Successes, sum(FailureCount) as Failures"
        }
      },
      # Row 3 (left): Metrics Insights — failures by region + orderType
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "Failures by region + orderType (Metrics Insights, EMF)"
          view   = "timeSeries"
          region = var.aws_region
          period = 300
          stat   = "Sum"
          metrics = [
            [{
              expression = "SELECT SUM(FailureCount) FROM SCHEMA(\"${local.emf_namespace}\", orderType, region) GROUP BY region, orderType"
              label      = "sum(FailureCount) by region, orderType"
              id         = "q3"
            }]
          ]
        }
      },
      # Row 3 (right): Metrics Insights — SDK OrderOutcome split
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "SDK OrderOutcome by status (PutMetricData)"
          view   = "timeSeries"
          region = var.aws_region
          period = 300
          stat   = "Sum"
          metrics = [
            [{
              expression = "SELECT SUM(OrderOutcome) FROM SCHEMA(\"${local.sdk_namespace}\", orderType, region, status) GROUP BY status"
              label      = "sum(OrderOutcome) by status"
              id         = "q4"
            }]
          ]
        }
      },
      # Row 4: Logs Insights — latest 25 order events with fields
      {
        type   = "log"
        x      = 0
        y      = 18
        width  = 24
        height = 6
        properties = {
          title  = "Recent order events (Logs Insights, EMF)"
          region = var.aws_region
          view   = "table"
          query  = "SOURCE '${local.emf_log_group_name}' | fields @timestamp, region, orderType, symbol, RequestLatency, SuccessCount, FailureCount | sort @timestamp desc | limit 25"
        }
      },
      # Row 5: Contributor Insights — top orderType by failure count
      {
        type   = "contributorInsights"
        x      = 0
        y      = 24
        width  = 24
        height = 6
        properties = {
          title            = "Top orderType by failure count (Contributor Insights)"
          region           = var.aws_region
          period           = 300
          insightRuleNames = [aws_cloudwatch_contributor_insight_rule.orders_error_contributors.rule_name]
          topContributors  = 10
          legend = {
            position = "bottom"
          }
        }
      },
    ]
  })
}
