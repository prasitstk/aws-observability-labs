#!/usr/bin/env python3
"""Financial order worker for Lab 05 dynamic scaling.

Polls an SQS queue, simulates order processing, and deletes messages.
Deployed on every ASG instance via user_data as a systemd service
(``order-worker.service``). The queue URL, AWS region, and simulated
processing delay are supplied through environment variables.

Environment variables:

    QUEUE_URL      - SQS queue URL to poll (required).
    AWS_REGION     - AWS region for the boto3 client (required).
    PROCESS_DELAY  - Seconds to sleep per message to simulate processing.
                     Defaults to 2.
"""

from __future__ import annotations

import json
import logging
import os
import signal
import sys
import time

import boto3

LOG = logging.getLogger("order-worker")
LONG_POLL_SECONDS = 20
MAX_MESSAGES = 1

_shutdown = False


def _handle_signal(signum, _frame):
    global _shutdown
    LOG.info("received signal %s, shutting down", signum)
    _shutdown = True


def _process(order: dict, delay: float) -> None:
    LOG.info(
        "processing order id=%s symbol=%s side=%s qty=%s",
        order.get("order_id"),
        order.get("symbol"),
        order.get("side"),
        order.get("qty"),
    )
    time.sleep(delay)


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )

    queue_url = os.environ.get("QUEUE_URL")
    region = os.environ.get("AWS_REGION")
    delay = float(os.environ.get("PROCESS_DELAY", "2"))

    if not queue_url or not region:
        LOG.error("QUEUE_URL and AWS_REGION are required")
        return 2

    LOG.info("starting worker queue=%s region=%s delay=%ss", queue_url, region, delay)

    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    sqs = boto3.client("sqs", region_name=region)

    while not _shutdown:
        try:
            response = sqs.receive_message(
                QueueUrl=queue_url,
                MaxNumberOfMessages=MAX_MESSAGES,
                WaitTimeSeconds=LONG_POLL_SECONDS,
                VisibilityTimeout=30,
            )
        except Exception:
            LOG.exception("receive_message failed")
            time.sleep(2)
            continue

        messages = response.get("Messages", [])
        if not messages:
            continue

        for message in messages:
            body = message.get("Body", "{}")
            try:
                order = json.loads(body)
            except json.JSONDecodeError:
                LOG.warning("non-json message, dropping: %s", body[:200])
                order = {}

            try:
                _process(order, delay)
                sqs.delete_message(
                    QueueUrl=queue_url,
                    ReceiptHandle=message["ReceiptHandle"],
                )
            except Exception:
                LOG.exception("processing failed; message will retry after visibility timeout")

    LOG.info("worker stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
