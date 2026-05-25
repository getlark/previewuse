<!--
Thanks for the PR! A few quick things before you submit:

1. `shellcheck scripts/*.sh` is clean.
2. If you changed deploy/teardown behavior, you ran it against a real AWS account at least once.
3. You haven't added new required config — additive PREVIEW_* env vars are fine, but existing setups shouldn't break on upgrade.
4. The change fits the scope described in CONTRIBUTING.md.
-->

## What this changes

<!-- One or two sentences. Link to the issue if there is one. -->

## Why

<!-- The problem you hit, or the use case this enables. -->

## How you tested it

<!-- Especially important for deploy/teardown changes. Paste the relevant ==> log lines from a real run, with secrets redacted. -->

```
# log output
```

## Checklist

- [ ] `shellcheck scripts/*.sh` is clean
- [ ] Ran against a real AWS account (if touching deploy/teardown)
- [ ] No new required config / dependencies
- [ ] Updated README / examples if user-facing behavior changed
