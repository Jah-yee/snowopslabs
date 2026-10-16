<!-- Thanks for contributing to SnowOps Labs! Please fill this out. -->

## What

<!-- What does this PR do? One or two sentences. -->

## Why

<!-- The motivation / the issue it closes. Link issues: Closes #123 -->

## How it was tested

<!-- The tests this PR adds, and for a bug fix the test that failed before it.
     Then anything run by hand: cluster (k3d/kind), scenario verify output. -->

## Type of change

- [ ] Scenario / pack / content
- [ ] Platform module
- [ ] Docs
- [ ] Engine / CLI / SDK (requires an RFC under `docs/rfcs/` - link it)
- [ ] CI / tooling

## Checklist

- [ ] My commits are signed off (`git commit -s`: see DCO.md)
- [ ] Conventional Commit title (`feat:`, `fix:`, `docs:`, `ci:`, `chore:`)
- [ ] Cross-platform & idempotent (no GNU-only shell flags; safe to re-run)
- [ ] Updated relevant **docs** and the **runbook** (golden rule 8)
- [ ] New source files carry an SPDX header (`// SPDX-License-Identifier: Apache-2.0`)
- [ ] Tests ship with the change (docs/TESTING.md); `make lint` and `make test` pass locally
