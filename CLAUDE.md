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
- **EC2 root volumes** — both instances declare `root_block_device` (`ec2_root_volume_size`, default 8 GB gp3; prod tfvars sets 12, dev stays on the default — ~0.096 USD/GB/month per volume). The AMI's 8 GB filled to 100% on prod websocket on 2026-09-08 (toolchain + 2 GB swapfile + unattended-upgrade downloads, no autoclean, no disk metric); nginx then 500'd every broadcast body over its 8 KB buffer and the SSM agent stopped executing. Resizing is an in-place EBS modify, but EBS grows the device only — cloud-init's growpart runs at the next boot, or finish live with `sudo growpart /dev/nvme0n1 1 && sudo resize2fs /dev/root`. EBS never shrinks, so lowering the variable is a no-op that plans a diff forever.
- **EC2 host hygiene + CloudWatch agent** (`ec2-hygiene.tf`) — three SSM State Manager associations targeting `tag:Environment`: install the CloudWatch agent, configure it from the `/fuze-store/{env}/cloudwatch-agent/config` String parameter (disk_used_percent + mem_used_percent, rolled up to an `InstanceId`-only dimension so the alarms don't depend on device names), and a daily shell association that writes `/etc/apt/apt.conf.d/20fuze-autoclean`, sets `snap refresh.retain=2` and runs `apt-get clean`. This is the Terraform-owned replacement for OS config that would otherwise need `user_data`, which is ignored. `monitoring.tf` alarms on both metrics (`ec2_disk_alarm_threshold` 80, `ec2_memory_alarm_threshold` 90). Associations only bind to instances registered with SSM — if an agent is dead (a full disk kills it), fix the box by hand first.
- **RDS PostgreSQL 18.1** — in private subnets, deletion protection enabled, not publicly accessible
- **S3 bucket** — file uploads with versioning, public read access, CORS configured
- **SQS queue** — Laravel background job processing
- **DynamoDB table** — application cache (PAY_PER_REQUEST)
- **IAM** — EC2 role with managed policies for S3, SQS, RDS, DynamoDB, CloudWatch Logs, and read-only SSM parameter access (`/fuze-store/{env}/*`)
- **Security groups** — EC2 SG (SSH, HTTP, HTTPS, PostgreSQL ingress); RDS SG (PostgreSQL from EC2 SG only)
- **SSM Parameter Store** (`ssm.tf`) — SecureString **shells** for app secrets under `/fuze-store/{env}/api/*` (Laravel) and `/fuze-store/{env}/websocket/*` (Soketi). Terraform manages existence only: every parameter is created as `PLACEHOLDER` with `lifecycle.ignore_changes = [value]`, so real values never touch tfvars, git, or state. Seed real values with `scripts/seed-ssm.sh <dev|prod> <api|websocket> <env-file> [aws-profile]` (fills only still-PLACEHOLDER params; `--overwrite-all` to re-seed). Consumers render `.env` at deploy via the EC2 instance role: `apps/api/scripts/render-env.sh` (fuze-store monorepo, called from `deploy.sh`) and `render-env.sh` in fuze-store-cloud-server. Both safe-skip (keep the existing `.env`) while any param is unseeded. Adding a new secret = add the name to the list in `ssm.tf`, apply, seed. **If the parameter already exists** (seeded out-of-band before being listed), `terraform import` it instead of applying — a create writes `PLACEHOLDER` over the live value, and one PLACEHOLDER under the path makes `render-env.sh` skip the whole `.env` render while deploys still report success. **`CORS_ALLOWED_ORIGINS` (added 2026-09-05) is the one deliberately NON-secret entry** — the browser-origin allowlist for credentialed CORS on `api/*`, held here so a wrong origin is fixable without a code commit (still needs a deploy re-run, since SSM is read at deploy time). It is pending import; see the comment on it in `ssm.tf` for the exact command. **PROD IS OUT OF SYNC WITH THIS CONFIG** (2026-09-05): it was never applied after the Maya migration, so it still holds `XENDIT_*` and none of the seven `MAYA_*` params — a plain `terraform apply` there would create seven PLACEHOLDERs and silently disable every subsequent deploy's `.env` render. Reconcile via [docs/maya-prod-reconciliation.md](docs/maya-prod-reconciliation.md).

### Key patterns

- **Naming**: all resources use `local.name_prefix` = `"fuze-store-${var.environment}"`
- **Provider alias**: AWS provider is aliased as `"dev"` regardless of environment
- **Backend**: S3 partial backend config — `backend.tf` declares `backend "s3" {}`, actual config loaded from `envs/{env}/backend.hcl` via `-backend-config` flag. State locking uses DynamoDB.
- **Environment separation**: separate S3 state buckets and DynamoDB lock tables per environment. Variable overrides via `envs/{env}/terraform.tfvars` (gitignored).
- **Required variables** (no defaults, must be in tfvars): `key_pair_name`, `db_password` (sensitive)
- **Community modules**: `terraform-aws-modules/vpc/aws` v5.1.2, `terraform-aws-modules/rds/aws` v6.13.1
