---
name: Bug report
about: Something broke while running deploy.sh or teardown.sh
title: ''
labels: bug
assignees: ''
---

**What happened**

A clear description of what went wrong.

**What you expected**

What you thought should happen instead.

**Environment**

- previewuse commit: <!-- git rev-parse HEAD in the previewuse files you copied -->
- CI provider: <!-- GitHub Actions / CircleCI / running locally -->
- Runner OS: <!-- ubuntu-22.04, macos-14, etc. -->
- AWS region:
- AWS CLI version: <!-- `aws --version` -->

**`preview.config.sh`** (redact secrets)

```bash
# paste the relevant lines
```

**Full output**

The `==> ...` log lines from the failing script. Redact any IPs, hostnames, or values you'd rather not share publicly.

```
# paste here
```

**Anything else?**

Related PRs, links, screenshots, weird stuff in the AWS console, etc.
