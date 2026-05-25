---
name: configure-preview-deploy
description: Wire previewuse (per-branch preview environments on EC2) into the current repo. Use when the user asks to "set up preview deploys", "configure previewuse", "add preview environments", "deploy previews per branch", or runs /configure-preview-deploy. Discovers compose services, fills in preview.config.sh, generates Caddyfile + CI workflow, and explains the AWS prerequisites that still need to be set up by hand.
---

# configure-preview-deploy

Wire [previewuse](https://github.com/getlark/previewuse) into the current repo so each feature branch gets its own EC2-hosted preview environment.

## When to use

The user wants per-branch preview environments and is willing to host them on AWS (EC2 + Route53 + S3). Skip if they're looking for managed PaaS-style previews (Vercel, Render, Railway) — previewuse is BYO-cloud.

## What you produce

By the end of the session, the user's repo has:

1. `scripts/deploy.sh`, `scripts/teardown.sh`, `scripts/user-data.sh` — copied verbatim from previewuse.
2. `preview.config.sh` — filled in for their app.
3. `docker-compose.preview.yml` — either generated from scratch or adapted from their existing compose file, with a `caddy` service appended.
4. `Caddyfile` — one block per host pointing at the right service.
5. CI workflow — `.circleci/config.yml` extension or `.github/workflows/preview.yml`.
6. A `PREVIEW_SETUP.md` punch list of the AWS prerequisites the user still needs to provision.

## Workflow

### 1. Sanity check the project

- Confirm the repo has a working `docker-compose.yml` (or similar). If not, ask the user what services they want to preview and stop the skill — previewuse needs a compose setup.
- Read the existing compose file. Note: service names, exposed ports, env vars referenced (`${...}`), and any service that already terminates HTTP (nginx, traefik, caddy). Previewuse adds its own Caddy on :80/:443, so an existing edge proxy needs to be removed from the preview compose file or its ports cleared.

### 2. Drop the scripts in

Copy from the previewuse repo (the user has it cloned at a path they'll tell you, or fetch from GitHub) into the target repo:

```
scripts/deploy.sh
scripts/teardown.sh
scripts/user-data.sh
```

Make them executable (`chmod +x`).

### 3. Gather config values

Ask the user — in **one** `AskUserQuestion` batch — for the values you can't infer:

- **PREVIEW_DOMAIN** — base DNS zone (e.g. `preview.example.com`). Must already be a Route53 hosted zone.
- **PREVIEW_S3_BUCKET** — S3 bucket name for the bundle + `.env`.
- **AWS_REGION** — default `us-east-1`.
- **Arch / instance type** — offer `arm64 / t4g.medium` (cheaper) vs `x86_64 / t3.medium`.

Infer everything else:

- **PREVIEW_HOSTS** — derive from the compose services that expose web ports. Pick a sensible variable name per service (`DASHBOARD_HOST`, `API_HOST`, ...) and propose them. Confirm with the user if there's any ambiguity.
- **PREVIEW_FORWARD_ENV** — read every `${VAR}` reference in the compose file that isn't one of the host vars or a value with a literal default. Those are the secrets to forward. Present the list to the user for confirmation.
- **PREVIEW_HEALTH_CHECK_CMD / PREVIEW_POST_DEPLOY_CMD** — if you spot a `/health` endpoint or a migration command (`alembic`, `prisma migrate deploy`, `rails db:migrate`, `npm run migrate`), suggest one. Otherwise leave empty.

### 4. Write `preview.config.sh`

Use `preview.config.example.sh` from previewuse as the template. Fill in everything gathered above. Don't include settings the user didn't customize — keep the file short.

### 5. Generate `docker-compose.preview.yml`

If the user already has a `docker-compose.yml` suitable for preview, copy it and **add** a Caddy service that publishes :80 and :443. Otherwise build one from their existing dev compose:

- Strip dev-only volumes (source mounts).
- Switch from `build` to pinned images **only** if the user has them pushed somewhere — otherwise keep `build:` so the EC2 instance builds on deploy (this is the previewuse default).
- Ensure every host env var from `PREVIEW_HOSTS` is referenced where appropriate (in `args:` for frontend builds, in service `environment:` for backends).
- Append the Caddy service from `docker-compose.preview.yml` in this repo.

### 6. Generate `Caddyfile`

One block per host:

```caddy
{$DASHBOARD_HOST} {
    reverse_proxy <service>:<port>
}
```

Use the service name and internal port from the compose file. Don't expose those ports in the compose file — Caddy reaches them on the internal network.

### 7. Set up CI

Detect what CI the repo uses:

- `.circleci/config.yml` exists → append the deploy / teardown jobs from `circleci.example.yml`. Don't replace the whole file.
- `.github/workflows/` exists → write `.github/workflows/preview.yml` based on `github-actions.example.yml`.
- Neither → ask the user which CI provider they use and either generate the right file or note that they'll need to adapt one of the examples.

Make sure the CI workflow forwards every variable in `PREVIEW_FORWARD_ENV` from CI secrets — list them explicitly in the `env:` block, don't rely on the deploy script picking them up implicitly.

### 8. Write `PREVIEW_SETUP.md` (punch list)

A short file listing the AWS prerequisites the user still has to do by hand. Use the AWS prerequisites section of previewuse's README verbatim, plus a checklist of CI secrets they need to add. Don't fabricate AWS CLI commands — link to the README section instead.

### 9. Smoke test

Suggest the user push a branch and watch CI. Note: the first deploy is slow (Docker install + image build); subsequent deploys to the same slug reuse the instance.

## Things to avoid

- **Don't** invent AWS settings the user didn't specify (security group IDs, subnet IDs, hosted zone IDs). The deploy script auto-discovers them by name — leave the corresponding env vars unset rather than guessing.
- **Don't** commit secrets into `preview.config.sh`. Only variable *names* go in `PREVIEW_FORWARD_ENV`; values come from CI.
- **Don't** wire previewuse onto `main` deploys. The CI examples filter to non-main / open PRs for a reason: previews are short-lived per-branch infra.
- **Don't** modify the user's existing `docker-compose.yml`. Create a separate `docker-compose.preview.yml`.
- **Don't** edit `scripts/deploy.sh` or `scripts/teardown.sh` to "customize" them. All customization goes through `preview.config.sh`. If you find yourself wanting to edit them, propose a config setting upstream instead.
