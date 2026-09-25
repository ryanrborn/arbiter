# Contributing to Arbiter

Thanks for your interest in contributing.

## License and the Contributor License Agreement

All contributions to this repository are licensed under the
[Apache License, Version 2.0](LICENSE), the same license as the rest of the
project.

Before any pull request can be merged, you must sign the project's
[Contributor License Agreement (CLA.md)](CLA.md). A CLA check runs
automatically on every pull request and posts instructions for signing on your
first contribution.

**Why a CLA and not a DCO?** Arbiter follows an open-core model: components
that start out in this Apache-2.0 repository may later need to move into a
separately licensed, closed-source "Pro" package. A Developer Certificate of
Origin (DCO) only certifies that you wrote the contribution and have the right
to submit it — it does not grant the maintainer any right to relicense it. The
CLA does grant that right, which is why it's required rather than the more
common DCO sign-off. See [Licensing Model & Open-Core
Architecture](docs/licensing-model.md#4-contributor-license-agreement-cla-requirement)
for the full rationale.

> **Setup status:** the CLA check is currently skipped (neutral, not passing)
> until the repository owner completes a one-time setup — storing a
> signature-bot PAT as the `CLA_ASSISTANT_PAT` repository secret, and creating
> the `cla-signatures` branch that stores recorded signatures. Until that
> lands, the check will not block merges — but the CLA itself, and the
> requirement to sign it, still apply.

## Local development

This is an Elixir/Phoenix umbrella project. From the repository root:

```sh
# Install dependencies and set up child apps
mix setup

# Run the full pre-commit gate (compile, unused deps, formatting, tests)
mix precommit

# Run static analysis and security scanning (credo, sobelow, dialyzer, etc.)
mix audit
```

Before opening a pull request (or committing for review), run `mix precommit && mix audit`
and fix any issues. If you make further edits after running these, re-run to catch any new issues.

## Reporting security issues

Please do not open a public issue for a security vulnerability. See
[SECURITY.md](SECURITY.md) for how to report one privately.
