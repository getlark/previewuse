---
name: provision-preview-aws
description: Provision the AWS resources and CI secrets that previewuse needs — S3 bucket, EC2 key pair, security group, IAM instance profile, GitHub/CircleCI OIDC role, and the CI secrets that wire it all together. Use when the user asks to "provision preview AWS", "set up the AWS prerequisites for previewuse", "create the IAM roles for preview deploys", "finish the previewuse setup", or runs /provision-preview-aws. Usually invoked after `configure-preview-deploy` has filled in `preview.config.sh`. Confirms each AWS action before running it and writes GitHub secrets via `gh secret set` when authed.
---

# provision-preview-aws

Provision the AWS prerequisites that previewuse needs and wire up the CI secrets. Companion to [[configure-preview-deploy]] — that skill writes the config; this one creates the cloud resources.

## When to use

The user already has `preview.config.sh` filled in (either via `configure-preview-deploy` or by hand) and now needs the AWS account + CI secrets configured so deploys actually work. Skip if they want to do this manually — direct them to the AWS prerequisites section of `README.md` instead.

## What you produce

- An S3 bucket with Block Public Access, encryption, and a 7-day lifecycle rule on `preview/`.
- An EC2 key pair, with the private key written to `~/.ssh/` and base64-encoded into a CI secret.
- A security group `preview-sg` with 22/80/443 ingress.
- IAM role + instance profile `preview` (the role the EC2 instance assumes).
- GitHub or CircleCI OIDC provider (idempotent — one per AWS account).
- CI role `previewuse-ci` with a policy scoped to the bucket and Route53 hosted zone.
- CI secrets in the user's GitHub repo (or printed for manual paste if `gh` isn't available).

The Route53 hosted zone is **not** created — it usually needs NS delegation at the registrar. If it doesn't exist, halt and tell the user.

## Principles

- **Confirm each resource before creating.** Show the `aws` CLI command you're about to run and ask. The user picked this skill instead of the README because they want guided, not silent.
- **Idempotent.** Check whether each resource exists before creating. Use `aws ... describe-*` / `get-*` / `list-*` and key off the names from `preview.config.sh` (`PREVIEW_S3_BUCKET`, `PREVIEW_KEY_NAME`, `PREVIEW_SECURITY_GROUP_NAME`, `PREVIEW_IAM_PROFILE`). If a resource exists, skip and move on — don't recreate.
- **Don't invent values.** Hosted zone ID, account ID, region, bucket name all come from `preview.config.sh` or `aws sts get-caller-identity` / `aws route53 list-hosted-zones-by-name`. Never guess.
- **Don't write secrets to disk in the repo.** Private keys go to `~/.ssh/`. Forwarded env values go straight to `gh secret set` from a stdin pipe — never echo them.

## Workflow

### 1. Preflight

In parallel:

```bash
aws sts get-caller-identity            # confirms AWS auth + account ID
gh auth status                         # confirms gh auth (ok to skip if absent)
test -f preview.config.sh && source preview.config.sh && env | grep ^PREVIEW_
```

Halt with a clear message if:
- `aws sts get-caller-identity` fails → tell the user to `aws configure` or set `AWS_PROFILE`.
- `preview.config.sh` is missing → suggest running `/configure-preview-deploy` first.
- `PREVIEW_DOMAIN`, `PREVIEW_S3_BUCKET`, or `AWS_REGION` are unset → stop and ask the user to fill them in.

If `gh auth status` fails, note it — you'll fall back to printing secrets at the end.

Detect CI provider by what's on disk: `.github/workflows/preview.yml` → GitHub Actions, `.circleci/config.yml` containing `deploy_preview` → CircleCI. Ask if both or neither.

### 2. Verify the Route53 hosted zone

```bash
aws route53 list-hosted-zones-by-name --dns-name "$PREVIEW_DOMAIN" \
  --query 'HostedZones[?Name==`'"$PREVIEW_DOMAIN"'.`].Id' --output text
```

If empty → halt. Explain: the zone has to exist (and be delegated from the registrar if `PREVIEW_DOMAIN` is a subdomain) before this skill can do anything useful. Don't create it.

Capture the hosted zone ID (strip the `/hostedzone/` prefix) — you'll substitute it into the CI role policy in step 7.

### 3. S3 bucket

Check: `aws s3api head-bucket --bucket "$PREVIEW_S3_BUCKET" 2>&1`.

If missing, confirm and run (one batch):

```bash
aws s3api create-bucket --bucket "$PREVIEW_S3_BUCKET" --region "$AWS_REGION" \
  $( [[ "$AWS_REGION" != "us-east-1" ]] && echo "--create-bucket-configuration LocationConstraint=$AWS_REGION" )
aws s3api put-public-access-block --bucket "$PREVIEW_S3_BUCKET" \
  --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
aws s3api put-bucket-encryption --bucket "$PREVIEW_S3_BUCKET" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-bucket-lifecycle-configuration --bucket "$PREVIEW_S3_BUCKET" \
  --lifecycle-configuration '{"Rules":[{"ID":"expire-preview-artifacts","Filter":{"Prefix":"preview/"},"Status":"Enabled","Expiration":{"Days":7}}]}'
```

If the bucket exists but lacks public-access-block / encryption / lifecycle, **don't silently overwrite** — print what's missing and ask before fixing.

### 4. EC2 key pair

Check: `aws ec2 describe-key-pairs --key-names "${PREVIEW_KEY_NAME:-preview-key}" --region "$AWS_REGION"`.

If missing, confirm and run:

```bash
KEY_NAME="${PREVIEW_KEY_NAME:-preview-key}"
aws ec2 create-key-pair --key-name "$KEY_NAME" --region "$AWS_REGION" \
  --query 'KeyMaterial' --output text > "$HOME/.ssh/${KEY_NAME}"
chmod 600 "$HOME/.ssh/${KEY_NAME}"
```

If it already exists in AWS but `~/.ssh/${KEY_NAME}` doesn't, you can't recover the private key — stop and ask the user to either (a) point at an existing local key file or (b) delete + recreate. Don't auto-delete.

Stash the base64-encoded key for step 8:

```bash
base64 < "$HOME/.ssh/${KEY_NAME}"   # macOS; on Linux drop the `<`-redirect and use `base64 file`
```

### 5. Security group

Check: `aws ec2 describe-security-groups --group-names "${PREVIEW_SECURITY_GROUP_NAME:-preview-sg}" --region "$AWS_REGION"`.

If missing:

```bash
SG_NAME="${PREVIEW_SECURITY_GROUP_NAME:-preview-sg}"
aws ec2 create-security-group --group-name "$SG_NAME" \
  --description "previewuse instances" --region "$AWS_REGION"
SG=$(aws ec2 describe-security-groups --group-names "$SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION")
for port in 22 80 443; do
  aws ec2 authorize-security-group-ingress --group-id "$SG" \
    --protocol tcp --port "$port" --cidr 0.0.0.0/0 --region "$AWS_REGION"
done
```

Surface the warning from `README.md` about 22/80/443 being world-open. Offer to scope SSH to a specific CIDR if the user has one in mind, but don't block on it.

### 6. EC2 instance profile

Check both:
- `aws iam get-role --role-name "${PREVIEW_IAM_PROFILE:-preview}"`
- `aws iam get-instance-profile --instance-profile-name "${PREVIEW_IAM_PROFILE:-preview}"`

If missing, render the trust + policy from the templates next to this skill into `$TMP` (use `mktemp -d`, not the repo). The templates live at `.claude/skills/provision-preview-aws/templates/` (resolve the directory of this `SKILL.md`; do **not** copy JSON out of the README or write it from memory).

```bash
SKILL_DIR="$(dirname "$(realpath .claude/skills/provision-preview-aws/SKILL.md)")"
TMPL="$SKILL_DIR/templates"
TMP="$(mktemp -d)"
ROLE="${PREVIEW_IAM_PROFILE:-preview}"

cp "$TMPL/preview-instance-trust.json" "$TMP/preview-instance-trust.json"
sed "s|__BUCKET__|${PREVIEW_S3_BUCKET}|g" \
  "$TMPL/preview-instance-policy.json" > "$TMP/preview-instance-policy.json"

aws iam create-role --role-name "$ROLE" \
  --assume-role-policy-document file://"$TMP/preview-instance-trust.json"
aws iam put-role-policy --role-name "$ROLE" --policy-name preview-s3-read \
  --policy-document file://"$TMP/preview-instance-policy.json"
aws iam create-instance-profile --instance-profile-name "$ROLE"
aws iam add-role-to-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE"
```

Verify substitution before each `put-role-policy` / `create-role` — `grep __ "$TMP/*.json"` should return nothing. If any `__PLACEHOLDER__` survives, halt; don't ship a literal placeholder to IAM.

### 7. CI role (OIDC)

Two sub-cases — GitHub Actions or CircleCI. Pick the one matching what step 1 detected.

**GitHub OIDC provider (per account, idempotent):**

```bash
aws iam list-open-id-connect-providers \
  --query 'OpenIDConnectProviderList[?contains(Arn, `token.actions.githubusercontent.com`)]'
```

If empty:

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

**CI role:** ask the user for the GitHub `org/repo` (default to `gh repo view --json nameWithOwner -q .nameWithOwner`). Render the trust + policy from the templates in `$TMPL` — do **not** write the JSON from memory or copy it out of the README. The CI policy is what governs whether `deploy.sh` works; any drift here (e.g. dropping `ec2:DescribeInstanceTypeOfferings`) shows up as a runtime IAM denial.

```bash
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REPO="${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"

sed -e "s|__ACCOUNT_ID__|${ACCOUNT_ID}|g" \
    -e "s|__REPO__|${REPO}|g" \
  "$TMPL/previewuse-ci-trust-github.json" > "$TMP/previewuse-ci-trust.json"

sed -e "s|__ACCOUNT_ID__|${ACCOUNT_ID}|g" \
    -e "s|__AWS_REGION__|${AWS_REGION}|g" \
    -e "s|__PREVIEW_IAM_PROFILE__|${PREVIEW_IAM_PROFILE:-preview}|g" \
    -e "s|__BUCKET__|${PREVIEW_S3_BUCKET}|g" \
    -e "s|__HOSTED_ZONE_ID__|${HOSTED_ZONE_ID}|g" \
  "$TMPL/previewuse-ci-policy.json" > "$TMP/previewuse-ci-policy.json"

grep -l '__' "$TMP"/previewuse-ci-*.json && { echo "unsubstituted placeholders"; exit 1; }

aws iam create-role --role-name previewuse-ci \
  --assume-role-policy-document file://"$TMP/previewuse-ci-trust.json"
aws iam put-role-policy --role-name previewuse-ci --policy-name previewuse \
  --policy-document file://"$TMP/previewuse-ci-policy.json"
```

Tighten the `sub` condition to `repo:<org>/<repo>:*` initially (the template default); mention they can tighten further to `:pull_request` later.

If `previewuse-ci` already exists, diff the existing trust + policy against the rendered ones (`aws iam get-role` / `aws iam get-role-policy`). If they differ, surface the diff and ask before `update-assume-role-policy` / `put-role-policy`. Don't replace silently.

Capture the role ARN: `arn:aws:iam::<account>:role/previewuse-ci`.

**CircleCI variant:** ask for the org UUID (Org Settings → Overview) and project UUID. Use `previewuse-ci-trust-circleci.json` from `$TMPL`, substituting `__ACCOUNT_ID__`, `__CIRCLE_ORG_ID__`, `__CIRCLE_PROJECT_ID__`. Same `previewuse-ci-policy.json` as GitHub. Set the CircleCI context variables in step 8 instead of GitHub secrets.

### 8. CI secrets

Determine which secrets the workflow needs by reading `.github/workflows/preview.yml` (or the CircleCI config) — every name listed under `env:` that comes from `${{ secrets.* }}`. Cross-check against `PREVIEW_FORWARD_ENV` in `preview.config.sh`.

The fixed set:
- `PREVIEW_SSH_PRIVATE_KEY` — base64 from step 4.
- `AWS_ROLE_ARN` (GitHub) or `AWS_ROLE_TO_ASSUME` (CircleCI context) — from step 7. Confirm the exact name the workflow expects.

The variable set: every name in `PREVIEW_FORWARD_ENV`. For each, check if it's already a GitHub secret (`gh secret list -R <repo> --json name -q '.[].name'`). For missing ones, ask the user for the value via `AskUserQuestion` — **one** batch with all the names; don't ping them per secret. If a value is a real production secret they'd rather paste themselves, that's fine — note it and skip.

If `gh` is authed:

```bash
gh secret set PREVIEW_SSH_PRIVATE_KEY -R "$REPO" --body "$(base64 < ~/.ssh/$KEY_NAME)"
gh secret set AWS_ROLE_ARN -R "$REPO" --body "$ROLE_ARN"
# for each forwarded var
gh secret set "$NAME" -R "$REPO" --body "$VALUE"
```

Always pipe `--body` from a variable or `--body-file`, never inline a value the user pasted (avoids leaking through shell history).

If `gh` isn't authed, print a checklist of names + how to obtain each value (base64 the key, paste the ARN, etc.) and stop. Don't print the values themselves.

### 9. Summary

Print a short recap:
- What was created vs already existed.
- The CI role ARN and how to verify (`aws sts assume-role-with-web-identity` isn't easy to test directly — easier to push a branch).
- Next action: push a branch with the `deploy-preview` label and watch CI.
- Reminder: set a CloudWatch billing alarm. Link to the Cost section of `README.md`.

Update `PREVIEW_SETUP.md` (if `configure-preview-deploy` left one) to mark items done, or delete the file if everything is provisioned.

## Things to avoid

- **Don't create the Route53 hosted zone.** Subdomain delegation usually needs NS records at the registrar — automating it leads to dangling zones the user can't reach.
- **Don't write JSON policy files into the repo.** Use `mktemp -d` so policy files don't get committed.
- **Don't widen or rewrite the IAM policies.** Render them from the JSON templates in `.claude/skills/provision-preview-aws/templates/` by substituting placeholders only. Don't paraphrase the JSON, drop statements, or swap scoped resources for `"*"` — `deploy.sh` depends on the exact action set (e.g. `ec2:DescribeInstanceTypeOfferings`), and the resource scoping is the security model.
- **Don't run `aws configure`** or write to `~/.aws/credentials`. If auth is missing, ask the user to set it up.
- **Don't store the SSH private key in the repo.** `~/.ssh/<key-name>` only.
- **Don't echo secret values.** `gh secret set --body "$VAR"` is fine; printing `$VAR` to the console is not.
- **Don't run this for production-adjacent AWS accounts** without surfacing the security model section of `README.md` first. Preview instances are public; the user should know.
