# previewuse

Per-branch preview environments for any Docker Compose project.

On each feature branch, CI spins up (or reuses) an EC2 instance, points DNS at it, runs `docker compose up`, and comments the preview URLs on the PR. Caddy terminates TLS via Let's Encrypt. When the PR closes, the instance and DNS records are torn down.

## Quickstart

From the root of your repo:

```bash
curl -fsSL https://raw.githubusercontent.com/getlark/previewuse/main/install.sh | bash
```

This drops the scripts, compose file, example configs, and Claude Code skills into your repo.

Then point your coding agent at the two shipped skills, in order:

1. **`/configure-preview-deploy`** — fills in `preview.config.sh`, `Caddyfile`, `docker-compose.preview.yml`, and the CI workflow using signals from your repo.
2. **`/provision-preview-aws`** — creates the AWS resources (S3 bucket, EC2 key pair, security group, IAM roles, OIDC provider) and pushes CI secrets via `gh secret set`. Confirms each action before running it.

That's it — open a PR with the `deploy-preview` label and CI will post the preview URLs.

## License

MIT.
