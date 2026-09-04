# GitHub Actions → AWS, via OIDC, for deploying over SSM.
#
# WHY THIS EXISTS
#
# `Deploy API` used to SSH from a GitHub-hosted runner to the EC2 box. That can
# never work on prod: `ssh_allowed_cidr_blocks` is two /32 office addresses, and
# hosted runners get dynamic Azure IPs. Dev worked only because its list is
# 0.0.0.0/0 — so the two environments were never exercising the same path, and
# the first production deploy attempt died on `dial tcp :22: i/o timeout` after
# the merge.
#
# The fix is to stop needing inbound SSH at all. SSM `send-command` reaches the
# instance through the agent's OUTBOUND connection, which is already Online on
# both boxes, so nothing about the security group has to be widened. Combined
# with OIDC there are also no long-lived AWS keys in GitHub secrets.
#
# Once this is live, port 22 can be narrowed further or closed entirely; it is
# left alone here because that is a separate, human decision.

# `data.aws_caller_identity.current` is already declared in main.tf.

# Derived, not required input. envs/*/terraform.tfvars is gitignored, so a
# value that HAS to be set there is a value that silently defaults to the wrong
# thing on a fresh clone — and here the wrong thing is a production role that
# trusts the development branch.
locals {
  deploy_branch = coalesce(
    var.deploy_branch,
    var.environment == "prod" ? "production" : "development",
  )
}

# GitHub's OIDC issuer. The thumbprint list is deliberately omitted: since 2023
# AWS validates GitHub's endpoint against its own trust store, and pinning a
# leaf thumbprint here would silently break every deploy the day GitHub rotates
# its certificate.
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["ffffffffffffffffffffffffffffffffffffffff"]

  lifecycle {
    ignore_changes = [thumbprint_list]
  }

  tags = {
    Name        = "${local.name_prefix}-github-oidc"
    Environment = var.environment
  }
}

# The role a deploy run assumes.
#
# The trust condition is the whole security boundary, so it is scoped to one
# repo AND one branch. `repo:<owner>/<repo>:ref:refs/heads/<branch>` means a
# workflow on any other branch — or a fork — cannot assume this role even
# though the OIDC provider is account-wide. Without the `sub` condition any
# GitHub repo on earth could assume it.
resource "aws_iam_role" "github_actions_deploy" {
  name = "${local.name_prefix}-github-actions-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:ref:refs/heads/${local.deploy_branch}"
          }
        }
      }
    ]
  })

  tags = {
    Name        = "${local.name_prefix}-github-actions-deploy"
    Environment = var.environment
  }
}

# Least privilege: send ONE document to ONE instance, and read back the result.
#
# `SendCommand` is scoped to both the instance ARN and the document ARN, so this
# role cannot run an arbitrary document (AWS-RunShellScript is the only one
# permitted) and cannot target any other instance in the account. The read
# actions take `*` because a command invocation has no ARN to scope to — the
# command id is only known after the send.
resource "aws_iam_role_policy" "github_actions_deploy" {
  name = "${local.name_prefix}-github-actions-deploy"
  role = aws_iam_role.github_actions_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SendDeployCommand"
        Effect = "Allow"
        Action = "ssm:SendCommand"
        Resource = [
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.laravel.id}",
          "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript",
        ]
      },
      {
        Sid      = "ReadCommandResult"
        Effect   = "Allow"
        Action   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
        Resource = "*"
      },
    ]
  })
}

output "github_actions_deploy_role_arn" {
  description = "Set as the AWS_DEPLOY_ROLE_ARN secret on the matching GitHub Environment."
  value       = aws_iam_role.github_actions_deploy.arn
}

output "deploy_target_instance_id" {
  description = "Set as the DEPLOY_INSTANCE_ID secret on the matching GitHub Environment."
  value       = aws_instance.laravel.id
}
