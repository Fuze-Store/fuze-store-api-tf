#!/usr/bin/env bash
# Seed the SSM parameter shells created by ssm.tf from a local env file.
#
# For every parameter under /fuze-store/{env}/{subtree}/ whose value is
# still "PLACEHOLDER" (or when --overwrite-all is passed), look up the
# matching KEY in the given env file and `aws ssm put-parameter` it.
# Values are never echoed.
#
# Usage:
#   ./scripts/seed-ssm.sh <dev|prod> <api|websocket> <path-to-env-file> [aws-profile] [--overwrite-all]
#
# Examples:
#   ./scripts/seed-ssm.sh prod api ../fuze-store/apps/api/.env my-prod-profile
#   ./scripts/seed-ssm.sh prod websocket ../fuze-store-cloud-server/.env my-prod-profile
#
# After seeding, verify from the EC2 box (instance role, no creds needed):
#   aws ssm get-parameters-by-path --path /fuze-store/prod/api --with-decryption \
#     --region ap-southeast-1 --query 'Parameters[*].Name'
set -euo pipefail

ENVIRONMENT="${1:?usage: seed-ssm.sh <dev|prod> <api|websocket> <env-file> [aws-profile] [--overwrite-all]}"
SUBTREE="${2:?missing subtree (api|websocket)}"
ENV_FILE="${3:?missing path to env file}"
AWS_PROFILE_ARG=()
OVERWRITE_ALL=false

for arg in "${@:4}"; do
  if [ "$arg" = "--overwrite-all" ]; then
    OVERWRITE_ALL=true
  else
    AWS_PROFILE_ARG=(--profile "$arg")
  fi
done

REGION="${AWS_REGION:-ap-southeast-1}"
SSM_PATH="/fuze-store/${ENVIRONMENT}/${SUBTREE}"

if [ ! -f "$ENV_FILE" ]; then
  echo "env file not found: $ENV_FILE" >&2
  exit 1
fi

# Read a KEY's value out of the env file without echoing it.
# Handles KEY=value, KEY="value", KEY='value'. Last occurrence wins.
env_value() {
  local key="$1"
  local line value
  line=$(grep -E "^[[:space:]]*${key}=" "$ENV_FILE" | tail -n1 || true)
  [ -z "$line" ] && return 1
  value="${line#*=}"
  # strip surrounding quotes
  case "$value" in
    \"*\") value="${value#\"}"; value="${value%\"}" ;;
    \'*\') value="${value#\'}"; value="${value%\'}" ;;
  esac
  printf '%s' "$value"
}

echo "Seeding ${SSM_PATH}/* from ${ENV_FILE} (region ${REGION})"

# List the parameter shells terraform created (names + current values).
# (while-read instead of mapfile — macOS ships bash 3.2)
entries_file=$(mktemp)
chmod 600 "$entries_file"
trap 'rm -f "$entries_file"' EXIT
aws ssm get-parameters-by-path \
  --path "$SSM_PATH" --with-decryption --region "$REGION" "${AWS_PROFILE_ARG[@]}" \
  --query 'Parameters[*].[Name,Value]' --output text > "$entries_file"

if [ ! -s "$entries_file" ]; then
  echo "No parameters found under ${SSM_PATH} — run 'terraform apply' first." >&2
  exit 1
fi

seeded=0 skipped_seeded=0 missing=0

while IFS=$'\t' read -r name current; do
  [ -z "$name" ] && continue
  key="${name##*/}"

  if [ "$current" != "PLACEHOLDER" ] && [ "$OVERWRITE_ALL" != "true" ]; then
    echo "  = ${key} (already seeded, skipping — use --overwrite-all to replace)"
    skipped_seeded=$((skipped_seeded + 1))
    continue
  fi

  if value=$(env_value "$key"); then
    # SSM rejects empty values — a key that exists in the env file with an
    # empty value is seeded as the __EMPTY__ sentinel, which the render
    # scripts write back as an empty value.
    if [ -z "$value" ]; then
      value="__EMPTY__"
      note=" (empty → __EMPTY__ sentinel)"
    else
      note=""
    fi
    aws ssm put-parameter \
      --name "$name" --type SecureString --overwrite \
      --value "$value" --region "$REGION" "${AWS_PROFILE_ARG[@]}" >/dev/null
    echo "  + ${key} seeded${note}"
    seeded=$((seeded + 1))
  else
    echo "  ! ${key} — key not found in ${ENV_FILE}; still PLACEHOLDER"
    missing=$((missing + 1))
  fi
done < "$entries_file"

echo
echo "Done: ${seeded} seeded, ${skipped_seeded} already seeded, ${missing} missing."
if [ "$missing" -gt 0 ]; then
  echo "Fill the missing ones manually (value stays out of shell history):"
  echo '  read -rs SECRET && aws ssm put-parameter --name '"${SSM_PATH}"'/<KEY> \'
  echo '    --type SecureString --overwrite --value "$SECRET" --region '"${REGION}"' && unset SECRET'
fi
