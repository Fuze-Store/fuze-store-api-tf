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
    # Maya Business payment gateway (ADR 0079). One key pair PER API FAMILY:
    # Maya scopes a credential to one family, so a Checkout key is refused by
    # /payments/v1/* and a Vault key cannot read a checkout. Maya Business
    # Manager's "Add Application" is single-select, which is why there are two
    # applications and four keys rather than one pair.
    #
    # MAYA_PUBLIC_KEY / MAYA_SECRET_KEY are deliberately NOT here. They are the
    # single-multi-solution-credential fallback and stay blank in the base env
    # files while the per-family keys are set; add them only if a future
    # environment is issued one credential serving both families.
    "MAYA_CHECKOUT_PUBLIC_KEY",
    "MAYA_CHECKOUT_SECRET_KEY",
    # Not read by the API — card tokenization is client-side on mobile, which
    # carries its own copy. Held here as the canonical source for that value.
    "MAYA_VAULT_PUBLIC_KEY",
    "MAYA_VAULT_SECRET_KEY",
    # Not issued by Maya — we generate it (openssl rand -hex 32). Maya signs no
    # webhook, so this URL segment plus the IP allowlist is the ONLY auth on
    # /webhooks/payments/{token}; a blank value lets anyone forge paid callbacks.
    "MAYA_WEBHOOK_PATH_TOKEN",
    "GOOGLE_CLIENT_SECRET",
    # Google "Desktop app" OAuth client used by the Fuze Store Hub's browser
    # sign-in. The Hub ships client IDs only; the code->token exchange runs
    # server-side (POST /api/v1/social/exchange), so this secret lives here.
    # Its client ID is NOT a secret and sits in the API's *.base.env files
    # alongside GOOGLE_CLIENT_ID. Facebook needs no desktop pair — it falls
    # back to FACEBOOK_CLIENT_SECRET, since Facebook user ids are app-scoped
    # and the Hub must therefore use the same app as the API anyway.
    "GOOGLE_DESKTOP_CLIENT_SECRET",
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
