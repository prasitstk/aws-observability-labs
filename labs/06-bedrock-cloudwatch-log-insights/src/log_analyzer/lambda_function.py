"""CloudWatch Custom Widget backend.

Invoked by a widget on the lab dashboard. Accepts a log_group_arn parameter,
pulls the most recent log stream, sends the last N events to Amazon Bedrock
(Claude Haiku 4.5) with a log-summarisation prompt, and returns an HTML
fragment the widget renders inline.

Supports the widget "describe" protocol so the widget's docs tab works.

Grounding references (public AWS docs):
  - InvokeModel: https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_InvokeModel.html
  - Anthropic Messages API on Bedrock: https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-anthropic-claude-messages.html
  - CloudWatch custom widgets: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-custom-widgets.html
  - Logs DescribeLogStreams / GetLogEvents:
      https://docs.aws.amazon.com/AmazonCloudWatchLogs/latest/APIReference/API_DescribeLogStreams.html
      https://docs.aws.amazon.com/AmazonCloudWatchLogs/latest/APIReference/API_GetLogEvents.html
"""

import html
import json
import logging
import os
from datetime import datetime, timezone

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

MODEL_ID = os.environ.get("MODEL_ID", "us.anthropic.claude-haiku-4-5-20251001-v1:0")
BEDROCK_REGION = os.environ.get("BEDROCK_REGION", "us-east-1")
DEFAULT_LOG_GROUP = os.environ.get("DEFAULT_LOG_GROUP", "")
RECENT_EVENTS_LIMIT = int(os.environ.get("RECENT_EVENTS_LIMIT", "50"))

logs_client = boto3.client("logs")
bedrock = boto3.client("bedrock-runtime", region_name=BEDROCK_REGION)


DESCRIBE_DOCS = """## Bedrock Log Summary Widget

Calls the log-analyzer Lambda to summarise the most recent log stream of a
target log group using Amazon Bedrock (Claude Haiku 4.5).

### Widget parameters

| Param | Description |
|---|---|
| **log_group_arn** | ARN of the log group to summarise. Defaults to the trade-processor log group when omitted. |

### Example parameters

```yaml
log_group_arn: arn:aws:logs:us-east-1:111122223333:log-group:/aws/lambda/bedrock-log-insights-trade-processor
```
"""


def _latest_log_stream(log_group_identifier):
    """Return the most recently-updated log stream name for the given group."""
    response = logs_client.describe_log_streams(
        logGroupIdentifier=log_group_identifier,
        orderBy="LastEventTime",
        descending=True,
        limit=1,
    )
    streams = response.get("logStreams", [])
    if not streams:
        raise RuntimeError(
            f"No log streams found for {log_group_identifier}. Upload a trade "
            "batch to S3 to produce logs, then refresh this widget."
        )
    return streams[0]["logStreamName"]


def _recent_events_text(log_group_identifier, stream_name, limit):
    """Return a newline-joined '[timestamp] message' string of recent events."""
    response = logs_client.get_log_events(
        logGroupIdentifier=log_group_identifier,
        logStreamName=stream_name,
        limit=limit,
        startFromHead=False,
    )
    events = response.get("events", [])
    if not events:
        return ""

    lines = []
    for event in events:
        ts = datetime.fromtimestamp(event["timestamp"] / 1000, tz=timezone.utc)
        lines.append(f"[{ts.isoformat()}] {event['message'].rstrip()}")
    return "\n".join(lines)


def _bedrock_summarise(events_text, log_group_arn):
    """Invoke Bedrock to summarise the supplied log events."""
    prompt = (
        "You are a cloud operations analyst reviewing AWS CloudWatch log "
        "output for a Lambda function. Your audience is the on-call engineer "
        "watching a CloudWatch dashboard.\n\n"
        f"The target log group is:\n  {log_group_arn}\n\n"
        "Summarise the log excerpt below. Your response MUST follow this "
        "exact structure:\n\n"
        "OVERVIEW:\n"
        "- 1-2 sentences stating what the function appears to be doing.\n\n"
        "OBSERVED ERRORS OR WARNINGS:\n"
        "- Bullet points quoting any exception names, error codes, or "
        "ambiguous WARN lines.\n"
        "- If none, write 'None detected in the provided window.'\n\n"
        "LIKELY ROOT CAUSE:\n"
        "- 1-3 bullet points. Prefer IAM / permission / configuration "
        "explanations when the logs support them.\n\n"
        "RECOMMENDED NEXT STEPS:\n"
        "- 2-4 concrete actions. Reference IAM actions, Terraform variables, "
        "or AWS service names where appropriate.\n\n"
        "--- LOG EXCERPT START ---\n"
        f"{events_text}\n"
        "--- LOG EXCERPT END ---"
    )

    payload = {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 900,
        "temperature": 0.2,
        "top_p": 1,
        "messages": [
            {"role": "user", "content": [{"type": "text", "text": prompt}]}
        ],
    }

    response = bedrock.invoke_model(
        modelId=MODEL_ID,
        body=json.dumps(payload),
        contentType="application/json",
        accept="application/json",
    )
    body = json.loads(response["body"].read())

    usage = body.get("usage", {})
    logger.info(
        "Bedrock tokens — input: %s, output: %s",
        usage.get("input_tokens", "N/A"),
        usage.get("output_tokens", "N/A"),
    )

    text = body["content"][0].get("text", "")
    return text


def _resolve_log_group(widget_params):
    """Return the best available log group identifier (ARN preferred)."""
    arn = (widget_params or {}).get("log_group_arn") or DEFAULT_LOG_GROUP
    if not arn:
        raise ValueError(
            "Missing 'log_group_arn' parameter and no DEFAULT_LOG_GROUP "
            "environment variable is set."
        )
    return arn


def _render_html(log_group_arn, stream_name, summary_text):
    """Render the widget body as HTML."""
    safe_group = html.escape(log_group_arn)
    safe_stream = html.escape(stream_name)
    safe_summary = html.escape(summary_text).replace("\n", "<br />")

    return (
        "<h2>Bedrock Log Summary</h2>"
        f"<p><strong>Log group:</strong> <code>{safe_group}</code><br />"
        f"<strong>Most recent stream:</strong> <code>{safe_stream}</code><br />"
        f"<strong>Model:</strong> <code>{html.escape(MODEL_ID)}</code></p>"
        f"<div style='white-space:normal;line-height:1.5'>{safe_summary}</div>"
    )


def lambda_handler(event, context):
    logger.info("Widget event: %s", json.dumps(event)[:500])

    if isinstance(event, dict) and event.get("describe"):
        return DESCRIBE_DOCS

    widget_context = (event or {}).get("widgetContext") or {}
    params = widget_context.get("params") or {}

    try:
        log_group_arn = _resolve_log_group(params)
        stream_name = _latest_log_stream(log_group_arn)
        events_text = _recent_events_text(log_group_arn, stream_name, RECENT_EVENTS_LIMIT)

        if not events_text:
            return (
                "<h2>Bedrock Log Summary</h2>"
                f"<p>No events found in the latest stream of <code>{html.escape(log_group_arn)}</code>. "
                "Upload a trade batch to S3 and refresh the widget.</p>"
            )

        summary = _bedrock_summarise(events_text, log_group_arn)
        return _render_html(log_group_arn, stream_name, summary)

    except Exception as exc:
        logger.exception("Widget rendering failed")
        return (
            "<h2>Bedrock Log Summary — Error</h2>"
            f"<p><strong>{html.escape(type(exc).__name__)}</strong>: "
            f"{html.escape(str(exc))}</p>"
        )
