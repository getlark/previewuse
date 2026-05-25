#!/usr/bin/env bash
set -euo pipefail

#
# Deploy a feature-branch preview environment to a single EC2 instance.
#
# Usage:
#   ./scripts/deploy.sh <branch-name>
#
# Configuration is loaded from ./preview.config.sh (or $PREVIEW_CONFIG_FILE),
# or from environment variables. See preview.config.example.sh for all
# available settings.
#
# Required (no defaults):
#   PREVIEW_DOMAIN              - base DNS zone, e.g. "preview.example.com"
#   PREVIEW_KEY_NAME            - EC2 key pair name for SSH access
#   PREVIEW_SSH_PRIVATE_KEY     - base64-encoded contents of the SSH private key
#   PREVIEW_S3_BUCKET           - S3 bucket for the source bundle + .env
#

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------
CONFIG_FILE="${PREVIEW_CONFIG_FILE:-./preview.config.sh}"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

BRANCH="${1:?Usage: deploy.sh <branch-name>}"

# ---------------------------------------------------------------------------
# Required configuration
# ---------------------------------------------------------------------------
: "${PREVIEW_DOMAIN:?PREVIEW_DOMAIN is required (e.g. preview.example.com)}"
: "${PREVIEW_KEY_NAME:?PREVIEW_KEY_NAME is required (EC2 key pair name)}"
: "${PREVIEW_SSH_PRIVATE_KEY:?PREVIEW_SSH_PRIVATE_KEY is required (base64 of SSH private key)}"
: "${PREVIEW_S3_BUCKET:?PREVIEW_S3_BUCKET is required (S3 bucket for bundle + .env)}"

# ---------------------------------------------------------------------------
# Optional configuration with defaults
# ---------------------------------------------------------------------------
AWS_REGION="${AWS_REGION:-us-east-1}"
INSTANCE_TYPE="${PREVIEW_INSTANCE_TYPE:-t4g.medium}"
ARCH="${PREVIEW_ARCH:-arm64}"   # arm64 | x86_64
IAM_PROFILE="${PREVIEW_IAM_PROFILE:-preview}"
SECURITY_GROUP_NAME="${PREVIEW_SECURITY_GROUP_NAME:-preview-sg}"
COMPOSE_FILE="${PREVIEW_COMPOSE_FILE:-docker-compose.preview.yml}"
USER_DATA_FILE="${PREVIEW_USER_DATA_FILE:-scripts/user-data.sh}"
PR_LABEL="${PREVIEW_PR_LABEL-deploy-preview}"
HEALTH_CHECK_CMD="${PREVIEW_HEALTH_CHECK_CMD:-}"
POST_DEPLOY_CMD="${PREVIEW_POST_DEPLOY_CMD:-}"

# PREVIEW_HOSTS: array of "VAR_NAME=__SLUG__.subdomain.template" pairs.
# Defaults to a single dashboard host if unset.
if [ -z "${PREVIEW_HOSTS+x}" ]; then
  PREVIEW_HOSTS=("DASHBOARD_HOST=__SLUG__.${PREVIEW_DOMAIN}")
fi

# PREVIEW_FORWARD_ENV: names of environment variables to copy into the
# generated .env file. The values are read from the current environment.
[ -z "${PREVIEW_FORWARD_ENV+x}" ] && declare -a PREVIEW_FORWARD_ENV=()

# PREVIEW_BUNDLE_PATHS: optional array of paths to tar. Defaults to all files
# tracked by git.
[ -z "${PREVIEW_BUNDLE_PATHS+x}" ] && declare -a PREVIEW_BUNDLE_PATHS=()

# ---------------------------------------------------------------------------
# Compute slug + hosts
# ---------------------------------------------------------------------------
SLUG=$(echo "$BRANCH" | sed 's/[^a-zA-Z0-9]/-/g' | tr '[:upper:]' '[:lower:]' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | head -c 40)

# Temp files that hold secrets (SSH key, generated .env) or large bundles.
# Install the EXIT trap up front so any failure path scrubs them.
BUNDLE_PATH="/tmp/preview-${SLUG}-bundle.tar.gz"
ENV_PATH="/tmp/preview-${SLUG}.env"
SSH_KEY_PATH="/tmp/preview-ssh-key-${SLUG}"
trap 'rm -f "$BUNDLE_PATH" "$ENV_PATH" "$SSH_KEY_PATH"' EXIT

declare -a HOST_NAMES=()
declare -a HOST_LINES=()  # KEY=VALUE lines for .env
PRIMARY_HOST=""
for entry in "${PREVIEW_HOSTS[@]}"; do
  var_name="${entry%%=*}"
  template="${entry#*=}"
  host_value="${template//__SLUG__/$SLUG}"
  HOST_NAMES+=("$host_value")
  HOST_LINES+=("${var_name}=${host_value}")
  [ -z "$PRIMARY_HOST" ] && PRIMARY_HOST="$host_value"
done

echo "==> Deploying preview for branch: $BRANCH (slug: $SLUG)"
for host in "${HOST_NAMES[@]}"; do
  echo "    https://${host}"
done

# ---------------------------------------------------------------------------
# Optional: gate deploy on a "deploy-preview" PR label
# ---------------------------------------------------------------------------
PR_NUMBER=""
GITHUB_REPO=""
GITHUB_API="https://api.github.com"
AUTH_HEADER=""

if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "$PR_LABEL" ]; then
  GITHUB_REPO=$(git remote get-url origin 2>/dev/null \
    | sed -E 's#.*github\.com[:/]##' | sed 's/\.git$//' || echo "")

  if [ -n "$GITHUB_REPO" ]; then
    AUTH_HEADER="Authorization: token ${GITHUB_TOKEN}"

    echo "    Looking up PRs for ${GITHUB_REPO}..."
    API_URL="${GITHUB_API}/repos/${GITHUB_REPO}/pulls?state=open&per_page=100"
    API_RESPONSE=$(curl -s -w "\n%{http_code}" -H "$AUTH_HEADER" "$API_URL")
    HTTP_CODE=$(echo "$API_RESPONSE" | tail -1)
    API_BODY=$(echo "$API_RESPONSE" | sed '$d')

    if [ "$HTTP_CODE" != "200" ]; then
      echo "ERROR: GitHub API returned HTTP ${HTTP_CODE}; cannot verify \"${PR_LABEL}\" label, refusing to deploy"
      exit 1
    fi

    PR_JSON=$(echo "$API_BODY" | jq -r --arg branch "$BRANCH" '[.[] | select(.head.ref == $branch)][0] // empty' 2>/dev/null || echo "")

    if [ -n "$PR_JSON" ]; then
      HAS_LABEL=$(echo "$PR_JSON" | jq -r --arg label "$PR_LABEL" '[.labels[].name] | any(. == $label)' 2>/dev/null || echo "false")

      if [ "$HAS_LABEL" != "true" ]; then
        echo "==> PR does not have the \"${PR_LABEL}\" label, skipping deploy"
        exit 0
      fi
      echo "    PR has \"${PR_LABEL}\" label, proceeding"
      PR_NUMBER=$(echo "$PR_JSON" | jq -r '.number')
    else
      echo "    No open PR found for branch '${BRANCH}', skipping deploy"
      exit 0
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Resolve security group
# ---------------------------------------------------------------------------
if [ -z "${PREVIEW_SECURITY_GROUP_ID:-}" ]; then
  SECURITY_GROUP=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${SECURITY_GROUP_NAME}" \
    --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION")
  if [ "$SECURITY_GROUP" = "None" ] || [ -z "$SECURITY_GROUP" ]; then
    echo "ERROR: Security group '${SECURITY_GROUP_NAME}' not found. Create it first (see README)."
    exit 1
  fi
else
  SECURITY_GROUP="$PREVIEW_SECURITY_GROUP_ID"
fi

# ---------------------------------------------------------------------------
# Resolve Route53 hosted zone
# ---------------------------------------------------------------------------
if [ -z "${PREVIEW_HOSTED_ZONE_ID:-}" ]; then
  HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
    --dns-name "$PREVIEW_DOMAIN" \
    --query 'HostedZones[0].Id' --output text --region "$AWS_REGION" | sed 's|/hostedzone/||')
  if [ "$HOSTED_ZONE_ID" = "None" ] || [ -z "$HOSTED_ZONE_ID" ]; then
    echo "ERROR: Hosted zone for '${PREVIEW_DOMAIN}' not found."
    exit 1
  fi
else
  HOSTED_ZONE_ID="$PREVIEW_HOSTED_ZONE_ID"
fi

# ---------------------------------------------------------------------------
# Resolve AMI (latest Amazon Linux 2023 for the requested arch)
# ---------------------------------------------------------------------------
AMI_ID=$(aws ec2 describe-images \
  --owners amazon \
  --filters "Name=name,Values=al2023-ami-2023*-${ARCH}" "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text --region "$AWS_REGION")
echo "    AMI: $AMI_ID (${ARCH})"

# ---------------------------------------------------------------------------
# Find or launch EC2 instance
# ---------------------------------------------------------------------------
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:preview-branch,Values=${SLUG}" "Name=instance-state-name,Values=running,pending" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text --region "$AWS_REGION" 2>/dev/null || echo "None")

if [ "$INSTANCE_ID" = "None" ] || [ -z "$INSTANCE_ID" ]; then
  echo "==> Launching new EC2 instance..."

  # Resolve VPC ID
  if [ -n "${PREVIEW_VPC_ID:-}" ]; then
    VPC_ID="$PREVIEW_VPC_ID"
  else
    VPC_ID=$(aws ec2 describe-vpcs \
      --filters "Name=is-default,Values=true" \
      --query 'Vpcs[0].VpcId' --output text --region "$AWS_REGION")
    if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
      echo "ERROR: No default VPC found. Set PREVIEW_VPC_ID."
      exit 1
    fi
  fi

  # Resolve subnet
  if [ -n "${PREVIEW_SUBNET_ID:-}" ]; then
    SUBNET_ID="$PREVIEW_SUBNET_ID"
    AZ=$(aws ec2 describe-subnets --subnet-ids "$SUBNET_ID" \
      --query 'Subnets[0].AvailabilityZone' --output text --region "$AWS_REGION")
    echo "    Using subnet $SUBNET_ID in AZ $AZ (VPC: $VPC_ID)"
  else
    # Find AZs that support the requested instance type
    SUPPORTED_AZS=$(aws ec2 describe-instance-type-offerings \
      --location-type availability-zone \
      --filters "Name=instance-type,Values=${INSTANCE_TYPE}" \
      --query 'InstanceTypeOfferings[].Location' --output text --region "$AWS_REGION")

    SUBNET_ID=""
    for AZ in $SUPPORTED_AZS; do
      SUBNET_ID=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=${VPC_ID}" "Name=availability-zone,Values=${AZ}" "Name=map-public-ip-on-launch,Values=true" \
        --query 'Subnets[0].SubnetId' --output text --region "$AWS_REGION" 2>/dev/null || echo "None")
      if [ "$SUBNET_ID" != "None" ] && [ -n "$SUBNET_ID" ]; then
        echo "    Using subnet $SUBNET_ID in AZ $AZ (VPC: $VPC_ID)"
        break
      fi
    done

    if [ -z "$SUBNET_ID" ] || [ "$SUBNET_ID" = "None" ]; then
      echo "ERROR: No public subnet found in VPC '${VPC_ID}' in an AZ that supports ${INSTANCE_TYPE}"
      echo "       Set PREVIEW_SUBNET_ID to a specific public subnet."
      exit 1
    fi
  fi

  TAG_SPEC="ResourceType=instance,Tags=[{Key=Name,Value=preview-${SLUG}},{Key=preview-branch,Value=${SLUG}}"
  for entry in "${PREVIEW_HOSTS[@]}"; do
    var_name="${entry%%=*}"
    template="${entry#*=}"
    host_value="${template//__SLUG__/$SLUG}"
    tag_key="preview-host-$(echo "$var_name" | tr '[:upper:]_' '[:lower:]-')"
    TAG_SPEC="${TAG_SPEC},{Key=${tag_key},Value=${host_value}}"
  done
  TAG_SPEC="${TAG_SPEC}]"

  INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$PREVIEW_KEY_NAME" \
    --security-group-ids "$SECURITY_GROUP" \
    --subnet-id "$SUBNET_ID" \
    --iam-instance-profile "Name=$IAM_PROFILE" \
    --associate-public-ip-address \
    --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":16,"VolumeType":"gp3"}}]' \
    --tag-specifications "$TAG_SPEC" \
    --user-data "file://${USER_DATA_FILE}" \
    --query 'Instances[0].InstanceId' --output text --region "$AWS_REGION")

  echo "    Instance: $INSTANCE_ID"
  echo "==> Waiting for instance to be running..."
  aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"
else
  echo "==> Reusing existing instance: $INSTANCE_ID"
fi

# ---------------------------------------------------------------------------
# Get public IP
# ---------------------------------------------------------------------------
PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text --region "$AWS_REGION")
echo "    Public IP: $PUBLIC_IP"

# ---------------------------------------------------------------------------
# Update Route53 DNS records
# ---------------------------------------------------------------------------
echo "==> Updating DNS records..."
DNS_CHANGES=""
for host in "${HOST_NAMES[@]}"; do
  [ -n "$DNS_CHANGES" ] && DNS_CHANGES="${DNS_CHANGES},"
  DNS_CHANGES="${DNS_CHANGES}{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"${host}\",\"Type\":\"A\",\"TTL\":60,\"ResourceRecords\":[{\"Value\":\"${PUBLIC_IP}\"}]}}"
done
aws route53 change-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --change-batch "{\"Changes\":[${DNS_CHANGES}]}" \
  --region "$AWS_REGION" > /dev/null

# ---------------------------------------------------------------------------
# Package source code and upload to S3
# ---------------------------------------------------------------------------
echo "==> Packaging source and uploading to S3..."

if [ "${#PREVIEW_BUNDLE_PATHS[@]}" -gt 0 ]; then
  tar czf "$BUNDLE_PATH" "${PREVIEW_BUNDLE_PATHS[@]}"
else
  git ls-files -z | tar --null -czf "$BUNDLE_PATH" -T -
fi

aws s3 cp "$BUNDLE_PATH" "s3://${PREVIEW_S3_BUCKET}/preview/${SLUG}/bundle.tar.gz" --region "$AWS_REGION" > /dev/null

# Generate .env file: host vars + forwarded env vars
: > "$ENV_PATH"
for line in "${HOST_LINES[@]}"; do
  echo "$line" >> "$ENV_PATH"
done
for var_name in "${PREVIEW_FORWARD_ENV[@]}"; do
  printf '%s=%s\n' "$var_name" "${!var_name:-}" >> "$ENV_PATH"
done

aws s3 cp "$ENV_PATH" "s3://${PREVIEW_S3_BUCKET}/preview/${SLUG}/.env" --region "$AWS_REGION" > /dev/null

# ---------------------------------------------------------------------------
# Wait for SSH to be ready
# ---------------------------------------------------------------------------
echo "==> Waiting for SSH..."

echo "$PREVIEW_SSH_PRIVATE_KEY" | base64 -d > "$SSH_KEY_PATH"
chmod 600 "$SSH_KEY_PATH"
SSH_OPTS="-i $SSH_KEY_PATH -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"

for i in $(seq 1 30); do
  if ssh $SSH_OPTS "ec2-user@${PUBLIC_IP}" "echo ready" 2>/dev/null; then
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "ERROR: Timed out waiting for SSH"
    exit 1
  fi
  echo "    Waiting for SSH... (attempt $i/30)"
  sleep 10
done

# ---------------------------------------------------------------------------
# Wait for user-data (Docker install) to finish
# ---------------------------------------------------------------------------
echo "==> Waiting for Docker..."
ssh $SSH_OPTS "ec2-user@${PUBLIC_IP}" "
  for i in \$(seq 1 60); do
    if command -v docker &>/dev/null && sudo docker info &>/dev/null; then
      echo 'Docker is ready'
      exit 0
    fi
    echo 'Waiting for Docker... (attempt '\$i'/60)'
    sleep 5
  done
  echo 'ERROR: Docker not available after timeout'
  exit 1
"

# ---------------------------------------------------------------------------
# Deploy on the instance
# ---------------------------------------------------------------------------
echo "==> Deploying to instance..."
ssh $SSH_OPTS "ec2-user@${PUBLIC_IP}" "
  set -euo pipefail

  sudo mkdir -p /opt/preview && sudo chown ec2-user:ec2-user /opt/preview
  cd /opt/preview

  aws s3 cp 's3://${PREVIEW_S3_BUCKET}/preview/${SLUG}/bundle.tar.gz' bundle.tar.gz --region '${AWS_REGION}'
  aws s3 cp 's3://${PREVIEW_S3_BUCKET}/preview/${SLUG}/.env' .env --region '${AWS_REGION}'

  tar xzf bundle.tar.gz

  sudo docker compose -f '${COMPOSE_FILE}' --env-file .env up -d --build --remove-orphans
"

# Optional health check
if [ -n "$HEALTH_CHECK_CMD" ]; then
  echo "==> Running health check..."
  ssh $SSH_OPTS "ec2-user@${PUBLIC_IP}" "
    cd /opt/preview
    for i in \$(seq 1 30); do
      if ${HEALTH_CHECK_CMD} > /dev/null 2>&1; then
        echo 'Healthy'
        exit 0
      fi
      [ \"\$i\" -eq 30 ] && { echo 'WARNING: health check timed out'; exit 0; }
      sleep 5
    done
  "
fi

# Optional post-deploy hook (e.g. migrations)
if [ -n "$POST_DEPLOY_CMD" ]; then
  echo "==> Running post-deploy command..."
  ssh $SSH_OPTS "ec2-user@${PUBLIC_IP}" "
    set -euo pipefail
    cd /opt/preview
    ${POST_DEPLOY_CMD}
  "
fi

echo ""
echo "==> Preview environment is live!"
for host in "${HOST_NAMES[@]}"; do
  echo "    https://${host}"
done
echo ""

# ---------------------------------------------------------------------------
# Comment on GitHub PR with preview URLs (requires GITHUB_TOKEN + PR_NUMBER)
# ---------------------------------------------------------------------------
if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${PR_NUMBER:-}" ]; then
  (
    echo "==> Posting preview URLs to PR #${PR_NUMBER}..."

    COMMIT_SHA="${CIRCLE_SHA1:-${GITHUB_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")}}"
    COMMENT_MARKER="<!-- preview-deploy -->"

    URLS_TABLE="| Host | URL |"$'\n'"|---|---|"
    for entry in "${PREVIEW_HOSTS[@]}"; do
      var_name="${entry%%=*}"
      template="${entry#*=}"
      host_value="${template//__SLUG__/$SLUG}"
      URLS_TABLE="${URLS_TABLE}"$'\n'"| **${var_name}** | https://${host_value} |"
    done

    COMMENT_BODY="${COMMENT_MARKER}
## Preview Environment

${URLS_TABLE}

_Deployed from commit \`${COMMIT_SHA}\`_"

    JSON_PAYLOAD=$(jq -n --arg body "$COMMENT_BODY" '{body: $body}')

    EXISTING_COMMENT_ID=$(curl -sf -H "$AUTH_HEADER" \
      "${GITHUB_API}/repos/${GITHUB_REPO}/issues/${PR_NUMBER}/comments?per_page=100" \
      | jq -r --arg marker "$COMMENT_MARKER" \
        '[.[] | select(.body | startswith($marker))][0].id // empty')

    if [ -n "$EXISTING_COMMENT_ID" ]; then
      curl -sf -X PATCH -H "$AUTH_HEADER" -H "Content-Type: application/json" \
        -d "$JSON_PAYLOAD" \
        "${GITHUB_API}/repos/${GITHUB_REPO}/issues/comments/${EXISTING_COMMENT_ID}" > /dev/null
      echo "    Updated existing PR comment"
    else
      curl -sf -X POST -H "$AUTH_HEADER" -H "Content-Type: application/json" \
        -d "$JSON_PAYLOAD" \
        "${GITHUB_API}/repos/${GITHUB_REPO}/issues/${PR_NUMBER}/comments" > /dev/null
      echo "    Posted preview URLs to PR"
    fi
  ) || echo "    WARNING: Failed to post preview URL to PR (non-fatal)"
fi
