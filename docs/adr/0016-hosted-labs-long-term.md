# ADR 0016: Hosted labs are a long-term goal, built on the open-source lab

**Status:** Accepted
**Date:** 2026-10-16

## Context

[ADR-0001](0001-cut-cloud-and-commercial-scope.md) removed the cloud runtimes
and the commercial layer (pack marketplace, entitlement tiers, paid editions)
because they served no users and pulled attention from the core loop. The
product definition then listed a hosted multi-tenant service as out of scope.

That left no answer for people who want to practise but can't, or would rather
not, run the lab locally: the minimum is Docker with 2 CPUs and 4 GB, and the
heavier scenarios want 6 GB or more. A hosted version, where the same
scenarios run on a cluster we operate and open in a browser, would serve them,
and could pay for the project's upkeep.

Building it now would repeat the mistake ADR-0001 corrected: effort spent on a
surface with no users while the core is still young.

## Decision

Hosted labs are a goal for later, not for now.

- They come after the open-source lab has a solid base of users, and their
  shape is decided by what those users ask for.
- They are a separate service built on the open-source lab, living outside
  this repository as [GOVERNANCE.md](../../GOVERNANCE.md) requires of
  commercial offerings. They never gate the open core and never take features
  away from the local lab.
- Any change hosted labs need in this repository goes through an RFC first.

ADR-0001 stands. Nothing it removed comes back because of this record.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| Keep hosted labs out of scope for good | Shuts out people without the hardware, and leaves the project no way to fund itself |
| Start building hosted labs now | No users yet to tell us what they need; the same breadth-over-depth trap as v1 |
| Paid features inside the open-source lab | Splits the project into editions, which ADR-0001 rejected |

## Consequences

- **Easier:** the product docs and website can mention hosted labs honestly, as
  a plan, without implying it exists or is close.
- **Harder:** nothing changes in the code today, so the people who need hosted
  labs still have to wait.
- **Constraint on future work:** a feature that only works hosted needs a
  strong reason, and an RFC that explains it.
