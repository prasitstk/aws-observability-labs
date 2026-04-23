#!/bin/bash
# -----------------------------------------------------------------------------
# Lab 05: Stress Test for ASG Scaling
# Generates CPU load on ASG instances to trigger scaling policies.
# Run via SSM Send Command targeting ASG instances.
#
# Usage (from local machine):
#   aws ssm send-command \
#     --document-name "AWS-RunShellScript" \
#     --targets "Key=tag:Project,Values=dynamic-scaling" \
#     --parameters 'commands=["bash /tmp/stress_test.sh 300"]' \
#     --region us-east-1
# -----------------------------------------------------------------------------

set -euo pipefail

DURATION=${1:-300}  # Default 5 minutes

echo "=== Starting CPU stress test for ${DURATION}s ==="
echo "Instance: $(ec2-metadata --instance-id | cut -d' ' -f2)"
echo "Time: $(date -u)"

# Install stress-ng if not present
if ! command -v stress-ng &>/dev/null; then
  echo "Installing stress-ng..."
  dnf install -y stress-ng
fi

# Run CPU stress
echo "Running stress-ng --cpu $(nproc) --timeout ${DURATION}s"
stress-ng --cpu "$(nproc)" --timeout "${DURATION}s" --metrics-brief

echo "=== Stress test completed ==="
echo "Time: $(date -u)"
