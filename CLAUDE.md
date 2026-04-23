# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

Public collection repo for AWS CloudWatch observability labs. Each lab is built from scratch using AWS documentation as reference, with Terraform as the IaC baseline. The collection tells a progressive monitoring story: govern, observe, instrument, measure, scale, and analyze with AI.

## Terraform Commands

Each lab has Terraform under `labs/NN-name/infrastructure/terraform/`.

```bash
cd labs/04-custom-metrics-structured-logging/infrastructure/terraform

terraform init          # First time or after provider changes
terraform plan          # Preview
terraform apply         # Deploy
terraform destroy       # Always tear down after testing to avoid charges
```

A `terraform.tfvars.example` is provided in each lab. Copy to `terraform.tfvars` and customize before applying. The `.gitignore` excludes `*.tfvars` (but keeps `*.tfvars.example`) and `*.zip` (Lambda deployment packages built by `archive_file` data sources).

## Architecture

### Shared Modules

Labs consume reusable modules via relative paths (e.g., `source = "../../../../shared/modules/cw-vpc"`):

- **`shared/modules/cw-vpc/`** — Public-subnet VPC + internet gateway + base security group. Optional second public subnet for multi-AZ ASG labs (Labs 01 and 05). No NAT gateway, no VPC endpoints — keeps baseline cost low. CloudWatch Agent reaches the public CloudWatch endpoint over the IGW.
- **`shared/modules/cw-instance-profile/`** — IAM role + instance profile with `CloudWatchAgentServerPolicy` + `AmazonSSMManagedInstanceCore` attached via `aws_iam_role_policy_attachment`. Accepts `additional_policy_arns` for lab-specific permissions (Lab 04 `PutMetricData`, Lab 05 SQS access). Uses `aws_iam_role_policy_attachment` (not deprecated `managed_policy_arns`).
- **`shared/policies/`** — JSON trust policy template for EC2 service assume-role.

### Lab Structure Pattern

```
labs/NN-topic-name/
  README.md
  architecture.drawio          # Source diagram (draw.io XML)
  architecture.png             # Exported at 2x scale
  infrastructure/terraform/    # main.tf, variables.tf, outputs.tf, versions.tf
  src/                         # Lambda code, Flask app, load generators (when needed)
```

All labs use the same provider constraints: Terraform `>= 1.5`, AWS provider `>= 5.0`. Default region is `us-east-1`.

### 5-Layer Enhancement Model

1. **IaC** — Terraform baseline (all labs)
2. **CI/CD** — GitHub Actions (`terraform fmt -check` + `validate` on push and PR)
3. **Monitoring** — CloudWatch dashboards, alarms, SNS, Contributor Insights, log retention discipline
4. **Finance Domain** — Trading-system framing (Labs 02 / 04 / 05 / 06 done; Labs 01 / 03 planned)
5. **Multi-Cloud** — Azure Monitor + Application Insights side-by-side (planned)

### Lab Status

| Lab | Status | Layers |
|-----|--------|--------|
| 01 — Governance Monitoring Overview | Complete | 1 (IaC), 2 (CI/CD), 3 (Monitoring) |
| 02 — CloudWatch Metrics, Dashboards & Alarms | Complete | 1 (IaC), 2 (CI/CD), 3 (Monitoring) |
| 03 — EC2 Detailed Monitoring + CloudWatch Agent | Complete | 1 (IaC), 2 (CI/CD), 3 (Monitoring) |
| 04 — Custom Metrics & Structured Logging | Complete | 1 (IaC), 2 (CI/CD), 3 (Monitoring) |
| 05 — Dynamic Scaling with CloudWatch Alarms | Complete | 1 (IaC), 2 (CI/CD), 3 (Monitoring) |
| 06 — Bedrock CloudWatch Log Insights | Complete | 1 (IaC), 2 (CI/CD), 3 (Monitoring) |

## Layer 3 Design: Consistent Alarm + SNS Wiring

Every `aws_cloudwatch_metric_alarm` across all six labs publishes to **both** `alarm_actions` and `ok_actions` against the lab's SNS topic, so operators see both the breach and the recovery transition. Lab 04 adds a Contributor Insights rule on the EMF log group (top `orderType` by failure count) wired into a dashboard widget. Lab 06 wires three Lambda alarms (processor errors, analyzer errors, analyzer p90 duration) to a dedicated SNS topic. All `aws_cloudwatch_log_group` resources declare `retention_in_days` (14 days default; 30 days for Lab 04 order log groups and Lab 06 Lambda log groups).

## Bedrock-Specific Gotchas (Lab 06)

- **Model access:** First-time Anthropic model users may need to submit use case details before access is granted via the Bedrock console.
- **Cross-region inference profile:** Lab 06 uses `us.anthropic.claude-haiku-4-5-20251001-v1:0`. The Lambda IAM policy must grant `bedrock:InvokeModel` on **both** the inference profile ARN **and** the underlying foundation model ARN — cross-region routing requires both.
- **Custom Widget IAM:** The `cloudwatch.amazonaws.com` principal needs `lambda:InvokeFunction` permission scoped to the dashboard ARN. The first time the dashboard renders, CloudWatch prompts the user to *Allow always*.
- **Lambda timeout:** Bedrock invocations can take 5–30 seconds. The log-analyzer Lambda timeout defaults to 300 seconds.
- **The "controlled failure" demo:** `grant_processor_putmetric` defaults to `false` so the trade-processor hits a controlled `AccessDeniedException` on first run — Bedrock summarises the IAM gap. Flip to `true` and re-apply for a clean summary.

## CloudWatch-Specific Gotchas

- **Dashboards bill monthly even when idle.** Always run `terraform destroy` after testing.
- **Metric Insights vs Logs Insights:** Metric Insights is SQL over metrics (cheap, fast, no per-query cost). Logs Insights is full-text query over log events (per-GB scanned cost). The Lab 04 dashboard mixes both deliberately.
- **Anomaly-detection alarms** require ~2 weeks of data before they're useful. Lab 02 deploys one but the model needs warm-up.
- **EMF auto-extraction** is opt-in per log group via the agent config — the CloudWatch Agent in Labs 03 and 04 ships JSON to the log group, and CloudWatch extracts the metric set from the `_aws` block at ingest. No metric filter required.
- **`aws_cloudwatch_dashboard` widget JSON** uses camelCase keys (`alarm`, `metric`, `log`, `contributorInsights`, `custom`). Type names are case-sensitive — `Alarm` will silently render as a blank widget.
- **Contributor Insights rule attribute** for cross-resource references is `rule_name`, not `name`.

## AWS Provider v6 Gotchas

The `>= 5.0` constraint resolves to AWS provider v6.x:

- `managed_policy_arns` on `aws_iam_role` is deprecated — use `aws_iam_role_policy_attachment` instead.
- `data.aws_region.current.name` is deprecated — use `.id` instead.
- `aws_cloudwatch_contributor_insight_rule` (singular "insight") is the correct resource name; v5 docs sometimes show the plural form which fails to parse.
- Always validate resource schemas against the installed provider version (v6.x), not older docs.

## Architecture Diagrams

Labs use draw.io (`.drawio` XML with `mxgraph.aws4.*` stencils). Export workflow:

```bash
/Applications/draw.io.app/Contents/MacOS/draw.io --export --format png --scale 2 --border 10 -b white -o architecture.png architecture.drawio
```

**Note:** Use `-b white` (short flag) for background. The long form `--background` is misinterpreted as an input path.

Commit both `.drawio` and `.png`. The README references the PNG.

Use **direct shape** style for AWS icons (`sketch=0;...shape=mxgraph.aws4.{service};`), not the legacy `resourceIcon` wrapper. Common service fill colors: Management `#E7157B`, Storage `#3F8624`, Compute `#ED7100`, Networking `#8C4FFF`, Security/IAM `#DD344C`.

## Local Validation

`tests/validate.sh` discovers every Terraform directory under `shared/modules/` and `labs/`, then runs `init -backend=false`, `fmt -check`, and `validate` on each. Run before pushing — it mirrors the CI workflow at `.github/workflows/terraform-ci.yml`.

```bash
bash tests/validate.sh
```

## Conventions

- Lab directories: `NN-descriptive-topic-name` (kebab-case)
- Tags: every resource gets `local.common_tags` (`Project`, `Environment`, `ManagedBy`)
- Git commits: Conventional Commits format — `type(scope): description`
