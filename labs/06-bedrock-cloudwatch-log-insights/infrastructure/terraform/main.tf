# -----------------------------------------------------------------------------
# Lab 06: Bedrock CloudWatch Log Insights (AI capstone)
# Deploys: S3 bucket with trade-input/ + trade-output/ prefixes, a
# trade-processor Lambda (S3 PUT → classify JSON trades → write CSV), a
# log-analyzer Lambda invoked by a CloudWatch Custom Widget (describe log
# stream → Bedrock Claude Haiku 4.5 → HTML summary), and a CloudWatch
# dashboard combining the custom widget with Lambda observability tiles.
# Demonstrates AI-powered root-cause analysis delivered inline on a dashboard.
# -----------------------------------------------------------------------------

locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  bucket_name = (
    var.bucket_name_override != ""
    ? var.bucket_name_override
    : "${var.project_name}-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.id}-trades"
  )

  trade_processor_name = "${var.project_name}-trade-processor"
  log_analyzer_name    = "${var.project_name}-log-analyzer"

  trade_processor_log_group = "/aws/lambda/${local.trade_processor_name}"
  log_analyzer_log_group    = "/aws/lambda/${local.log_analyzer_name}"
}

# --- Data Sources ---

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "archive_file" "trade_processor" {
  type        = "zip"
  source_dir  = "${path.module}/../../src/trade_processor"
  output_path = "${path.module}/../../src/trade_processor.zip"
}

data "archive_file" "log_analyzer" {
  type        = "zip"
  source_dir  = "${path.module}/../../src/log_analyzer"
  output_path = "${path.module}/../../src/log_analyzer.zip"
}

# --- S3 Bucket (trade input + output) ---

resource "aws_s3_bucket" "trades" {
  bucket        = local.bucket_name
  force_destroy = true

  tags = merge(local.common_tags, {
    Name = local.bucket_name
  })
}

resource "aws_s3_bucket_versioning" "trades" {
  bucket = aws_s3_bucket.trades.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "trades" {
  bucket = aws_s3_bucket.trades.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "trades" {
  bucket = aws_s3_bucket.trades.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "trades" {
  bucket = aws_s3_bucket.trades.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# --- Trade Processor Lambda ---

resource "aws_iam_role" "trade_processor" {
  name = "${var.project_name}-trade-processor-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "trade_processor" {
  name = "${var.project_name}-trade-processor-policy"
  role = aws_iam_role.trade_processor.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid    = "CloudWatchLogs"
          Effect = "Allow"
          Action = [
            "logs:CreateLogStream",
            "logs:PutLogEvents",
          ]
          Resource = "arn:aws:logs:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:log-group:${local.trade_processor_log_group}:*"
        },
        {
          Sid    = "S3TradeIO"
          Effect = "Allow"
          Action = [
            "s3:GetObject",
            "s3:PutObject",
          ]
          Resource = "${aws_s3_bucket.trades.arn}/*"
        },
      ],
      var.grant_processor_putmetric ? [{
        Sid      = "CloudWatchPutMetric"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
      }] : []
    )
  })
}

resource "aws_cloudwatch_log_group" "trade_processor" {
  name              = local.trade_processor_log_group
  retention_in_days = var.cloudwatch_log_retention_days

  tags = merge(local.common_tags, {
    Name = "${local.trade_processor_name}-logs"
  })
}

resource "aws_lambda_function" "trade_processor" {
  function_name    = local.trade_processor_name
  description      = "Classifies trade records uploaded to S3 and emits logs that the analyzer Lambda summarises via Bedrock."
  role             = aws_iam_role.trade_processor.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.13"
  timeout          = var.trade_processor_timeout
  memory_size      = 128
  filename         = data.archive_file.trade_processor.output_path
  source_code_hash = data.archive_file.trade_processor.output_base64sha256

  environment {
    variables = {
      OUTPUT_PREFIX    = var.trade_output_prefix
      METRIC_NAMESPACE = "CWLabs/TradeProcessor"
      PUBLISH_METRICS  = "true"
      PROJECT_NAME     = var.project_name
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.trade_processor,
    aws_iam_role_policy.trade_processor,
  ]

  tags = merge(local.common_tags, {
    Name = local.trade_processor_name
  })
}

resource "aws_lambda_permission" "s3_invoke_trade_processor" {
  statement_id   = "AllowS3InvokeTradeProcessor"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.trade_processor.function_name
  principal      = "s3.amazonaws.com"
  source_arn     = aws_s3_bucket.trades.arn
  source_account = data.aws_caller_identity.current.account_id
}

resource "aws_s3_bucket_notification" "trade_input_trigger" {
  bucket = aws_s3_bucket.trades.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.trade_processor.arn
    events              = ["s3:ObjectCreated:Put"]
    filter_prefix       = var.trade_input_prefix
    filter_suffix       = ".json"
  }

  depends_on = [aws_lambda_permission.s3_invoke_trade_processor]
}

# --- Log Analyzer Lambda (invoked by CloudWatch Custom Widget) ---

resource "aws_iam_role" "log_analyzer" {
  name = "${var.project_name}-log-analyzer-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "log_analyzer" {
  name = "${var.project_name}-log-analyzer-policy"
  role = aws_iam_role.log_analyzer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "OwnCloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:log-group:${local.log_analyzer_log_group}:*"
      },
      {
        Sid    = "ReadTargetLogGroup"
        Effect = "Allow"
        Action = [
          "logs:DescribeLogStreams",
          "logs:GetLogEvents",
          "logs:FilterLogEvents",
          "logs:StartQuery",
          "logs:GetQueryResults",
          "logs:StopQuery",
        ]
        Resource = [
          "${aws_cloudwatch_log_group.trade_processor.arn}:*",
          aws_cloudwatch_log_group.trade_processor.arn,
        ]
      },
      {
        Sid    = "BedrockInvoke"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:GetInferenceProfile",
        ]
        Resource = [
          "arn:aws:bedrock:*:*:inference-profile/${var.bedrock_model_id}",
          var.bedrock_foundation_model_arn,
        ]
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "log_analyzer" {
  name              = local.log_analyzer_log_group
  retention_in_days = var.cloudwatch_log_retention_days

  tags = merge(local.common_tags, {
    Name = "${local.log_analyzer_name}-logs"
  })
}

resource "aws_lambda_function" "log_analyzer" {
  function_name    = local.log_analyzer_name
  description      = "Called by a CloudWatch Custom Widget to summarise the most recent log stream of the trade-processor Lambda using Amazon Bedrock."
  role             = aws_iam_role.log_analyzer.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.13"
  timeout          = var.log_analyzer_timeout
  memory_size      = var.log_analyzer_memory_size
  filename         = data.archive_file.log_analyzer.output_path
  source_code_hash = data.archive_file.log_analyzer.output_base64sha256

  environment {
    variables = {
      MODEL_ID            = var.bedrock_model_id
      RECENT_EVENTS_LIMIT = tostring(var.recent_events_limit)
      BEDROCK_REGION      = var.aws_region
      DEFAULT_LOG_GROUP   = local.trade_processor_log_group
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.log_analyzer,
    aws_iam_role_policy.log_analyzer,
  ]

  tags = merge(local.common_tags, {
    Name = local.log_analyzer_name
  })
}

# CloudWatch Custom Widgets invoke the Lambda via the dashboard's
# service-linked role, but the Lambda's resource policy still needs to allow
# invocation from the cloudwatch.amazonaws.com principal.
resource "aws_lambda_permission" "cloudwatch_invoke_log_analyzer" {
  statement_id  = "AllowCloudWatchCustomWidget"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.log_analyzer.function_name
  principal     = "cloudwatch.amazonaws.com"
  source_arn    = "arn:aws:cloudwatch::${data.aws_caller_identity.current.account_id}:dashboard/${var.project_name}-dashboard"
}

# --- SNS Notifications ---

resource "aws_sns_topic" "alarms" {
  name = "${var.project_name}-alarms"

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-alarms-topic"
  })
}

resource "aws_sns_topic_subscription" "email" {
  count = var.notification_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# --- CloudWatch Metric Alarms ---

resource "aws_cloudwatch_metric_alarm" "trade_processor_errors" {
  alarm_name          = "${var.project_name}-trade-processor-errors"
  alarm_description   = "Any error on the trade-processor Lambda. With grant_processor_putmetric=false this is expected and is the signal Bedrock will summarise."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  period              = 60
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.trade_processor.function_name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "log_analyzer_errors" {
  alarm_name          = "${var.project_name}-log-analyzer-errors"
  alarm_description   = "Any error on the log-analyzer Lambda. Indicates the custom-widget pipeline itself is failing (Bedrock throttle, IAM drift, timeout)."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  period              = 60
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.log_analyzer.function_name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "log_analyzer_duration" {
  alarm_name          = "${var.project_name}-log-analyzer-duration-p90"
  alarm_description   = "Log-analyzer p90 duration exceeds ${var.analyzer_duration_p90_threshold_ms} ms — Bedrock is running slow and the custom widget is at risk of timing out."
  namespace           = "AWS/Lambda"
  metric_name         = "Duration"
  extended_statistic  = "p90"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.analyzer_duration_p90_threshold_ms
  period              = 300
  evaluation_periods  = 2
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.log_analyzer.function_name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = local.common_tags
}

# --- CloudWatch Dashboard (Custom Widget + Lambda observability) ---

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project_name}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      # Row 1: operator instructions
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 3
        properties = {
          markdown = <<-EOT
            # Bedrock Log Insights — Operator View

            Upload a JSON trade batch to **s3://${local.bucket_name}/${var.trade_input_prefix}** to generate logs in `${local.trade_processor_log_group}`.
            The **AI Log Summary** widget below invokes the `${local.log_analyzer_name}` Lambda, which pulls the most recent log stream, sends it to Bedrock (`${var.bedrock_model_id}`), and renders the HTML summary inline.

            On first load CloudWatch will prompt you to allow the dashboard to call the Lambda — choose **Allow always** to render the widget.
          EOT
        }
      },
      # Row 2: Bedrock-generated HTML summary (custom widget)
      {
        type   = "custom"
        x      = 0
        y      = 3
        width  = 24
        height = 12
        properties = {
          title    = "AI Log Summary (Bedrock ${var.bedrock_model_id})"
          endpoint = aws_lambda_function.log_analyzer.arn
          params = {
            log_group_arn = aws_cloudwatch_log_group.trade_processor.arn
          }
          updateOn = {
            refresh   = true
            resize    = false
            timeRange = false
          }
        }
      },
      # Row 3: Analyzer Lambda observability
      {
        type   = "metric"
        x      = 0
        y      = 15
        width  = 6
        height = 6
        properties = {
          title   = "Analyzer Invocations"
          region  = var.aws_region
          metrics = [["AWS/Lambda", "Invocations", "FunctionName", local.log_analyzer_name]]
          period  = 300
          stat    = "Sum"
          view    = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 6
        y      = 15
        width  = 6
        height = 6
        properties = {
          title   = "Analyzer Errors"
          region  = var.aws_region
          metrics = [["AWS/Lambda", "Errors", "FunctionName", local.log_analyzer_name]]
          period  = 300
          stat    = "Sum"
          view    = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 15
        width  = 6
        height = 6
        properties = {
          title  = "Analyzer Duration (ms)"
          region = var.aws_region
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", local.log_analyzer_name, { stat = "Average", label = "Average" }],
            ["...", { stat = "Maximum", label = "Maximum" }],
          ]
          period = 300
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 18
        y      = 15
        width  = 6
        height = 6
        properties = {
          title  = "Analyzer Duration Percentiles"
          region = var.aws_region
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", local.log_analyzer_name, { stat = "p50", label = "p50" }],
            ["...", { stat = "p90", label = "p90" }],
            ["...", { stat = "p99", label = "p99" }],
          ]
          period = 300
          view   = "timeSeries"
        }
      },
      # Row 4: Trade processor observability
      {
        type   = "metric"
        x      = 0
        y      = 21
        width  = 12
        height = 6
        properties = {
          title  = "Trade Processor — Invocations & Errors"
          region = var.aws_region
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", local.trade_processor_name, { label = "Invocations", color = "#2ca02c" }],
            ["AWS/Lambda", "Errors", "FunctionName", local.trade_processor_name, { label = "Errors", color = "#d62728" }],
          ]
          period = 60
          stat   = "Sum"
          view   = "timeSeries"
        }
      },
      {
        type   = "log"
        x      = 12
        y      = 21
        width  = 12
        height = 6
        properties = {
          title  = "Trade Processor — Recent Log Events"
          region = var.aws_region
          view   = "table"
          query  = "SOURCE '${local.trade_processor_log_group}' | fields @timestamp, @message | sort @timestamp desc | limit 25"
        }
      },
      # Row 5: Alarm status
      {
        type   = "alarm"
        x      = 0
        y      = 27
        width  = 24
        height = 4
        properties = {
          title = "Lambda Alarms"
          alarms = [
            aws_cloudwatch_metric_alarm.trade_processor_errors.arn,
            aws_cloudwatch_metric_alarm.log_analyzer_errors.arn,
            aws_cloudwatch_metric_alarm.log_analyzer_duration.arn,
          ]
        }
      },
    ]
  })
}
