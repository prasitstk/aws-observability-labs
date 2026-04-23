# cw-instance-profile

Reusable Terraform module for an IAM role and instance profile with CloudWatch Agent and SSM connectivity.

## Features

- IAM role with EC2 trust policy
- `CloudWatchAgentServerPolicy` managed policy for CloudWatch Agent metrics and logs
- `AmazonSSMManagedInstanceCore` managed policy for SSM Agent connectivity
- Support for additional policy ARNs (e.g., custom PutMetricData policies)
- Instance profile ready for EC2 launch templates

## Usage

```hcl
module "cw_instance_profile" {
  source = "../../../../shared/modules/cw-instance-profile"

  project_name          = "my-cw-lab"
  additional_policy_arns = [
    aws_iam_policy.custom_metrics.arn,
  ]

  common_tags = local.common_tags
}
```

## Inputs

| Name | Description | Type | Default | Required |
|---|---|---|---|---|
| `project_name` | Project name used for resource naming | `string` | — | yes |
| `role_name_suffix` | Suffix appended to the IAM role name | `string` | `"cw-instance"` | no |
| `additional_policy_arns` | List of additional IAM policy ARNs to attach to the role | `list(string)` | `[]` | no |
| `common_tags` | Tags to apply to all resources created by this module | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|---|---|
| `role_name` | Name of the IAM role |
| `role_arn` | ARN of the IAM role |
| `instance_profile_name` | Name of the instance profile |
| `instance_profile_arn` | ARN of the instance profile |

## Design Decisions

- Attaches both `CloudWatchAgentServerPolicy` and `AmazonSSMManagedInstanceCore` by default — CloudWatch Agent requires SSM for config retrieval via Parameter Store.
- Uses `aws_iam_role_policy_attachment` instead of the deprecated `managed_policy_arns` attribute on `aws_iam_role` (AWS provider v6 compatibility).
- Trust policy loaded from shared JSON template at `shared/policies/ec2-assume-role.json`.
