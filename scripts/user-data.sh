#!/bin/bash
# EC2 user-data script: installs Docker on Amazon Linux 2023.
# Runs once on first boot. Works on both arm64 and x86_64 instances.

set -euo pipefail

dnf update -y
dnf install -y docker aws-cli tar gzip

case "$(uname -m)" in
  aarch64) BUILDX_ARCH=arm64;  COMPOSE_ARCH=aarch64 ;;
  x86_64)  BUILDX_ARCH=amd64;  COMPOSE_ARCH=x86_64  ;;
  *) echo "Unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

# Amazon's docker package ships an old buildx + no compose plugin.
# Install latest plugins from GitHub.
PLUGIN_DIR=/usr/local/lib/docker/cli-plugins
mkdir -p "$PLUGIN_DIR"

BUILDX_VERSION="v0.31.1"
curl -fSL "https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-${BUILDX_ARCH}" \
  -o "$PLUGIN_DIR/docker-buildx"
chmod +x "$PLUGIN_DIR/docker-buildx"

curl -fSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${COMPOSE_ARCH}" \
  -o "$PLUGIN_DIR/docker-compose"
chmod +x "$PLUGIN_DIR/docker-compose"

systemctl enable docker
systemctl start docker

# Allow ec2-user to run docker without sudo
usermod -aG docker ec2-user
