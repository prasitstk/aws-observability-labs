"""Classify trade records uploaded to S3.

Triggered by s3:ObjectCreated:Put events under the trade-input/ prefix.
Reads a JSON file of trade records, classifies each, writes a CSV summary
back to trade-output/, and publishes a CloudWatch custom metric.

The CloudWatch PutMetricData call is intentional — on the initial deploy the
execution role does NOT grant cloudwatch:PutMetricData, which raises an
AccessDeniedException. That error is the signal the log-analyzer Lambda
summarises via Bedrock. Flip grant_processor_putmetric=true in Terraform to
fix the role and observe a clean summary on the next run.
"""

import csv
import io
import json
import logging
import os
import time
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")
cloudwatch = boto3.client("cloudwatch")

OUTPUT_PREFIX = os.environ.get("OUTPUT_PREFIX", "trade-output/")
METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "CWLabs/TradeProcessor")
PUBLISH_METRICS = os.environ.get("PUBLISH_METRICS", "true").lower() == "true"
PROJECT_NAME = os.environ.get("PROJECT_NAME", "bedrock-log-insights")


def classify_trade(trade):
    """Classify a single trade record.

    Returns a dict with the original fields plus an orderClass label.
    """
    side = str(trade.get("side", "")).lower()
    qty = float(trade.get("qty", 0) or 0)
    price = trade.get("price")

    if price is None:
        order_class = "marketOrder"
    elif trade.get("stopPrice") is not None:
        order_class = "stopOrder"
    else:
        order_class = "limitOrder"

    notional = qty * float(price) if price is not None else 0.0

    return {
        "symbol": trade.get("symbol", "UNKNOWN"),
        "side": side,
        "qty": qty,
        "price": price if price is not None else "",
        "venue": trade.get("venue", "UNKNOWN"),
        "orderClass": order_class,
        "notionalUsd": round(notional, 2),
    }


def publish_metric(metric_name, value, unit="Count", dimensions=None):
    """Publish a CloudWatch metric. Raises ClientError on AccessDenied."""
    cloudwatch.put_metric_data(
        Namespace=METRIC_NAMESPACE,
        MetricData=[
            {
                "MetricName": metric_name,
                "Value": value,
                "Unit": unit,
                "Timestamp": datetime.now(timezone.utc),
                "Dimensions": dimensions or [{"Name": "Project", "Value": PROJECT_NAME}],
            }
        ],
    )


def lambda_handler(event, context):
    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key = record["s3"]["object"]["key"]
        logger.info("Processing trade batch: s3://%s/%s", bucket, key)

        start = time.time()

        try:
            obj = s3.get_object(Bucket=bucket, Key=key)
            body = obj["Body"].read().decode("utf-8")
        except Exception as exc:
            logger.error("Failed to read input object %s: %s", key, exc)
            continue

        try:
            trades = json.loads(body)
            if not isinstance(trades, list):
                trades = [trades]
        except json.JSONDecodeError as exc:
            logger.error("Input is not valid JSON: %s", exc)
            continue

        logger.info("Loaded %d trade records from %s", len(trades), key)

        classified = []
        failed = 0
        for i, trade in enumerate(trades):
            try:
                classified.append(classify_trade(trade))
            except Exception as exc:
                failed += 1
                logger.warning("Trade index %d failed to classify: %s", i, exc)

        # Write CSV back to trade-output/
        csv_buf = io.StringIO()
        writer = csv.DictWriter(
            csv_buf,
            fieldnames=[
                "symbol",
                "side",
                "qty",
                "price",
                "venue",
                "orderClass",
                "notionalUsd",
            ],
        )
        writer.writeheader()
        writer.writerows(classified)

        basename = os.path.splitext(os.path.basename(key))[0]
        out_key = f"{OUTPUT_PREFIX}{basename}_classified.csv"

        try:
            s3.put_object(
                Bucket=bucket,
                Key=out_key,
                Body=csv_buf.getvalue().encode("utf-8"),
                ContentType="text/csv",
            )
            logger.info("Wrote classified output to s3://%s/%s", bucket, out_key)
        except Exception as exc:
            logger.error("Failed to write output %s: %s", out_key, exc)

        # Publish metric — this may intentionally fail with AccessDenied
        # on first deploy. The log-analyzer Lambda summarises that failure
        # via Bedrock so the operator can see the root cause on the
        # CloudWatch dashboard.
        if PUBLISH_METRICS:
            try:
                publish_metric(
                    "TradesClassified",
                    float(len(classified)),
                    unit="Count",
                )
                publish_metric(
                    "TradeClassificationFailures",
                    float(failed),
                    unit="Count",
                )
                logger.info(
                    "Published %d TradesClassified and %d failure metrics to %s",
                    len(classified),
                    failed,
                    METRIC_NAMESPACE,
                )
            except ClientError as exc:
                code = exc.response.get("Error", {}).get("Code", "Unknown")
                logger.error(
                    "cloudwatch:PutMetricData failed with %s — missing IAM permission on trade-processor role. "
                    "Re-apply Terraform with grant_processor_putmetric=true to fix. Full error: %s",
                    code,
                    exc,
                )
            except Exception as exc:
                logger.error("Unexpected PutMetricData error: %s", exc)

        elapsed_ms = int((time.time() - start) * 1000)
        logger.info(
            "Batch complete: %d classified, %d failed, elapsed=%dms",
            len(classified),
            failed,
            elapsed_ms,
        )
