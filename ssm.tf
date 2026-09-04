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
    # BOTH shapes are seedable, because they differ per environment and this
    # list is shared by all of them. Seed the pair the environment actually
    # uses and give the other set an empty value in the source env file — the
    # seed script stores that as the __EMPTY__ sentinel, which renders back as
    # blank, and config/maya.php treats blank as unset (it uses `?:`, not
    # env()'s default argument, precisely so that holds).
    #
    #   two applications  -> seed the four per-family keys, leave the pair blank
    #   one multi-solution credential -> seed the pair, leave the four blank
    #
    # Every name here must appear in the env file at seed time even when blank.
    # A name absent from that file stays PLACEHOLDER, and ONE PLACEHOLDER under
    # the path makes render-env.sh skip the whole .env render — deploys then
    # keep shipping the previous config while reporting success.
    #
    # PROD IS NOT RECONCILED as of 2026-09-05 — it still holds the XENDIT_*
    # params and NONE of the MAYA_* ones, so a plain apply there creates seven
    # PLACEHOLDERs at once. Follow docs/maya-prod-reconciliation.md; do not
    # improvise the order.
    "MAYA_PUBLIC_KEY",
    "MAYA_SECRET_KEY",
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
    # NOT a secret — the public browser-origin allowlist for credentialed CORS
    # on api/* (config/cors.php). It sits here, against the "non-secret config
    # lives in the base env file" rule, so a wrong or missing browser origin can
    # be corrected WITHOUT a code commit. Note SSM is read at DEPLOY time, so a
    # param edit alone changes nothing — re-run the deploy workflow after it.
    # Consequence to remember: the value in environments/{env}.base.env is INERT
    # on deployed environments once this exists, so change BOTH.
    #
    # Value must NEVER be "*": config/cors.php sets supports_credentials, so
    # php-cors skips the wildcard branch and reflects whatever Origin was sent,
    # handing every site on the internet a credentialed allow.
    #
    # SEEDED OUT-OF-BAND 2026-09-05, BEFORE it was added to this list, so it
    # ALREADY EXISTS with a real value. IMPORT it before the next apply — do NOT
    # let terraform create it: a create writes PLACEHOLDER over the live value,
    # and one PLACEHOLDER under this path makes render-env.sh skip the ENTIRE
    # .env render while deploys keep reporting success. After the import,
    # ignore_changes = [value] protects the seeded value permanently.
    #
    #   terraform init -backend-config=envs/prod/backend.hcl
    #   terraform import -var-file=envs/prod/terraform.tfvars \
    #     'aws_ssm_parameter.api_secret["CORS_ALLOWED_ORIGINS"]' \
    #     /fuze-store/prod/api/CORS_ALLOWED_ORIGINS
    #
    # Repeat for dev with envs/dev/* and the /fuze-store/dev/... path.
    #
    # The follow-up plan is NOT "No changes" — expect ONE in-place update that
    # drops the hand-written description and flips the Terraform tag false ->
    # true (dev, 2026-09-05). That is cosmetic; apply it or let the next full
    # apply pick it up. What matters is that `value` MUST NOT appear in the
    # diff: ignore_changes keeps it hidden among the unchanged attributes. If
    # you ever see value -> "PLACEHOLDER", STOP and do not apply.
    "CORS_ALLOWED_ORIGINS",
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
