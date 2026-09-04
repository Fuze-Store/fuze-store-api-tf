# Runbook — reconciling PROD terraform after the Maya migration

**Status as of 2026-09-05: prod is NOT reconciled.** Read the hazard section
before running any `terraform apply` against prod.

`ssm.tf` was updated for the Maya gateway migration ([ADR 0079], 2026-08-27) and
prod has never been applied since. Dev is fully reconciled.

| | dev | prod |
|---|---|---|
| `ssm.tf` api params | 31 | 31 (same config) |
| Live SSM params | 31 | 27 |
| In terraform state | 31 | 26 |
| `MAYA_*` | 7 present | **0 — missing** |
| `XENDIT_*` | none | **3 still present** |

---

## The hazard — read this first

A plain `terraform apply` against prod today would **create 8 parameters and
destroy 3**. Two of those creates are dangerous, for two *different* reasons:

```
WOULD CREATE (in ssm.tf, absent from prod state)
  CORS_ALLOWED_ORIGINS       <-- EXISTS LIVE with a real value.
                                 A create writes PLACEHOLDER OVER IT.
  MAYA_CHECKOUT_PUBLIC_KEY   <-- do not exist yet.
  MAYA_CHECKOUT_SECRET_KEY       Created as PLACEHOLDER.
  MAYA_PUBLIC_KEY
  MAYA_SECRET_KEY
  MAYA_VAULT_PUBLIC_KEY
  MAYA_VAULT_SECRET_KEY
  MAYA_WEBHOOK_PATH_TOKEN

WOULD DESTROY (in prod state, removed from ssm.tf)
  XENDIT_CALLBACK_TOKEN      <-- expected and safe; nothing reads these
  XENDIT_PUBLIC_KEY              after the Maya migration.
  XENDIT_SECRET_KEY
```

**Why a `PLACEHOLDER` is not a small problem.** `render-env.sh` in the
`fuze-store` monorepo safe-skips the **entire** `.env` render if *any* parameter
under `/fuze-store/prod/api/` still reads `PLACEHOLDER`. It exits 0. The deploy
reports success. The box keeps serving its previous `.env`, so every config
change after that point silently fails to land — including unrelated ones.

The failure is invisible except for one line in the deploy log:

```
render-env: unseeded PLACEHOLDER params (...) — keeping existing .env
```

So the ordering rule for this whole runbook is: **never leave a `PLACEHOLDER`
under the prod path, not even for a minute.** Apply-then-seed opens exactly that
window. Seed-then-import closes it.

---

## Prerequisites

- Live Maya **production** credentials. As of 2026-09-05 the payment-provider
  application is still pending — which is the same fact `BETA_MODE` encodes, and
  is the likely reason prod was never applied. If the keys do not exist yet, you
  can still reconcile using `__EMPTY__` sentinels (see Step B3) — prod already
  runs with blank Maya credentials today, so that changes nothing operationally.
- `aws` CLI with the `fuze-store-prod` SSO profile logged in.
- `terraform` initialised against prod:
  ```bash
  terraform init -reconfigure -backend-config=envs/prod/backend.hcl
  ```
  Always pass `-reconfigure` when switching environments. Without it terraform
  may offer to *copy* the current state into the other environment's bucket.
- `TF_VAR_db_password` exported — `variable.tf` marks it `sensitive` with no
  default, so terraform prompts interactively and will hang a scripted run:
  ```bash
  export TF_VAR_db_password="$(aws ssm get-parameter \
    --name /fuze-store/prod/api/DB_PASSWORD --with-decryption \
    --region ap-southeast-1 --profile fuze-store-prod \
    --query Parameter.Value --output text)"
  ```

---

## Part A — import `CORS_ALLOWED_ORIGINS` (independent, do this first)

It was seeded out-of-band on 2026-09-05 before being added to `ssm.tf`, so it
exists live but is absent from state. Import adopts it; `ignore_changes = [value]`
then protects the value permanently.

```bash
terraform import -input=false -var-file=envs/prod/terraform.tfvars \
  'aws_ssm_parameter.api_secret["CORS_ALLOWED_ORIGINS"]' \
  /fuze-store/prod/api/CORS_ALLOWED_ORIGINS
```

The follow-up targeted plan reports **one cosmetic in-place update** (drops the
hand-written description, flips the `Terraform` tag `false -> true`) — not
"No changes". That is expected; dev behaved identically.

**Abort condition:** if `value` appears in that diff — especially
`value -> "PLACEHOLDER"` — stop and do not apply.

---

## Part B — reconcile the Maya parameters

The safe order is **create with real values -> import -> apply**, which never
produces a `PLACEHOLDER`. The order documented in `CLAUDE.md` (add to list,
apply, seed) is fine for a fresh environment but wrong here, because it opens the
render-skipping window described above.

### B1. Decide the credential shape

Maya scopes a credential to ONE API family, and Maya Business Manager's "Add
Application" is single-select — hence two applications and four keys, rather than
one pair. `config/maya.php` resolves per family with a `?:` fallback:

```php
'public_key' => env('MAYA_CHECKOUT_PUBLIC_KEY') ?: env('MAYA_PUBLIC_KEY', ''),
```

`?:` is used rather than `env()`'s default argument precisely so a *blank* line
falls through. So exactly one of these shapes is seeded, and the other is blank:

| Shape | Seed with real values | Seed as `__EMPTY__` |
|---|---|---|
| **Two applications** (what dev uses) | the 4 `MAYA_CHECKOUT_*` + `MAYA_VAULT_*` | `MAYA_PUBLIC_KEY`, `MAYA_SECRET_KEY` |
| One multi-solution credential | `MAYA_PUBLIC_KEY`, `MAYA_SECRET_KEY` | the 4 per-family keys |

Verified dev shape (2026-09-05), for reference:

```
MAYA_CHECKOUT_PUBLIC_KEY   set        MAYA_PUBLIC_KEY   __EMPTY__
MAYA_CHECKOUT_SECRET_KEY   set        MAYA_SECRET_KEY   __EMPTY__
MAYA_VAULT_PUBLIC_KEY      set
MAYA_VAULT_SECRET_KEY      set
MAYA_WEBHOOK_PATH_TOKEN    set
```

`MAYA_VAULT_*` is not read by the API — card tokenisation is client-side on
mobile, which carries its own copy. It is held here as the canonical source.

All 7 names must end up existing with a non-`PLACEHOLDER` value, blank included.

### B2. Generate the webhook path token

`MAYA_WEBHOOK_PATH_TOKEN` is **not issued by Maya — we generate it.** Maya signs
no webhook, so this URL segment plus the IP allowlist is the ONLY authentication
on `/webhooks/payments/{token}`. A blank value lets anyone forge paid callbacks.

```bash
openssl rand -hex 32
```

### B3. Create all 7 parameters with real values

Set the 4 real keys and blank the pair (two-application shape). `__EMPTY__` is
the sentinel for an intentionally-blank value — SSM rejects empty strings, and
`render-env.sh` writes `__EMPTY__` back out as a genuine blank.

```bash
# Real values — read without leaving them in shell history.
for KEY in MAYA_CHECKOUT_PUBLIC_KEY MAYA_CHECKOUT_SECRET_KEY \
           MAYA_VAULT_PUBLIC_KEY MAYA_VAULT_SECRET_KEY MAYA_WEBHOOK_PATH_TOKEN; do
  read -rs -p "$KEY: " V && echo
  aws ssm put-parameter --name "/fuze-store/prod/api/$KEY" --value "$V" \
    --type SecureString --key-id alias/aws/ssm --tier Standard \
    --tags Key=Environment,Value=prod Key=Terraform,Value=true \
    --region ap-southeast-1 --profile fuze-store-prod >/dev/null && echo "  + $KEY"
  unset V
done

# Deliberately blank under the two-application shape.
for KEY in MAYA_PUBLIC_KEY MAYA_SECRET_KEY; do
  aws ssm put-parameter --name "/fuze-store/prod/api/$KEY" --value "__EMPTY__" \
    --type SecureString --key-id alias/aws/ssm --tier Standard \
    --tags Key=Environment,Value=prod Key=Terraform,Value=true \
    --region ap-southeast-1 --profile fuze-store-prod >/dev/null && echo "  = $KEY (__EMPTY__)"
done
```

Tag `Terraform=true` here, since these are about to be imported and genuinely
become terraform-managed.

### B4. Import all 7 into state

```bash
for KEY in MAYA_PUBLIC_KEY MAYA_SECRET_KEY MAYA_CHECKOUT_PUBLIC_KEY \
           MAYA_CHECKOUT_SECRET_KEY MAYA_VAULT_PUBLIC_KEY \
           MAYA_VAULT_SECRET_KEY MAYA_WEBHOOK_PATH_TOKEN; do
  terraform import -input=false -var-file=envs/prod/terraform.tfvars \
    "aws_ssm_parameter.api_secret[\"$KEY\"]" "/fuze-store/prod/api/$KEY" || break
done
```

### B5. Plan, and read it carefully

```bash
terraform plan -input=false -var-file=envs/prod/terraform.tfvars
```

Expected: **0 to add**, some in-place tag/description updates, and **3 to
destroy** (the `XENDIT_*` params).

**Abort conditions — stop and investigate if the plan shows any of these:**

- Anything **to add** under `aws_ssm_parameter.api_secret` — an import was
  missed, and applying will write `PLACEHOLDER` over it.
- `value` appearing in any parameter diff, especially `-> "PLACEHOLDER"`.
- Destroys beyond the 3 `XENDIT_*` parameters.

### B6. Apply

```bash
terraform apply -var-file=envs/prod/terraform.tfvars
```

---

## Verification (mandatory before the next API deploy)

This is the single check that matters — it must print `none`:

```bash
aws ssm get-parameters-by-path --path /fuze-store/prod/api --with-decryption \
  --region ap-southeast-1 --profile fuze-store-prod --output json \
| python3 -c "import json,sys; d=json.load(sys.stdin); \
p=[x['Name'].rsplit('/',1)[-1] for x in d['Parameters'] if x['Value']=='PLACEHOLDER']; \
print(p or 'none — render-env will not safe-skip')"
```

Then confirm the counts line up — 31 live, 31 in state, 0 pending changes:

```bash
aws ssm get-parameters-by-path --path /fuze-store/prod/api --region ap-southeast-1 \
  --profile fuze-store-prod --query 'length(Parameters)' --output text
terraform state list | grep -c 'aws_ssm_parameter.api_secret'
```

After the next API deploy, confirm the render actually happened — the log must
show `render-env: rendered ...`, **not** `keeping existing .env`.

---

## If a PLACEHOLDER does reach prod

Nothing is lost and no rollback is needed — but **do not deploy** until it is
cleared, because deploys will silently no-op on config.

1. Seed the offending parameter with its real value (or `__EMPTY__`):
   ```bash
   read -rs SECRET && aws ssm put-parameter --name /fuze-store/prod/api/<KEY> \
     --type SecureString --overwrite --value "$SECRET" \
     --region ap-southeast-1 && unset SECRET
   ```
2. Re-run the verification above until it prints `none`.
3. Re-run the deploy. `render-env.sh` keeps the prior file at `.env.previous`,
   so the box was never left without a working config.

---

## Related

- `ssm.tf` — the parameter list, the `PLACEHOLDER` warning, and the
  `CORS_ALLOWED_ORIGINS` import note.
- `scripts/seed-ssm.sh` — seeds only still-`PLACEHOLDER` params unless
  `--overwrite-all`. Note that `--overwrite-all` against an env file missing a
  key leaves that key `PLACEHOLDER`, which is a second route into this failure.
- `fuze-store/apps/api/scripts/render-env.sh` — the consumer, and the source of
  the safe-skip contract.
- ADR 0079 (`fuze-store/docs/adr/0079-maya-gateway-abstraction-and-dunning.md`)
  — why the gateway moved to Maya and why credentials are per-API-family.
