"""
Lambda function that processes CloudWatch alarm notifications via SNS,
queries CloudTrail for recent RunInstances events, and sends enriched
email notifications through a second SNS topic.

Architecture: CloudWatch Alarm -> SNS TriggerTopic -> this Lambda
              -> CloudTrail LookupEvents API
              -> SNS EmailTopic -> email subscriber

References:
  - https://docs.aws.amazon.com/awscloudtrail/latest/APIReference/API_LookupEvents.html
  - https://docs.aws.amazon.com/lambda/latest/dg/with-sns.html
"""

import json
import logging
import os
import time
from datetime import datetime, timedelta, timezone

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

cloudtrail = boto3.client("cloudtrail")
sns = boto3.client("sns")

EMAIL_TOPIC_ARN = os.environ["EMAIL_TOPIC_ARN"]
LOOKBACK_MINUTES = int(os.environ.get("LOOKBACK_MINUTES", "10"))
SETTLE_SECONDS = int(os.environ.get("SETTLE_SECONDS", "130"))


def lookup_run_instances_events():
    """Query CloudTrail for recent RunInstances API calls."""
    now = datetime.now(timezone.utc)
    start = now - timedelta(minutes=LOOKBACK_MINUTES)

    response = cloudtrail.lookup_events(
        LookupAttributes=[
            {"AttributeKey": "EventName", "AttributeValue": "RunInstances"}
        ],
        StartTime=start,
        EndTime=now,
        MaxResults=5,
    )

    events = []
    for event in response.get("Events", []):
        entry = {
            "EventId": event.get("EventId"),
            "EventName": event.get("EventName"),
            "EventTime": event.get("EventTime", "").isoformat()
            if hasattr(event.get("EventTime", ""), "isoformat")
            else str(event.get("EventTime", "")),
            "EventSource": event.get("EventSource"),
            "Username": event.get("Username"),
        }
        resources = event.get("Resources", [])
        if resources:
            entry["Resource"] = {
                "ResourceType": resources[0].get("ResourceType"),
                "ResourceName": resources[0].get("ResourceName"),
            }
        events.append(entry)
    return events


def handler(event, context):
    """Lambda entry point — triggered by SNS from CloudWatch alarm."""
    logger.info("Received event: %s", json.dumps(event))

    # Parse the SNS message (CloudWatch alarm payload)
    sns_message = event["Records"][0]["Sns"]["Message"]
    try:
        alarm_data = json.loads(sns_message)
        alarm_name = alarm_data.get("AlarmName", "Unknown")
        new_state = alarm_data.get("NewStateValue", "Unknown")
        reason = alarm_data.get("NewStateReason", "")
    except (json.JSONDecodeError, KeyError):
        alarm_name = "Unknown"
        new_state = "Unknown"
        reason = sns_message

    # Wait for CloudTrail to record the scaling event
    logger.info("Waiting %d seconds for CloudTrail logs...", SETTLE_SECONDS)
    time.sleep(SETTLE_SECONDS)

    # Query CloudTrail for RunInstances events
    try:
        ct_events = lookup_run_instances_events()
    except Exception:
        logger.exception("Failed to query CloudTrail")
        ct_events = []

    # Build enriched notification
    subject = f"Scaling Event: {alarm_name} -> {new_state}"
    body_lines = [
        "=== CloudWatch Alarm ===",
        f"Alarm:  {alarm_name}",
        f"State:  {new_state}",
        f"Reason: {reason}",
        "",
        f"=== CloudTrail RunInstances (last {LOOKBACK_MINUTES} min) ===",
    ]

    if ct_events:
        for ev in ct_events:
            body_lines.append(f"  EventId:   {ev['EventId']}")
            body_lines.append(f"  EventName: {ev['EventName']}")
            body_lines.append(f"  Time:      {ev['EventTime']}")
            body_lines.append(f"  Source:    {ev['EventSource']}")
            body_lines.append(f"  User:      {ev['Username']}")
            if "Resource" in ev:
                body_lines.append(f"  Resource:  {ev['Resource']['ResourceName']}")
            body_lines.append("")
    else:
        body_lines.append("  No RunInstances events found in this window.")

    message = "\n".join(body_lines)

    # Publish to email topic
    try:
        sns.publish(
            TopicArn=EMAIL_TOPIC_ARN,
            Subject=subject[:100],
            Message=message,
        )
        logger.info("Notification sent to %s", EMAIL_TOPIC_ARN)
    except Exception:
        logger.exception("Failed to publish to SNS")
        raise

    return {"statusCode": 200, "body": "Event processed successfully"}
