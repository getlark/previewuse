#!/usr/bin/env bash
set -euo pipefail

#
# Tear down a feature-branch preview environment.
#
# Usage:
#   ./scripts/teardown.sh <branch-name>
#
# Configuration is loaded from ./preview.config.sh (or $PREVIEW_CONFIG_FILE),
# or from environment variables. See preview.config.example.sh.
#

CONFIG_FILE="${PREVIEW_CONFIG_FILE:-./preview.config.sh}"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

BRANCH="${1:?Usage: teardown.sh <branch-name>}"

: "${PREVIEW_DOMAIN:?PREVIEW_DOMAIN is required}"
: "${PREVIEW_S3_BUCKET:?PREVIEW_S3_BUCKET is required}"

AWS_REGION="${AWS_REGION:-us-east-1}"

if [ -z "${PREVIEW_HOSTS+x}" ]; then
  PREVIEW_HOSTS=("DASHBOARD_HOST=__SLUG__.${PREVIEW_DOMAIN}")
fi

SLUG=$(echo "$BRANCH" | sed 's/[^a-zA-Z0-9]/-/g' | tr '[:upper:]' '[:lower:]' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | head -c 40)

declare -a HOST_NAMES=()
for entry in "${PREVIEW_HOSTS[@]}"; do
  template="${entry#*=}"
  HOST_NAMES+=("${template//__SLUG__/$SLUG}")
done

echo "==> Tearing down preview for branch: $BRANCH (slug: $SLUG)"

# ---------------------------------------------------------------------------
# Find the instance
# ---------------------------------------------------------------------------
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:preview-branch,Values=${SLUG}" "Name=instance-state-name,Values=running,pending,stopped" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text --region "$AWS_REGION" 2>/dev/null || echo "None")

PUBLIC_IP=""
if [ "$INSTANCE_ID" != "None" ] && [ -n "$INSTANCE_ID" ]; then
  PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text --region "$AWS_REGION" 2>/dev/null || echo "")

  echo "==> Terminating instance: $INSTANCE_ID"
  aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION" > /dev/null
else
  echo "    No running instance found for slug: $SLUG"
fi

# ---------------------------------------------------------------------------
# Delete Route53 DNS records
# ---------------------------------------------------------------------------
if [ -z "${PREVIEW_HOSTED_ZONE_ID:-}" ]; then
  HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
    --dns-name "$PREVIEW_DOMAIN" \
    --query 'HostedZones[0].Id' --output text --region "$AWS_REGION" 2>/dev/null | sed 's|/hostedzone/||')
else
  HOSTED_ZONE_ID="$PREVIEW_HOSTED_ZONE_ID"
fi

if [ -n "$HOSTED_ZONE_ID" ] && [ "$HOSTED_ZONE_ID" != "None" ] && [ -n "$PUBLIC_IP" ]; then
  echo "==> Deleting DNS records..."
  DNS_CHANGES=""
  for host in "${HOST_NAMES[@]}"; do
    [ -n "$DNS_CHANGES" ] && DNS_CHANGES="${DNS_CHANGES},"
    DNS_CHANGES="${DNS_CHANGES}{\"Action\":\"DELETE\",\"ResourceRecordSet\":{\"Name\":\"${host}\",\"Type\":\"A\",\"TTL\":60,\"ResourceRecords\":[{\"Value\":\"${PUBLIC_IP}\"}]}}"
  done
  aws route53 change-resource-record-sets \
    --hosted-zone-id "$HOSTED_ZONE_ID" \
    --change-batch "{\"Changes\":[${DNS_CHANGES}]}" \
    --region "$AWS_REGION" > /dev/null 2>&1 || echo "    WARNING: Could not delete DNS records (may already be gone)"
else
  echo "    Skipping DNS cleanup (no hosted zone or no IP found)"
fi

# ---------------------------------------------------------------------------
# Clean up S3 artifacts
# ---------------------------------------------------------------------------
echo "==> Cleaning up S3 artifacts..."
aws s3 rm "s3://${PREVIEW_S3_BUCKET}/preview/${SLUG}/" --recursive --region "$AWS_REGION" > /dev/null 2>&1 || true

echo ""
echo "==> Preview environment torn down for: $BRANCH"
