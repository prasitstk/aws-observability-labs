output "s3_bucket_name" {
  value       = aws_s3_bucket.trades.id
  description = "S3 bucket that accepts trade-input/ uploads and stores trade-output/ results."
}

output "s3_bucket_arn" {
  value = aws_s3_bucket.trades.arn
}

output "trade_input_uri" {
  value       = "s3://${aws_s3_bucket.trades.id}/${var.trade_input_prefix}"
  description = "Upload a JSON batch of trades here to drive the pipeline."
}

output "trade_processor_function_name" {
  value = aws_lambda_function.trade_processor.function_name
}

output "trade_processor_log_group" {
  value = aws_cloudwatch_log_group.trade_processor.name
}

output "trade_processor_log_group_arn" {
  value = aws_cloudwatch_log_group.trade_processor.arn
}

output "log_analyzer_function_name" {
  value = aws_lambda_function.log_analyzer.function_name
}

output "log_analyzer_function_arn" {
  value = aws_lambda_function.log_analyzer.arn
}

output "bedrock_model_id" {
  value = var.bedrock_model_id
}

output "dashboard_name" {
  value = aws_cloudwatch_dashboard.main.dashboard_name
}

output "dashboard_url" {
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
  description = "Direct link to the CloudWatch dashboard hosting the Bedrock custom widget."
}

output "upload_sample_command" {
  value       = "aws s3 cp ../../src/sample-trades.json s3://${aws_s3_bucket.trades.id}/${var.trade_input_prefix}sample-trades.json --region ${var.aws_region}"
  description = "Ready-to-use CLI command to trigger the pipeline with the bundled sample batch."
}
