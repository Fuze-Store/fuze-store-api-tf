# --------------------
# SSM Parameter Store — application secrets
#
# Terraform manages parameter EXISTENCE only, never the real value:
# every parameter is created as a "PLACEHOLDER" SecureString and
# `ignore_changes = [value]` keeps terraform from ever reading or
# reverting the seeded secret. Real values are seeded out-of-band with
# `scripts/seed-ssm.sh` (or `aws ssm put-parameter --overwrite`), so
# secrets never pass through tfvars, git, or terraform state.
#
# Consumers:
# - Laravel EC2: apps/api/scripts/render-env.sh (fuze-store monorepo)
#   merges /fuze-store/{env}/api/* over environments/{env}.base.env at
#   deploy time, via the instance role (no AWS credentials on the box).
# - WebSocket EC2 (Soketi): render-env.sh in fuze-store-cloud-server
#   reads /fuze-store/{env}/websocket/*.
#
# NOTE: multiline secrets (JWT RSA PEMs, Passport oauth-*.key) stay as
# files on the server — dotenv rendering is line-oriented by design.
# --------------------

data "aws_caller_identity" "current" {}

locals {
  ssm_prefix = "/fuze-store/${var.environment}"

  # Laravel API secrets (rendered into apps/api/.env at deploy).
  # Keep names identical to the .env variable names — the render script
  # writes them verbatim as KEY=value.
  api_secret_params = toset([
    "APP_KEY",
    "APP_PREVIOUS_KEYS", # rotation grace: holds the prior APP_KEY(s) so old ciphertext still decrypts
    "DB_PASSWORD",
    "LOG_SLACK_WEBHOOK_URL",
    "PUSHER_APP_ID",
    "PUSHER_APP_KEY",
    "PUSHER_APP_SECRET",
    "XENDIT_SECRET_KEY",
    "XENDIT_PUBLIC_KEY",
    "XENDIT_CALLBACK_TOKEN",
    "GOOGLE_CLIENT_SECRET",
    "FACEBOOK_CLIENT_SECRET",
    "SENTRY_LARAVEL_DSN",
    "POSTHOG_API_KEY", # PostHog product analytics (ADR 0047) — public write-only project key, but SSM-managed like every credential
    "SMS_API_KEY",
    "SMS_API_SECRET",
    "MOVIDER_API_KEY",
    "MOVIDER_API_SECRET",
    "MOVIDER_DR_WEBHOOK_SECRET",
    "JWT_SECRET",
    "PASSPORT_PERSONAL_ACCESS_CLIENT_ID",
    "PASSPORT_PERSONAL_ACCESS_CLIENT_SECRET",
    "PAIRING_SIGNING_PRIVATE_KEY",
    "PAIRING_SIGNING_PUBLIC_KEY",
    "PAIRING_SIGNING_KEY_ID",
  ])

  # Soketi WebSocket server secrets. The SOKETI_DEFAULT_APP_* values MUST
  # be seeded with the same values as the api subtree's PUSHER_APP_* —
  # the Laravel broadcaster authenticates against the Soketi app.
  websocket_secret_params = toset([
    "SOKETI_DB_POSTGRES_PASSWORD",
    "SOKETI_DEFAULT_APP_ID",
    "SOKETI_DEFAULT_APP_KEY",
    "SOKETI_DEFAULT_APP_SECRET",
  ])
}

resource "aws_ssm_parameter" "api_secret" {
  for_each = local.api_secret_params

  name  = "${local.ssm_prefix}/api/${each.key}"
  type  = "SecureString"
  value = "PLACEHOLDER" # seeded via scripts/seed-ssm.sh — never through terraform

  lifecycle {
    ignore_changes = [value]
  }

  tags = {
    Environment = var.environment
    Terraform   = "true"
  }
}

resource "aws_ssm_parameter" "websocket_secret" {
  for_each = local.websocket_secret_params

  name  = "${local.ssm_prefix}/websocket/${each.key}"
  type  = "SecureString"
  value = "PLACEHOLDER" # seeded via scripts/seed-ssm.sh — never through terraform

  lifecycle {
    ignore_changes = [value]
  }

  tags = {
    Environment = var.environment
    Terraform   = "true"
  }
}

output "ssm_parameter_prefix" {
  description = "SSM path prefix holding this environment's application secrets"
  value       = local.ssm_prefix
}
