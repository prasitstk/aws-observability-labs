#!/usr/bin/env python3
"""Flask Orders API — custom metrics + structured logs demo.

Two complementary techniques on a single POST /orders endpoint:

1. Embedded Metric Format (EMF): write a CloudWatch-native JSON record
   to a log file the CloudWatch Agent tails. CloudWatch auto-extracts
   metrics from the `_aws` block — no PutMetricData call, no metric
   filter. Published to namespace CWLabs/OrderServiceEMF.

2. PutMetricData SDK: call cloudwatch.put_metric_data() directly.
   Published to namespace CWLabs/OrderServiceSDK. Activated per-request
   via the `useSDK` payload field so both paths can be compared.

Log files are emitted under /home/ec2-user and picked up by the
CloudWatch Agent configuration that ships via SSM Parameter Store.
"""

from __future__ import annotations

import json
import logging
import os
import random
import sys
import time
from typing import Any

import boto3
from flask import Flask, jsonify, request

REGION = os.environ.get("AWS_REGION", "us-east-1")
EMF_NAMESPACE = os.environ.get("EMF_NAMESPACE", "CWLabs/OrderServiceEMF")
SDK_NAMESPACE = os.environ.get("SDK_NAMESPACE", "CWLabs/OrderServiceSDK")
EMF_LOG_PATH = os.environ.get("EMF_LOG_PATH", "/home/ec2-user/logs-emf-orders.log")
SDK_LOG_PATH = os.environ.get("SDK_LOG_PATH", "/home/ec2-user/logs-sdk-orders.log")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "5000"))

ALLOWED_ORDER_TYPES = ("Market", "Limit", "Stop")
ALLOWED_REGIONS = ("us-east-1", "eu-central-1", "us-west-2")

app = Flask(__name__)

emf_logger = logging.getLogger("emf")
emf_logger.setLevel(logging.INFO)
emf_logger.addHandler(logging.FileHandler(EMF_LOG_PATH))
emf_logger.handlers[-1].setFormatter(logging.Formatter("%(message)s"))

sdk_logger = logging.getLogger("sdk")
sdk_logger.setLevel(logging.INFO)
sdk_logger.addHandler(logging.FileHandler(SDK_LOG_PATH))
sdk_logger.handlers[-1].setFormatter(logging.Formatter("%(message)s"))

console = logging.getLogger("console")
console.setLevel(logging.INFO)
console.addHandler(logging.StreamHandler(sys.stdout))

cloudwatch = boto3.client("cloudwatch", region_name=REGION)


def _simulate_latency_ms(order_type: str) -> int:
    """Simulate realistic per-order-type latency with occasional long tails."""
    start = time.time()
    if order_type == "Limit":
        time.sleep(random.uniform(0.6, 2.6))
    elif random.random() < 0.75:
        time.sleep(random.uniform(0.2, 1.4))
    else:
        time.sleep(random.uniform(0.05, 0.3))
    return int((time.time() - start) * 1000)


def _emit_emf(region: str, order_type: str, symbol: str, latency_ms: int, success: bool) -> None:
    record: dict[str, Any] = {
        "_aws": {
            "Timestamp": int(time.time() * 1000),
            "CloudWatchMetrics": [
                {
                    "Namespace": EMF_NAMESPACE,
                    # Two dimension sets published per record:
                    #   ["region", "orderType"] — used by the dashboard's Metrics Insights GROUP BY
                    #   []                      — no-dimension aggregate used by request-latency-alarm
                    # The alarm has no `dimensions` block, so it queries the metric at the no-dim
                    # level. Without the empty set below, the alarm sees "Insufficient data" forever
                    # even while traffic is flowing, because EMF only publishes dimensional copies.
                    "Dimensions": [["region", "orderType"], []],
                    "Metrics": [
                        {"Name": "RequestLatency", "Unit": "Milliseconds"},
                        {"Name": "SuccessCount", "Unit": "Count"},
                        {"Name": "FailureCount", "Unit": "Count"},
                    ],
                }
            ],
        },
        "region": region,
        "orderType": order_type,
        "symbol": symbol,
        "RequestLatency": latency_ms,
        "SuccessCount": 1 if success else 0,
        "FailureCount": 0 if success else 1,
    }
    emf_logger.info(json.dumps(record))


def _emit_sdk(region: str, order_type: str, symbol: str, latency_ms: int, success: bool) -> None:
    status = "Success" if success else "Failure"
    cloudwatch.put_metric_data(
        Namespace=SDK_NAMESPACE,
        MetricData=[
            {
                "MetricName": "RequestLatency",
                "Dimensions": [
                    {"Name": "region", "Value": region},
                    {"Name": "orderType", "Value": order_type},
                ],
                "Unit": "Milliseconds",
                "Value": latency_ms,
            },
            {
                "MetricName": "OrderOutcome",
                "Dimensions": [
                    {"Name": "region", "Value": region},
                    {"Name": "orderType", "Value": order_type},
                    {"Name": "status", "Value": status},
                ],
                "Unit": "Count",
                "Value": 1,
            },
        ],
    )
    sdk_logger.info(
        json.dumps(
            {
                "ts": int(time.time() * 1000),
                "region": region,
                "orderType": order_type,
                "symbol": symbol,
                "status": status,
                "latencyMs": latency_ms,
            }
        )
    )


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok"}), 200


@app.route("/orders", methods=["POST"])
def create_order():
    payload = request.get_json(silent=True) or {}
    order_type = payload.get("orderType", "Market")
    region = payload.get("region", REGION)
    symbol = payload.get("symbol", "AAPL")
    use_sdk = bool(payload.get("useSDK", False))

    if order_type not in ALLOWED_ORDER_TYPES:
        order_type = "Market"
    if region not in ALLOWED_REGIONS:
        region = REGION

    latency_ms = _simulate_latency_ms(order_type)
    success = random.random() >= 0.25  # ~25% failure rate

    _emit_emf(region, order_type, symbol, latency_ms, success)

    if use_sdk:
        try:
            _emit_sdk(region, order_type, symbol, latency_ms, success)
        except Exception as exc:  # noqa: BLE001 — surface SDK failure in logs
            console.info(json.dumps({"event": "sdk_publish_failed", "error": str(exc)}))

    body = {"orderType": order_type, "region": region, "symbol": symbol, "latencyMs": latency_ms}
    return (jsonify({"message": "Order accepted", **body}), 200) if success \
        else (jsonify({"error": "Order failed", **body}), 500)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=LISTEN_PORT)
