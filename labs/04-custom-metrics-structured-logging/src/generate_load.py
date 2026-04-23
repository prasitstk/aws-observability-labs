#!/usr/bin/env python3
"""Load generator for the Lab 04 Flask Orders API.

Usage:

    python generate_load.py --url http://<ec2-ip>:5000/orders --count 30
    python generate_load.py --url http://<ec2-ip>:5000/orders --count 30 --use-sdk

The --use-sdk flag toggles the Flask app's PutMetricData path, which
publishes to the CWLabs/OrderServiceSDK namespace in addition to EMF.
"""

from __future__ import annotations

import argparse
import random
import sys
import time

import requests

ORDER_TYPES = ("Market", "Limit", "Stop")
REGIONS = ("us-east-1", "eu-central-1", "us-west-2")
SYMBOLS = ("AAPL", "GOOGL", "MSFT", "AMZN", "TSLA", "JPM", "GS", "BAC")


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Send random order requests to the Lab 04 Flask API.")
    parser.add_argument("--url", required=True, help="Full URL to the /orders endpoint.")
    parser.add_argument("--count", type=int, default=10, help="Number of requests to send.")
    parser.add_argument("--sleep", type=float, default=1.0, help="Seconds between requests.")
    parser.add_argument("--use-sdk", action="store_true", help="Set useSDK=true in the request body.")
    parser.add_argument("--timeout", type=float, default=15.0, help="Per-request timeout in seconds.")
    return parser.parse_args()


def _build_payload(use_sdk: bool) -> dict:
    return {
        "orderType": random.choice(ORDER_TYPES),
        "region": random.choice(REGIONS),
        "symbol": random.choice(SYMBOLS),
        "useSDK": use_sdk,
    }


def main() -> int:
    args = _parse_args()
    success = 0
    failure = 0

    print(f"Sending {args.count} requests to {args.url} (useSDK={args.use_sdk})")
    for i in range(args.count):
        payload = _build_payload(args.use_sdk)
        try:
            resp = requests.post(args.url, json=payload, timeout=args.timeout)
            tag = "OK " if resp.status_code == 200 else "ERR"
            print(f"[{i + 1:>3}/{args.count}] {tag} {resp.status_code} {payload} -> {resp.text.strip()[:120]}")
            if resp.status_code == 200:
                success += 1
            else:
                failure += 1
        except requests.exceptions.RequestException as exc:
            print(f"[{i + 1:>3}/{args.count}] EXC {exc} payload={payload}")
            failure += 1
        time.sleep(args.sleep)

    print(f"Done. success={success} failure={failure}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
