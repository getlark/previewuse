# previewuse

Per-branch preview environments for any Docker Compose project.

When CI runs on a feature branch, `deploy.sh`:

1. Launches an EC2 instance (or reuses the existing one for this branch).
2. Upserts Route53 A records for each configured host onto the instance.
3. Bundles your repo to S3, pulls it on the instance, and runs `docker compose up`.
4. Optionally posts the preview URLs back to the PR.

When the PR closes, `teardown.sh` terminates the instance and removes the DNS records.

Caddy on the instance terminates TLS for each host using Let's Encrypt, so you get clean HTTPS URLs with no extra setup.

## Quickstart

From the root of your existing repo:

```bash
curl -fsSL https://raw.githubusercontent.com/getlark/previewuse/main/install.sh | bash
```

This drops the scripts, compose file, example configs, and the `configure-preview-deploy` Claude Code skill into the current directory (prompting before overwriting). By default the installer fetches the [latest release](https://github.com/getlark/previewuse/releases) — pass `--ref <tag>` to pin a specific version (e.g. `--ref 0.1.0`), `--ref main` to track the development branch, `--dry-run` to preview, or `--yes` to overwrite without prompting.

Then use your coding agent to run `/configure-preview-deploy` instead of editing by hand — the skill walks through the config and reuses signals from your repo (compose services, env vars, etc).

Then wire it into CI — see [`circleci.example.yml`](circleci.example.yml) or [`github-actions.example.yml`](github-actions.example.yml).

If you prefer to edit it by hand:

```
# 1. Rename the examples
mv preview.config.example.sh preview.config.sh
mv Caddyfile.example Caddyfile

# 2. Edit preview.config.sh, docker-compose.preview.yml, and Caddyfile for your app.
```

### GitHub token (optional)

If `GITHUB_TOKEN` is set, `deploy.sh`:

1. Refuses to deploy unless an open PR exists for the branch.
2. Refuses to deploy unless that PR carries `PREVIEW_PR_LABEL` (default `deploy-preview`). Set `PREVIEW_PR_LABEL=""` to disable.
3. Posts/updates a sticky comment with the preview URLs.

The token needs `pull-requests: write` (GitHub Actions) or a classic PAT with `repo` scope (CircleCI). The default `${{ secrets.GITHUB_TOKEN }}` in Actions works as long as the workflow declares `permissions: pull-requests: write`.

If `GITHUB_TOKEN` is unset, the label gate is skipped and every branch run deploys.

## AWS prerequisites

You need these once per AWS account / domain. The recommended path is **GitHub OIDC** — no static AWS keys in CI.

### 1. Route53 hosted zone

A hosted zone for your preview subdomain (e.g. `preview.example.com`) must already exist. The scripts only create/delete records inside it — they never touch the zone itself.

If your apex domain (`example.com`) lives elsewhere, delegate the `preview.` subdomain to this zone via NS records at your registrar.

### 2. S3 bucket

```bash
aws s3api create-bucket --bucket my-preview-artifacts --region us-east-1
aws s3api put-public-access-block --bucket my-preview-artifacts \
  --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
aws s3api put-bucket-encryption --bucket my-preview-artifacts \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
```

Apply a lifecycle rule so bundles + `.env` files don't accumulate (teardown removes them on PR close, but a failed CI job can leave orphans):

```json
{
  "Rules": [{
    "ID": "expire-preview-artifacts",
    "Filter": { "Prefix": "preview/" },
    "Status": "Enabled",
    "Expiration": { "Days": 7 }
  }]
}
```

> **Note.** `.env` files written to this bucket contain every secret listed in `PREVIEW_FORWARD_ENV`. Bucket encryption + Block Public Access are mandatory, not optional. See [Security model](#security-model).

### 3. EC2 key pair + SSH private key in CI

```bash
aws ec2 create-key-pair --key-name preview-key --region us-east-1 \
  --query 'KeyMaterial' --output text > ~/.ssh/preview_key
chmod 600 ~/.ssh/preview_key
base64 -i ~/.ssh/preview_key | pbcopy   # paste into PREVIEW_SSH_PRIVATE_KEY secret
```

Linux: drop the `-i` (`base64 ~/.ssh/preview_key`).

### 4. Security group

```bash
aws ec2 create-security-group --group-name preview-sg \
  --description "previewuse instances" --region us-east-1
SG=$(aws ec2 describe-security-groups --group-names preview-sg \
  --query 'SecurityGroups[0].GroupId' --output text --region us-east-1)
for port in 22 80 443; do
  aws ec2 authorize-security-group-ingress --group-id "$SG" \
    --protocol tcp --port "$port" --cidr 0.0.0.0/0 --region us-east-1
done
```

> **Note.** Ports 22/80/443 are **open to the public internet**. This is required for Let's Encrypt's HTTP-01 challenge and for users to reach the preview. Tighten the SSH ingress to your CI runner's egress range if you can; HTTP/HTTPS must remain open to the world. See [Security model](#security-model).

### 5. EC2 instance profile (the role attached to the instance itself)

The instance only needs to read its own bundle out of S3.

`preview-instance-trust.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
```

`preview-instance-policy.json` (replace `my-preview-artifacts`):

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "ReadOwnBundle",
    "Effect": "Allow",
    "Action": ["s3:GetObject"],
    "Resource": "arn:aws:s3:::my-preview-artifacts/preview/*"
  }]
}
```

```bash
aws iam create-role --role-name preview --assume-role-policy-document file://preview-instance-trust.json
aws iam put-role-policy --role-name preview --policy-name preview-s3-read \
  --policy-document file://preview-instance-policy.json
aws iam create-instance-profile --instance-profile-name preview
aws iam add-role-to-instance-profile --instance-profile-name preview --role-name preview
```

### 6. CI role (GitHub OIDC, recommended)

One-time per AWS account: register GitHub as an OIDC provider.

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

`previewuse-ci-trust.json` (replace `123456789012`, `your-org`, `your-repo`):

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:your-org/your-repo:*"
      }
    }
  }]
}
```

Tighten the `sub` condition (e.g. `repo:your-org/your-repo:ref:refs/heads/main` or `:pull_request`) once you know which workflows run it.

`previewuse-ci-policy.json` (replace `123456789012`, `my-preview-artifacts`, `Z0123456789ABCDEFGHIJ`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EC2Read",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeImages",
        "ec2:DescribeVpcs",
        "ec2:DescribeSubnets",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeInstanceTypeOfferings",
        "ec2:DescribeInstances"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EC2ManagePreviewInstances",
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances",
        "ec2:TerminateInstances",
        "ec2:CreateTags"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": { "aws:RequestedRegion": "us-east-1" }
      }
    },
    {
      "Sid": "PassInstanceProfile",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::123456789012:role/preview",
      "Condition": {
        "StringEquals": { "iam:PassedToService": "ec2.amazonaws.com" }
      }
    },
    {
      "Sid": "S3PreviewBucket",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject"
      ],
      "Resource": "arn:aws:s3:::my-preview-artifacts/preview/*"
    },
    {
      "Sid": "S3List",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::my-preview-artifacts"
    },
    {
      "Sid": "Route53ListZones",
      "Effect": "Allow",
      "Action": "route53:ListHostedZonesByName",
      "Resource": "*"
    },
    {
      "Sid": "Route53WritePreviewZone",
      "Effect": "Allow",
      "Action": "route53:ChangeResourceRecordSets",
      "Resource": "arn:aws:route53:::hostedzone/Z0123456789ABCDEFGHIJ"
    }
  ]
}
```

```bash
aws iam create-role --role-name previewuse-ci --assume-role-policy-document file://previewuse-ci-trust.json
aws iam put-role-policy --role-name previewuse-ci --policy-name previewuse \
  --policy-document file://previewuse-ci-policy.json
```

In your GitHub Actions workflow:

```yaml
permissions:
  id-token: write       # required for OIDC
  contents: read
  pull-requests: write  # so deploy.sh can comment on the PR

- uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: arn:aws:iam::123456789012:role/previewuse-ci
    aws-region: us-east-1
```

### 6b. CI role (CircleCI OIDC)

CircleCI also issues OIDC tokens, so you can use the same role pattern instead of long-lived keys. The `circleci/aws-cli` orb wraps the `sts assume-role-with-web-identity` call — see [`circleci.example.yml`](circleci.example.yml).

One-time per AWS account: register CircleCI as an OIDC provider. Your CircleCI **organization ID** is the UUID under Organization Settings → Overview.

```bash
ORG_ID=<your-circleci-org-uuid>
aws iam create-open-id-connect-provider \
  --url "https://oidc.circleci.com/org/${ORG_ID}" \
  --client-id-list "${ORG_ID}" \
  --thumbprint-list 06b25927c42a721631c1efd9431e648fa62e1e39
```

The thumbprint is a formality — AWS validates the cert against its own trust store for well-known issuers — but the API still requires the field.

`previewuse-ci-trust.json` (replace `123456789012`, `<org-id>`, and `<project-id>`):

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::123456789012:oidc-provider/oidc.circleci.com/org/<org-id>"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "oidc.circleci.com/org/<org-id>:aud": "<org-id>"
      },
      "StringLike": {
        "oidc.circleci.com/org/<org-id>:sub": "org/<org-id>/project/<project-id>/*"
      }
    }
  }]
}
```

> **Note.** Without the `sub` filter, **any** CircleCI job in your org can assume this role. Find the project UUID in CircleCI Project Settings → Overview, or by inspecting the `sub` claim of a real `CIRCLE_OIDC_TOKEN_V2`.

Use the same `previewuse-ci-policy.json` from §6:

```bash
aws iam create-role --role-name previewuse-ci --assume-role-policy-document file://previewuse-ci-trust.json
aws iam put-role-policy --role-name previewuse-ci --policy-name previewuse \
  --policy-document file://previewuse-ci-policy.json
```

In your CircleCI config (the `aws-cli/setup` orb step handles the OIDC exchange):

```yaml
orbs:
  aws-cli: circleci/aws-cli@5.4.0

jobs:
  deploy_preview:
    docker: [{ image: cimg/aws:2025.01 }]
    steps:
      - checkout
      - aws-cli/setup:
          role_arn: arn:aws:iam::123456789012:role/previewuse-ci
      - run: bash scripts/deploy.sh "<< pipeline.git.branch >>"
```

### 6c. Static credentials (fallback)

If OIDC isn't available, create an IAM user with the same policy as above and provision the keys as CI secrets:

```
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
AWS_REGION
```

Rotate them on a schedule — the `previewuse-ci` policy is broad enough that leaked keys can spin up arbitrary EC2 instances.

## Security model

Read this before you point this at a production-adjacent AWS account.

- **Preview instances are publicly reachable.** Ports 80 and 443 must be open to `0.0.0.0/0` for Let's Encrypt to issue certs and for reviewers to load the previews. Anything you ship to a preview is on the public internet. Don't deploy unauthenticated admin panels or paths that read real production data.
- **Port 22 is open to the world by default.** SSH access is gated on the key pair, but you can tighten this further by replacing `0.0.0.0/0` with your CI provider's egress range (GitHub Actions publishes [`meta.actions`](https://api.github.com/meta), CircleCI has [IP ranges](https://circleci.com/docs/ip-ranges/)).
- **Secrets land in S3.** Every name listed in `PREVIEW_FORWARD_ENV` is read from the CI env and written verbatim into `s3://<bucket>/preview/<slug>/.env`. The bucket *must* have Block Public Access on and server-side encryption enabled (see step 2). The instance pulls the file once at deploy time; the S3 lifecycle rule (step 2) handles cleanup of orphans.
- **Preview `.env` lives on disk at `/opt/preview/.env` on the instance.** Anyone with SSH access (i.e. anyone holding `PREVIEW_SSH_PRIVATE_KEY`) can read it. Treat that private key like a production secret.
- **Teardown is best-effort and can fail silently.** `teardown.sh` exits 0 even if the Route53 delete call fails (records will be stale until the next deploy upserts them). It only finds instances by the `preview-branch` tag — if tagging fails at launch, the instance is orphaned and you'll need to terminate it by hand. Set a billing alarm.
- **There is no PR-author gate.** Anyone who can push a branch and apply the `deploy-preview` label can spin up an instance using your forwarded secrets. Restrict who can apply the label (GitHub Actions: `if: github.event.pull_request.head.repo.full_name == github.repository` to block forks).

## Cost

Each preview is a separate EC2 instance and runs until teardown.

- **Default**: `t4g.medium` on-demand in `us-east-1` is roughly **$0.034/hr** (~$25/month per always-on instance) plus 16 GB `gp3` (~$1.30/month) plus public IP (~$3.60/month while attached).
- **Data transfer out** is **$0.09/GB** above 100 GB/month per AWS account.
- **Route53** hosted zone is $0.50/month; record changes are effectively free at this volume.
- **S3** is negligible (a few MB per preview), but only if you set the lifecycle rule.

Set a CloudWatch billing alarm. A stuck CI job that never reaches teardown, or a teardown that fails, will leave an instance running. Set up [auto-stop](https://docs.aws.amazon.com/solutions/latest/instance-scheduler-on-aws/solution-overview.html) or a scheduled lambda to terminate `preview-branch`-tagged instances older than N hours if this is a real concern.

## Configuration

All settings live in `preview.config.sh` (sourced by both scripts) or as environment variables — see [`preview.config.example.sh`](preview.config.example.sh) for the full list.

The key settings:

| Setting | Purpose |
| --- | --- |
| `PREVIEW_DOMAIN` | Base DNS zone (must match a Route53 hosted zone). |
| `PREVIEW_HOSTS` | Array of `VAR=__SLUG__.template` entries. Each becomes a DNS record and is written into the generated `.env`. |
| `PREVIEW_FORWARD_ENV` | Names of CI-provided secrets to copy into the preview's `.env`. |
| `PREVIEW_HEALTH_CHECK_CMD` | Optional command (run on the instance) that gates post-deploy steps. |
| `PREVIEW_POST_DEPLOY_CMD` | Optional command for migrations/seeders. |
| `PREVIEW_PR_LABEL` | Required PR label to gate deploys. Set empty to deploy every branch. |

## How hosts work

For a branch `feat/new-checkout`, the slug is `feat-new-checkout` and:

```bash
PREVIEW_HOSTS=(
  "DASHBOARD_HOST=__SLUG__.${PREVIEW_DOMAIN}"
  "API_HOST=api.__SLUG__.${PREVIEW_DOMAIN}"
)
```

produces:

- A record `feat-new-checkout.preview.example.com` → instance IP
- A record `api.feat-new-checkout.preview.example.com` → instance IP
- `.env` contains `DASHBOARD_HOST=feat-new-checkout.preview.example.com` and `API_HOST=api.feat-new-checkout.preview.example.com`

Your `Caddyfile` reads those env vars and routes each host to the right compose service:

```caddy
{$DASHBOARD_HOST} { reverse_proxy dashboard:80 }
{$API_HOST}       { reverse_proxy api:8000 }
```

## Troubleshooting

- **DNS not propagating** — TTL is 60s but cached resolvers may take a few minutes. Use `dig +short <host> @1.1.1.1` to bypass. Try setting your DNS to [Cloudflare](https://one.one.one.one/dns/) or [Google DNS](https://developers.google.com/speed/public-dns/docs/using).
- **Caddy 502s** — usually means the upstream service isn't healthy yet. SSH in (`ssh -i key ec2-user@<ip>`) and `sudo docker compose logs -f`.
- **TLS cert fails to issue** — the host must be publicly resolvable to the EC2 IP before Caddy can complete the ACME challenge. Wait a minute and `sudo docker compose restart caddy`.

## License

MIT.
