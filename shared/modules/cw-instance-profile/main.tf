# -----------------------------------------------------------------------------
# cw-instance-profile: IAM role + instance profile for CloudWatch-monitored instances
# Attaches CloudWatchAgentServerPolicy + AmazonSSMManagedInstanceCore plus any
# additional policies.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "this" {
  name               = "${var.project_name}-${var.role_name_suffix}-role"
  assume_role_policy = file("${path.module}/../../policies/ec2-assume-role.json")

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.role_name_suffix}-role"
  })
}

resource "aws_iam_role_policy_attachment" "cw_agent" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "additional" {
  count      = length(var.additional_policy_arns)
  role       = aws_iam_role.this.name
  policy_arn = var.additional_policy_arns[count.index]
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.project_name}-${var.role_name_suffix}-profile"
  role = aws_iam_role.this.name

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-${var.role_name_suffix}-profile"
  })
}
