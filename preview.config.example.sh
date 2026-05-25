# shellcheck shell=bash
#
# previewuse configuration.
#
# Copy this file to `preview.config.sh` at the root of your repo and fill in the
# values for your environment. The deploy/teardown scripts will `source` it.
# You can also set any of these values via environment variables in your CI
# instead.
#

# ---------- Required ----------

# Base DNS zone for preview hosts. A Route53 hosted zone with this name must
# already exist; deploy.sh creates A records inside it.
export PREVIEW_DOMAIN="preview.example.com"

# EC2 key pair name to attach to launched instances (must exist in AWS_REGION).
export PREVIEW_KEY_NAME="preview-key"

# S3 bucket where the source bundle and generated .env are uploaded for the
# instance to pull. Must exist; the EC2 instance profile needs read access.
export PREVIEW_S3_BUCKET="my-preview-artifacts"

# ---------- Hosts ----------
#
# Each entry declares a host the preview will serve, in the form
# "ENV_VAR_NAME=__SLUG__.subdomain.template". `__SLUG__` is replaced with the
# branch slug. The host is added to DNS, and ENV_VAR_NAME is written into the
# generated .env so your docker-compose file can reference it (and your
# Caddyfile can route to the right service).
#
PREVIEW_HOSTS=(
  "DASHBOARD_HOST=__SLUG__.${PREVIEW_DOMAIN}"
  "API_HOST=api.__SLUG__.${PREVIEW_DOMAIN}"
)

# ---------- Env vars to forward into the preview ----------
#
# Names of variables that must be present in the deploy environment (e.g. CI
# secrets) and should be copied into the .env file the instance uses.
#
PREVIEW_FORWARD_ENV=(
  # DATABASE_PASSWORD
  # STRIPE_SECRET_KEY
  # OPENAI_API_KEY
)

# ---------- AWS ----------

export AWS_REGION="us-east-1"
export PREVIEW_INSTANCE_TYPE="t4g.medium"   # arm64; use e.g. t3.medium for x86
export PREVIEW_ARCH="arm64"                 # arm64 | x86_64
export PREVIEW_IAM_PROFILE="preview"        # instance profile name
export PREVIEW_SECURITY_GROUP_NAME="preview-sg"

# Optional: pin specific networking (otherwise default VPC + first public subnet)
# export PREVIEW_VPC_ID="vpc-xxx"
# export PREVIEW_SUBNET_ID="subnet-xxx"
# export PREVIEW_SECURITY_GROUP_ID="sg-xxx"
# export PREVIEW_HOSTED_ZONE_ID="Zxxx"

# ---------- Deploy-time hooks ----------

# Compose file deployed on the instance (relative to the bundle root).
export PREVIEW_COMPOSE_FILE="docker-compose.preview.yml"

# Health check to gate post-deploy steps. Runs inside the EC2 instance with the
# compose project context. Empty disables the check.
export PREVIEW_HEALTH_CHECK_CMD=""
# Example:
# export PREVIEW_HEALTH_CHECK_CMD="sudo docker compose -f ${PREVIEW_COMPOSE_FILE} exec -T api curl -fs http://localhost:8000/health"

# Optional command to run after services come up (migrations, seeders, etc.).
export PREVIEW_POST_DEPLOY_CMD=""
# Example:
# export PREVIEW_POST_DEPLOY_CMD="sudo docker compose -f ${PREVIEW_COMPOSE_FILE} exec -T api alembic upgrade head"

# ---------- GitHub integration ----------
#
# If GITHUB_TOKEN is set in the deploy environment, deploy.sh will:
#  - require an open PR for the branch
#  - require the PR to carry this label (set empty to disable label gating)
#  - post/update a comment on the PR with the preview URLs
#
export PREVIEW_PR_LABEL="deploy-preview"

# ---------- Bundling ----------
#
# By default the deploy script bundles every file tracked by git. Override to
# pin to specific paths (faster for monorepos).
#
# PREVIEW_BUNDLE_PATHS=(
#   docker-compose.preview.yml
#   Caddyfile
#   apps/api/
#   apps/web/
# )
