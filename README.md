# previewuse

Per-branch preview environments for any Docker Compose project.

On each feature branch, CI spins up (or reuses) an EC2 instance, points DNS at it, runs `docker compose up`, and comments the preview URLs on the PR. Caddy terminates TLS via Let's Encrypt. When the PR closes, the instance and DNS records are torn down.

## Why preview deployments?

A preview deployment is a publicly accessible version of your app for every git branch. Add a label like `deploy-preview` to a branch and you get a URL (like `mybranch.preview.example.com`) running a fully functional app, similar to your local environment.

- **Validate changes directly.** Instead of going deep on code review, you can play around with the change in a live environment and see its side effects for yourself.
- **Verify the work of background agents.** When an agent opens a branch, spin up a preview to confirm it actually works end to end.
- **Seed realistic test data.** Bring your own setup scripts so accounts and test data are provisioned automatically — no setting things up from scratch in each preview.
- **Share with anyone.** The URL is publicly accessible, so teammates, designers, or stakeholders can try the change without checking anything out locally.

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
