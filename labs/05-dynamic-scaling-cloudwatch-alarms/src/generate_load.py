#!/usr/bin/env python3
"""Load generator for the Lab 05 SQS-driven scaling demo.

Sends batches of financial order payloads to an SQS queue so the
``queue_high`` CloudWatch alarm breaches and drives the simple
scaling scale-out policy.

Usage:

    python generate_load.py --queue-url "$(terraform output -raw queue_url)" --count 20
"""

from __future__ import annotations

import argparse
import json
import random
import sys
import uuid

import boto3

SYMBOLS = ("AAPL", "GOOGL", "MSFT", "AMZN", "TSLA", "JPM", "GS", "BAC")
SIDES = ("BUY", "SELL")
BATCH_SIZE = 10


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Send financial order messages to an SQS queue.")
    parser.add_argument("--queue-url", required=True, help="SQS queue URL (terraform output queue_url).")
    parser.add_argument("--count", type=int, default=20, help="Number of messages to send.")
    parser.add_argument("--region", default="us-east-1", help="AWS region (default: us-east-1).")
    return parser.parse_args()


def _build_order() -> dict:
    return {
        "order_id": str(uuid.uuid4()),
        "symbol": random.choice(SYMBOLS),
        "side": random.choice(SIDES),
        "qty": random.randint(10, 500),
    }


def main() -> int:
    args = _parse_args()
    sqs = boto3.client("sqs", region_name=args.region)

    sent = 0
    for batch_start in range(0, args.count, BATCH_SIZE):
        batch = [
            {"Id": str(i), "MessageBody": json.dumps(_build_order())}
            for i in range(batch_start, min(batch_start + BATCH_SIZE, args.count))
        ]
        response = sqs.send_message_batch(QueueUrl=args.queue_url, Entries=batch)
        sent += len(response.get("Successful", []))
        if response.get("Failed"):
            for failure in response["Failed"]:
                print(f"FAILED id={failure.get('Id')} code={failure.get('Code')} msg={failure.get('Message')}")

    attrs = sqs.get_queue_attributes(
        QueueUrl=args.queue_url,
        AttributeNames=["ApproximateNumberOfMessages"],
    )
    depth = attrs.get("Attributes", {}).get("ApproximateNumberOfMessages", "?")
    print(f"sent={sent}/{args.count} approximate_queue_depth={depth}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
