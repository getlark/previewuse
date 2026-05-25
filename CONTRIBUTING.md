# Contributing to previewuse

Thanks for the interest. previewuse is intentionally small — a handful of shell scripts plus example config — and we want to keep it that way. Most changes that land here are real-world fixes from people running it in CI.

## Before you open a PR

- **Run [shellcheck](https://www.shellcheck.net/) on any script you touch.** `shellcheck scripts/*.sh` should be clean. The scripts use `set -euo pipefail` and several `${VAR:?...}` guards — please match the existing patterns.
- **Test against a real AWS account.** Unit tests for a shell script that calls `aws ec2 run-instances` aren't worth much. If you're changing deploy/teardown behavior, please verify against a real (cheap, throwaway) EC2 launch and include the relevant `==> ...` log lines from your run in the PR description.
- **Keep the dependency surface flat.** The current set is `aws`, `jq`, `curl`, `git`, `tar`, `base64`, `ssh` — all preinstalled on `ubuntu-latest`. Don't add new required tools without a strong reason.
- **Don't add new required config.** Adding optional `PREVIEW_*` env vars is fine; making existing setups break on upgrade is not. If you need to change a default, gate it behind a new opt-in variable.

If you're not sure whether something fits, please open an issue first to talk through it.

## Reporting bugs

Use the bug report template. The most useful bug reports include:

- The branch slug and PR number (if any).
- The full output from `deploy.sh` / `teardown.sh` (redact secrets).
- The relevant CI provider + runner OS.
- Your `preview.config.sh` with secrets stripped.
