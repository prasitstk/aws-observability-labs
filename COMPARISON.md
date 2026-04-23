# CloudWatch Monitoring Approaches — Comparative Analysis

A structured comparison of CloudWatch monitoring strategies to inform architecture decisions for observability and auto-scaling.

---

## Monitoring Depth Comparison

| Dimension | Basic EC2 Metrics | Detailed Monitoring | CloudWatch Agent | Custom SDK Metrics (PutMetricData) | Metric Filters |
|---|---|---|---|---|---|
| **What it measures** | CPU, network, disk ops, status checks | Same as basic, higher resolution | OS-level: memory, disk %, disk I/O, network per-interface | Application-specific: latency, throughput, error rates | Log-derived signals: error counts, latency extraction |
| **Resolution** | 5-minute intervals | 1-minute intervals | Configurable (10s-5min) | Configurable (per PutMetricData call) | Per log event → 1-minute aggregation |
| **Setup complexity** | Zero (automatic) | `monitoring = true` on instance | Install agent + JSON config via SSM | SDK integration in application code | Log group + filter pattern definition |
| **Namespace** | `AWS/EC2` | `AWS/EC2` | Custom (e.g., `project/OS`) | Custom (must not start with `AWS/`) | Custom |
| **IAM requirements** | None (built-in) | None (built-in) | `CloudWatchAgentServerPolicy` + `AmazonSSMManagedInstanceCore` | `cloudwatch:PutMetricData` | None (log group permissions only) |
| **Cost** | Free | $2.10/instance/month (7 metrics) | $0.30/custom metric/month | $0.30/metric/month (first 10K free) | Free (included with log ingestion) |
| **Can see memory?** | No | No | Yes | Yes (if app reports it) | Yes (if logged) |
| **Can see disk %?** | No | No | Yes | Yes (if app reports it) | Yes (if logged) |
| **Alarm support** | Yes | Yes | Yes | Yes | Yes |
| **Lab** | Lab 02 | Lab 03 | Lab 03 | Lab 04 | Lab 04 |

## Scaling Policy Comparison

| Dimension | Target Tracking | Step Scaling | Simple Scaling |
|---|---|---|---|
| **How it works** | Set a target value, AWS creates and manages alarms | Define step adjustments at multiple thresholds | Single adjustment per alarm, with cooldown |
| **Alarm management** | AWS creates/manages (you don't see or control them) | You create and maintain alarms | You create and maintain alarms |
| **Adjustment granularity** | One adjustment direction per policy | Multiple steps (e.g., +1 at 70%, +2 at 90%) | Single fixed adjustment |
| **Cooldown** | Built-in, self-managed (no explicit cooldown) | Uses ASG default cooldown (300s default) | Explicit cooldown period required |
| **Multiple metrics** | One metric per policy | One alarm per policy, but alarm can be composite | One alarm per policy |
| **Scale-in protection** | Optional disable scale-in flag | Separate scale-in policy + alarm | Separate alarm |
| **Best for** | Steady-state workloads, minimal config | Bursty workloads needing fine-grained control | Event-driven pipelines, simple on/off scaling |
| **Lab** | Lab 05 | Lab 05 | Lab 01 |

## Multi-Service CloudWatch Monitoring (Lab 02)

Lab 02 demonstrates CloudWatch's ability to unify monitoring across multiple AWS service types — EC2 (`AWS/EC2`), DynamoDB (`AWS/DynamoDB`), and S3 (`AWS/S3`) — in a single dashboard with cross-service alarms.

### How CloudWatch Unifies Multi-Service Monitoring

CloudWatch organizes metrics into **namespaces** (one per AWS service). Each namespace has its own set of metric names and dimensions. A single CloudWatch dashboard can query metrics across any combination of namespaces, providing a unified view of a distributed system.

| Namespace | Metric Examples | Dimensions | Resolution |
|---|---|---|---|
| `AWS/EC2` | CPUUtilization, NetworkIn/Out, DiskReadOps | InstanceId | 5 min (basic), 1 min (detailed) |
| `AWS/DynamoDB` | ConsumedReadCapacityUnits, ConsumedWriteCapacityUnits | TableName | 1 min |
| `AWS/S3` | GetRequests, PutRequests, DeleteRequests | BucketName, FilterId | 1 day (request metrics) |

### S3 Request Metrics — Activation Delay

S3 has two categories of CloudWatch metrics:

- **Storage metrics** (BucketSizeBytes, NumberOfObjects) — always enabled, reported once daily
- **Request metrics** (GetRequests, PutRequests, DeleteRequests, etc.) — **must be explicitly enabled** via `aws_s3_bucket_metric` and take **15-30 minutes** to appear after creation

In Lab 02, `aws_s3_bucket_metric.trade_reports` enables request metrics with `name = "EntireBucket"`. The `FilterId` dimension in alarm/dashboard configurations must match this name exactly. Without this configuration, request-level metrics do not appear in CloudWatch at all.

### Difference from Lab 04 (Custom Metrics)

Lab 02 and Lab 04 both monitor application behavior, but through different mechanisms:

| Aspect | Lab 02: Built-in Service Metrics | Lab 04: Custom PutMetricData |
|---|---|---|
| **Metric source** | AWS services report automatically | Application code calls PutMetricData API |
| **Namespace** | `AWS/EC2`, `AWS/DynamoDB`, `AWS/S3` | Custom (e.g., `project/Trading`) |
| **What you monitor** | Infrastructure capacity and requests | Business logic: latency, throughput, error rates |
| **Code changes** | None — metrics exist by default (S3 needs `bucket_metric`) | Application must instrument PutMetricData calls |
| **Cost** | Free (built-in) or included in service | $0.30/metric/month |
| **Best for** | Capacity planning, infrastructure health | Business SLA monitoring, application performance |

Lab 02's multi-service approach shows CloudWatch's breadth (many services, one dashboard), while Lab 04's custom metrics show CloudWatch's depth (application-specific business metrics pushed via SDK).

## When to Use What

### Basic EC2 Metrics (Lab 02)

**Best for:** Initial monitoring of any EC2 workload — zero setup, zero cost.

- Provides CPU utilization, network in/out, disk read/write ops, and status checks
- Sufficient for alarms on CPU thresholds, anomaly detection, and EC2 actions (auto-stop idle instances)
- 5-minute resolution limits usefulness for latency-sensitive workloads

**Upgrade to detailed monitoring** when you need 1-minute resolution for faster alarm response.

### Detailed Monitoring (Lab 03)

**Best for:** Production workloads where 5-minute alarm latency is too slow.

- Same metrics as basic, but at 1-minute intervals
- Enables 1-minute period alarms — detects and responds to spikes 5x faster
- $2.10/instance/month is negligible for production but adds up for large fleets

**Upgrade to CloudWatch Agent** when you need OS-level metrics (memory, disk %) that EC2 doesn't expose.

### CloudWatch Agent (Lab 03)

**Best for:** Production workloads requiring full OS visibility.

- Memory utilization — the #1 metric EC2 doesn't provide natively
- Disk usage percentage — critical for preventing volume exhaustion
- Per-device I/O and per-interface network metrics
- Log collection from application files (syslog, app.log, etc.)
- Configured centrally via SSM Parameter Store — no SSH needed

**Choose Agent over custom SDK metrics** when you need infrastructure-level observability without modifying application code.

### Custom SDK Metrics — PutMetricData (Lab 04)

**Best for:** Application-specific business metrics that infrastructure monitoring cannot capture.

- Trade latency, order throughput, error rates — domain metrics with business meaning
- Direct SDK call from application code — immediate metric availability
- Supports dimensions, units, and statistical aggregation
- $0.30/metric/month — budget for the metrics that matter most

**Choose PutMetricData over metric filters** when you need real-time, high-fidelity application metrics. PutMetricData pushes exact values; metric filters extract approximations from log text.

### Metric Filters (Lab 04)

**Best for:** Extracting monitoring signals from existing logs without code changes.

- Parse structured JSON logs: `{ $.level = "ERROR" }`, `{ $.latency_ms > 80 }`
- Zero additional cost beyond log ingestion
- Retrospective — filters only apply to new log events after creation
- Limited to simple pattern matching (no joins, no aggregations)

**Choose metric filters** when you're already shipping logs to CloudWatch and want to create alarms from log patterns without touching application code.

### Target Tracking Scaling (Lab 05)

**Best for:** Steady-state workloads where you want AWS to manage scaling automatically.

- Set one target (e.g., "keep CPU at 50%") and AWS handles the rest
- Creates and manages alarms behind the scenes — less infrastructure to maintain
- Graceful scale-in with built-in cooldown to prevent thrashing

**Choose target tracking** as your default scaling approach unless you have specific requirements for step scaling.

### Step Scaling (Lab 05)

**Best for:** Bursty workloads where you need proportional response to different load levels.

- Moderate load (+1 instance at 70% CPU) vs extreme load (+2 instances at 90% CPU)
- Full control over alarm thresholds and evaluation periods
- Can use custom metrics as alarm sources (e.g., queue depth, request latency)

**Choose step scaling** when target tracking's one-size-fits-all approach doesn't match your scaling patterns.

## Event-Driven Notification Patterns (Lab 01 vs Lab 05)

Lab 01 and Lab 05 both use CloudWatch alarms with Auto Scaling, but their notification approaches differ fundamentally:

### Direct SNS Notifications (Lab 05)

CloudWatch alarms publish directly to an SNS topic, which delivers the raw alarm JSON to email subscribers. This is simple and effective for basic alerting.

- **Flow:** CloudWatch Alarm → SNS Topic → Email
- **Content:** Raw alarm state change (alarm name, new state, reason)
- **Latency:** Seconds (near-instant)
- **Cost:** Free (SNS free tier)
- **Best for:** Simple alerting where the alarm message itself is sufficient

### Lambda-Enriched Notifications (Lab 01)

CloudWatch alarms publish to a trigger SNS topic, which invokes Lambda. Lambda queries CloudTrail for RunInstances events and publishes enriched context to a second email SNS topic.

- **Flow:** CloudWatch Alarm → SNS TriggerTopic → Lambda → CloudTrail LookupEvents → SNS EmailTopic → Email
- **Content:** Alarm context + CloudTrail event details (instance IDs, timestamps, user identity, source IP)
- **Latency:** ~2-3 minutes (includes CloudTrail propagation delay)
- **Cost:** Free (Lambda + SNS free tier)
- **Best for:** Governance and audit scenarios where operators need to know *what happened* (which instance launched, who triggered it) — not just *that something happened*

### CloudTrail Query Approaches

| Aspect | Metric Filters on CloudTrail Logs (Lab 01 original) | LookupEvents API (Lab 01 revised) |
|---|---|---|
| **How it works** | CloudTrail → CloudWatch Logs → metric filter → custom metric → alarm | Lambda calls `cloudtrail.lookup_events()` directly |
| **Setup** | CloudTrail CW Logs delivery + IAM + log group + metric filter | Lambda IAM policy with `cloudtrail:LookupEvents` |
| **Cost** | CloudWatch Logs ingestion (~$0.50/GB) | Free (included in CloudTrail) |
| **Latency** | Near-real-time (log stream delay) | 90-day lookback, but events appear after 5-15 min |
| **Best for** | Continuous metric/alarm on log patterns | On-demand event lookup in Lambda handlers |

## Key Trade-offs

### CloudWatch Agent vs Custom SDK Metrics

| Aspect | CloudWatch Agent | PutMetricData SDK |
|---|---|---|
| **What it measures** | OS-level infrastructure metrics | Application-specific business metrics |
| **Code changes** | None (config-only) | Application code must call PutMetricData |
| **Deployment** | SSM parameter + user_data install | Part of application deployment |
| **Metric control** | Predefined set (CPU, mem, disk, net) | Fully custom names, dimensions, units |
| **Log collection** | Built-in file-based collection | Not applicable (separate concern) |

Both are complementary — use Agent for infrastructure and SDK for business metrics.

### Metric Filters vs PutMetricData

| Aspect | Metric Filters | PutMetricData |
|---|---|---|
| **Cost** | Free (beyond log ingestion) | $0.30/metric/month |
| **Accuracy** | Approximate (text pattern matching) | Exact (application computes value) |
| **Latency** | Delayed (log ingestion → filter → metric) | Near-real-time (direct API call) |
| **Setup** | Terraform only (no code changes) | Application code changes required |
| **Best for** | Error counting, pattern detection | Precise business metrics |

### Metric Filter Pattern Examples

| Pattern | What It Matches |
|---|---|
| `{ $.level = "ERROR" }` | JSON logs where `level` field equals `ERROR` |
| `{ $.latency_ms > 80 }` | JSON logs where `latency_ms` exceeds 80 |
| `{ ($.errorCode = "*UnauthorizedAccess*") }` | CloudTrail events with unauthorized access errors |
| `"ERROR"` | Any log line containing the literal string `ERROR` |

### Dashboard Widget Guidelines

CloudWatch dashboards cost $3/month each (first 3 free). Design guidelines:

| Widget Type | Best For | Example |
|---|---|---|
| Time series (`timeSeries`) | Trends over time | CPU utilization, latency |
| Single value (`singleValue`) | Current state at a glance | Fleet capacity, error count |
| Alarm status (`alarm`) | Health overview | Color-coded alarm grid |
| Log query (`log`) | Recent events | Logs Insights table |
| Number (`number`) | Key metric snapshot | Current instance count |

## AI-Powered Log Analysis with Bedrock (Lab 06)

### Bedrock + CloudWatch Logs Insights

**Best for:** Automated root-cause analysis of structured application logs.

- Consumes structured logs generated by Lab 04 (financial trade processor)
- Lambda runs Logs Insights queries to extract error patterns and anomalies
- Sends query results + context to Bedrock for AI-driven root-cause analysis
- Delivers actionable recommendations via SNS (fix suggestions, affected components)
- EventBridge triggers on alarm state changes or scheduled intervals

### When to Use AI Analysis vs Manual Investigation

| Aspect | Manual Logs Insights | Bedrock AI Analysis |
|---|---|---|
| **Investigation depth** | Deep — analyst writes custom queries | Broad — AI reviews patterns across multiple queries |
| **Speed** | Minutes per investigation | Seconds per analysis |
| **Query crafting** | Requires Logs Insights syntax expertise | Pre-built query templates, AI interprets results |
| **Root cause quality** | High — domain expert reasoning | Good for common patterns, may miss domain nuance |
| **Cost** | $0.005/GB scanned | $0.005/GB + ~$0.01-0.10 Bedrock per invocation |
| **Scale** | One investigation at a time | Automated for every alarm trigger |

**Practical guidance:** Use Bedrock analysis as a first-responder — provide initial root-cause hypotheses and recommended actions within minutes of an incident. Human operators then validate and execute the recommendations.

## References

- [CloudWatch Metrics Documentation](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/working_with_metrics.html)
- [CloudWatch Agent Documentation](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Install-CloudWatch-Agent.html)
- [CloudWatch Alarms Documentation](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/AlarmThatSendsEmail.html)
- [CloudWatch Logs Metric Filters](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/MonitoringLogData.html)
- [CloudWatch Logs Insights](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/AnalyzingLogData.html)
- [CloudTrail LookupEvents API](https://docs.aws.amazon.com/awscloudtrail/latest/APIReference/API_LookupEvents.html)
- [Auto Scaling Simple Scaling](https://docs.aws.amazon.com/autoscaling/ec2/userguide/as-scaling-simple-step.html#SimpleScaling)
- [Auto Scaling Target Tracking](https://docs.aws.amazon.com/autoscaling/ec2/userguide/as-scaling-target-tracking.html)
- [Auto Scaling Step Scaling](https://docs.aws.amazon.com/autoscaling/ec2/userguide/as-scaling-simple-step.html)
- [CloudWatch Pricing](https://aws.amazon.com/cloudwatch/pricing/)
- [Amazon Bedrock Documentation](https://docs.aws.amazon.com/bedrock/latest/userguide/what-is-bedrock.html)
- [Amazon Bedrock Pricing](https://aws.amazon.com/bedrock/pricing/)
