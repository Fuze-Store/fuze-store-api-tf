# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

All commands use environment-specific config files from `envs/{dev,prod}/`.

```bash
# Initialize (required before first plan/apply, or when switching environments)
terraform init -backend-config=envs/dev/backend.hcl

# Plan changes
terraform plan -var-file=envs/dev/terraform.tfvars

# Apply changes
terraform apply -var-file=envs/dev/terraform.tfvars

# Destroy infrastructure
terraform destroy -var-file=envs/dev/terraform.tfvars
```

Replace `dev` with `prod` for production. There is no test runner or linter configured.

## Architecture

This repo provisions AWS infrastructure (ap-southeast-1) for a **Laravel API with WebSocket support** using Terraform >= 1.3.0 and AWS provider ~> 5.0.

### Resources managed in `main.tf`

- **VPC** — 2 AZs, public/private subnets (10.0.0.0/16), NAT gateway disabled
- **EC2 (Laravel app)** — t3.micro in public subnet with EIP, IMDSv2 enforced
- **EC2 (WebSocket)** — t4g.micro (ARM) in public subnet with EIP, IMDSv2 enforced
- **RDS PostgreSQL 18.1** — in private subnets, deletion protection enabled, not publicly accessible
- **S3 bucket** — file uploads with versioning, public read access, CORS configured
- **SQS queue** — Laravel background job processing
- **DynamoDB table** — application cache (PAY_PER_REQUEST)
- **IAM** — EC2 role with managed policies for S3, SQS, RDS, DynamoDB, CloudWatch Logs
- **Security groups** — EC2 SG (SSH, HTTP, HTTPS, PostgreSQL ingress); RDS SG (PostgreSQL from EC2 SG only)

### Key patterns

- **Naming**: all resources use `local.name_prefix` = `"fuze-store-${var.environment}"`
- **Provider alias**: AWS provider is aliased as `"dev"` regardless of environment
- **Backend**: S3 partial backend config — `backend.tf` declares `backend "s3" {}`, actual config loaded from `envs/{env}/backend.hcl` via `-backend-config` flag. State locking uses DynamoDB.
- **Environment separation**: separate S3 state buckets and DynamoDB lock tables per environment. Variable overrides via `envs/{env}/terraform.tfvars` (gitignored).
- **Required variables** (no defaults, must be in tfvars): `key_pair_name`, `db_password` (sensitive)
- **Community modules**: `terraform-aws-modules/vpc/aws` v5.1.2, `terraform-aws-modules/rds/aws` v6.13.1
