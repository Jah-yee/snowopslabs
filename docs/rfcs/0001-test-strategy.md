# RFC 0001 — Tests that find the bugs before a learner does

**Status:** Accepted
**Author:** @sagar2395
**Date:** 2026-10-13

## Summary

Most bugs in SnowOps Labs are found by using it: recording a video, running a
review harness on a live lab, or onboarding a fresh machine. This RFC measures
the current test suite, shows which layers let those bugs through, and proposes
six phases of work plus a tighter rule for new code. The aim is that `make
test` and one nightly cluster job find what today takes a person and a lab.

## Motivation

### What was measured

All numbers are from `main` at `92cacc4` on 2026-10-13.

**Go (39 packages, 163 test files, about 1,000 test functions)**

| Measure | Result |
|---|---|
| Statement coverage, whole module | 75.8% |
| Packages at or above the 80% gate | 31 of 39 |
| `internal/cli` | 34.3%; 65 of 188 functions never run. `scenario.go` 16%, `challenge.go` 14%, `incident.go` 11%, `init_cmd.go` 11% |
| `internal/httpapi` | 60.9%; `handlers.go` 18.6%. 18 of 66 routes are never called by a test, 33 of 66 are below 60% |
| Routes with no test | `GET /status`, `/apps`, `/apps/{name}/detail`, `/scenarios`, `/platform`, `/platform/component/{category}/{name}`, `/services`, `/runtimes`, `/dashboards`, `/jobs`; `POST /platform/up`, `/platform/down`, `/traffic/stop`, `/incidents/inject-random`, `/challenges/complete`, `/learn/paths/{name}/reset`, runtime activate and deactivate |
| Mutation sample, eight well-covered packages | about 9 in 10 of roughly 90 sampled mutants killed (see below) |
| CLI golden files, `--output json` schema tests, OpenAPI | none exist |
| Fuzz targets | 4, all in `internal/catalog`; no checked-in corpus |
| Cancellation and deadline tests | 5 test files assert `context.Canceled` or `DeadlineExceeded`; 88 exported functions take a context, and 7 packages that have them test no cancellation at all |
| `goleak`, `synctest`, `t.Parallel` | 0, 0, 1 use; 17 `time.Sleep` calls in tests |
| Order dependence | none found (`-shuffle=on` passes) |

The mutation sample flipped one operator on a covered line (`==`/`!=`,
`&&`/`||`, comparisons, `return true`/`false`) and ran the package's tests,
about 12 mutants each in `challenge`, `learn`, `results`, `run`, `scenario`,
`service/scenario`, `store` and `pkg/checks`. Tests caught about nine in ten.
Where the core packages have tests, the tests are good. The problem is not
weak assertions in the engine; it is the layers that have few tests or none.

**Shell (200 scripts, 11,700 lines, 197 bats tests)**

| Area | Scripts | Named in a test |
|---|---|---|
| `runtimes/` | 11 | 11 |
| `bootstrap/`, `install.sh`, release scripts | 8 | 5 |
| `platform/` | 63 | every `install.sh`, `uninstall.sh` and `status.sh` is run once under stubs; 5 have their own tests |
| `incidents/` | 18 | `inject.sh` and `resolve.sh` are run against a `kubectl` that prints nothing, which catches syntax errors only; 2 detection checks have behaviour tests |
| `scenarios/` | 73 (4,092 lines) | 1 |

The 13 scenarios declare 109 checks in YAML (`kubectl`, `promql`, `http` and
script checks) and ship 36 check scripts (2,074 lines). This is the grading
logic. One check script has a test. No test runs a scenario's checks
against a solved state, an untouched state or a false fix.

**UI (162 component tests, 4 browser tests)**

| Measure | Result |
|---|---|
| Coverage gate | 80%, but `App.tsx`, `views/**`, `hooks/**`, `lib/jobs.ts` and five components are excluded, about 80% of the code |
| Coverage with nothing excluded | 65.7% |
| Views with almost no coverage | `Apps` 0.8%, `Challenges` 1.1%, `Leaderboard` 2.7%, `Login` 3.1%, `Platform` 35.9%, `Dashboard` 46.2% |
| API mocking | 8 view test files replace `api/client` with `vi.mock`; fixtures are hand-written, so a renamed Go field fails no test |
| Error states | 2 assertions on an HTTP error status in the whole suite |
| Browser tests | The stub table uses `/api/status`; the client calls `/api/v2/status`. No stub matches, every request gets 404, and the four tests assert that the page is not blank |
| Documented journeys (7) | 0 exist |
| ESLint, Prettier, visual snapshots | not installed |

**Real cluster**

The nightly kind job runs one scenario (`env-promotion`) of 19 content items
marked `verified: true` (13 scenarios, 6 incidents). It never injects an
incident and never checks that an untouched lab fails verification.

### Where the bugs came from

Of 162 commits since June, 64 are fixes. A fix that touches two areas counts
in both rows.

| Area the fix touched | Fixes | Fixes with no test change |
|---|---|---|
| Scenario, incident, challenge and learning content | 35 | 26 |
| Platform and runtime shell | 16 | 5 |
| `internal/cli` | 12 | 3 |
| Other Go | 10 | 2 |
| `internal/httpapi` | 7 | 2 |
| UI | 4 | 1 |

More than half of all fixes are in content, and three in four of those shipped
without a test, because there is nowhere to put one. Their subjects repeat: a
check that passes with no work done, a check that passes after a wrong fix, a
fault that prints its own answer, a raw `{{.WorkloadName}}` in output, an
alert rule that can never fire on k3s. The review skills find these by hand on
a live lab, one item at a time.

### What the documents promise that does not exist

[TESTING.md](../TESTING.md) describes these as mandatory:

- CLI golden files and `make golden-update` (the target passes a flag no test
  defines).
- `make test-cluster` (it runs `test/cluster/run.sh`, which does not exist).
- OpenAPI generated from contract tests.
- Seven Playwright journeys against the real binary with a fake toolchain.
- `axe` on every route, visual snapshots, ESLint with `jsx-a11y`, Prettier.
- Fuzz targets for check expressions, step markers, templates and API bodies,
  with an extended nightly run.
- A nightly job that activates, verifies and tears down every verified
  scenario and incident.

`src/.coverage-exceptions` and the exclusions in `vitest.config.ts` justify
each entry with a rewrite in waves W1 to W7. The roadmap no longer has waves.
The floors are also stale: `internal/k8s` is allowed 0% and has 62.6%,
`internal/cli` 19.5% against 34.3%, `internal/httpapi` 43.6% against 60.9%.
Each can lose that much without failing a build.

### Diagnosis

1. **The gate exempts the surfaces users touch.** CLI commands, HTTP handlers
   and UI views are the exceptions, so the 80% rule holds only for the engine
   underneath them.
2. **Content has no hermetic behaviour tests.** It is where most bugs are, and
   the only test of a check's logic is a person on a live lab.
3. **Nothing tests the seams.** The Go response shapes and the TypeScript
   types are kept in step by hand; the browser tests do not reach the API.
4. **The rule does not ask for a regression test,** and nothing checks that a
   change brought tests with it.
5. **The documents describe the target as if it were built,** so a reader
   cannot tell what a green build covers.

## Design

### The rule for new work

Proposed text for the Hard rules in `CLAUDE.md`, replacing the current single
bullet on tests, and mirrored in the invariants and the definition of done in
`AGENT-CONTEXT.md`:

> - Every change ships its tests in the same commit, at the layer that owns the
>   behaviour. [TESTING.md](../TESTING.md) has the table of what each kind of
>   change needs.
> - A bug fix starts with a test that fails because of that bug. A bug that
>   only a cluster can reproduce goes in the cluster suite.
> - A test asserts an outcome a user would notice. Break the behaviour once and
>   watch the test fail before you trust it; "ran without error" is not a test.
> - A check, grader or detection script has three fixtures: solved passes,
>   untouched fails, and a known wrong fix fails.
> - Tests are table-driven and hermetic. No live cluster, network or real
>   credentials.
> - No new coverage exceptions or exclusions. Floors only go up.

The table for `TESTING.md`:

| You add or change | Tests required in the same change |
|---|---|
| A Go function or method with logic | Table-driven test in the file named after the source file: the happy path, every error return, boundary inputs. A `context.Context` argument adds a cancelled case and a deadline case |
| A new Go package | 80% from its first commit; no exception entry |
| An API route | A row in the contract table: success shape, one `problem+json` error with its `type`, the auth case, and 409 when it takes a lock. Its golden response is regenerated |
| A CLI command or flag | Golden file for the human output, schema assertion for `--output json`, exit code for each failure |
| A shell script with branching | bats: the calls it makes, a second run makes no destructive call, a failing tool makes it exit non-zero |
| A check, grader or detection script | The three fixtures above |
| `inject.sh` / `resolve.sh` | What it changes, that `resolve` restores what `inject` recorded, and that nothing it prints or writes on the learner's objects names the fault |
| A scenario, incident, challenge or path | Renders with a non-default app and namespace leaving no `{{` and no hardcoded `go-api`; an entry in the cluster suite |
| A UI component, hook or view | Loading, empty, error and populated states, and each interaction, with the API served by MSW from the contract goldens |
| A user journey | A Playwright journey against the real binary |
| A bug fix | The failing test first, named in the commit message |

### Phase 0 — Make the gates honest (2–3 days)

Nothing here writes product tests; it stops the suite from getting worse and
makes the documents true.

1. Land the rule above in `CLAUDE.md`, `AGENT-CONTEXT.md`, `CONTRIBUTING.md`
   and the authoring skills (`scenario-author`, `incident-author`,
   `learning-author`, `api-change`, `platform-component`).
2. Rewrite `TESTING.md` in two parts: what is enforced today, and what each
   later phase adds. Every claim in the first part names the target or CI job
   that enforces it.
3. Raise every coverage floor to today's value and replace the wave reasons.
   Make `coverage-gate.sh` fail when a package is more than one point above
   its floor, so floors follow reality.
4. Replace the UI exclusions with per-path thresholds at today's values, so
   views and hooks are inside the gate and cannot regress.
5. Add a changed-lines gate: at least 85% of the executable lines a pull
   request changes are covered, for Go from `coverage.out` and for the UI from
   `lcov`. This is what enforces tests for new code while old code catches up.
6. Add `make test-check`: a pull request that changes Go, a script or UI
   source without changing a test fails, unless a commit carries a
   `Tests-Not-Needed: <reason>` trailer.
7. Fix the browser stubs to `/api/v2`, and make an unstubbed request fail the
   test instead of returning 404.
8. Remove `golden-update` and `test-cluster` until phases 2 and 4 make them
   real. Run Go tests with `-shuffle=on`.

**Done when:** CI fails a pull request that lowers any package's coverage,
adds untested lines, or changes code without a test.

### Phase 1 — Content: every check proves it can fail (6–9 days)

The largest source of bugs gets a hermetic harness.

1. **State fixtures.** A scenario or incident gets `test/<state>/` directories.
   Each holds canned `kubectl` answers keyed by argument pattern, canned
   Prometheus answers keyed by query, and `expect.yaml` listing which checks
   pass. Required states: `untouched` (after `up`, no work done) and `solved`.
   Each false fix a review found becomes a named state.
2. **One Go test replays them.** It loads every scenario and incident, runs
   every declared check through the real `pkg/checks` runner with a fake
   executor and a fake Prometheus, and compares against `expect.yaml`. Script
   checks run under the bats stub, extended to answer from the same fixtures.
3. **Fault scripts.** bats tests per incident: `inject` makes the expected
   change, a second `inject` changes nothing, `resolve` restores what `inject`
   recorded, a failing `kubectl` fails the script. An answer-leak test asserts
   that no output line and no label or annotation on the learner's objects
   contains the fault's name. It fails for the four faults that annotate the
   object they break, so their bookkeeping moves to a record of its own.
4. **Static content tests in Go.** Every template in every scenario, fault,
   hint and snippet renders with app `zz-app` in namespace `zz-ns`; the output
   has no `{{`, and no `go-api` outside a short allow-list.
5. **Completeness gate.** A test lists every scenario, incident and check
   script and fails for any without fixtures. The 13 scenarios and 6 incidents
   start on an allow-list that only shrinks.

Order by fix history: `security-compliance`, `secrets-management`,
`observability-sre`, `backup-restore-drill`, the six incidents, then the rest.

**Done when:** every verified item has `untouched` and `solved` fixtures, and
a check that passes with no work done fails `make test`.

### Phase 2 — CLI and API contracts (7–10 days)

1. **API route table.** One table-driven suite walks the router and fails for
   any route without a row. A row asserts the success body, one error
   envelope, the auth case and, for a route that takes a lock, the 409 that
   names the holder. The 18 untested routes come first, then the 15 below 60%.
2. **Contract goldens.** Each row writes its response to
   `internal/httpapi/testdata/contract/`. Phase 3 serves these files to the UI
   tests, so a Go shape change fails a UI test.
3. **CLI harness.** `runCLI(t, args...)` returns stdout, stderr and the exit
   code over `toolchain.Fake`, a temp store and a temp content root. Each
   command gets a golden for its human output, a schema assertion for
   `--output json` and a row per failure. Order: `scenario up/down/verify`,
   `incident inject/status/resolve`, `challenge start/submit/hint`, `learn`,
   `init`, `lab`, `status`, `doctor`. `make golden-update` returns here.
4. **Cancellation.** Cancelled and deadline cases for the seven packages with
   none; `synctest` replaces the 17 sleeps; `goleak` in `run`, `executor` and
   `httpapi`.
5. **Fuzz.** Targets for template resolution, check parsing, step markers and
   API request bodies, each with a checked-in corpus.

Backlog items B8, B14, B15 and B17 are each fixed test-first in this phase.
B16 moves routes onto the run engine; its contract rows are written first so
the move cannot change a response unnoticed.

**Done when:** every route has a row, `internal/cli` is at 70% and
`internal/httpapi` at 80%, and the six smaller packages on the exception list
(`k8s`, `runtime`, `services`, `lab`, `learn`, `pkg/extension`) are over 80%
and off it.

### Phase 3 — UI (6–8 days)

1. Replace `vi.mock('../api/client')` in the eight view tests with MSW
   handlers that serve the contract goldens.
2. Tests for the six views near zero, then raise the rest: each covers
   loading, empty, error and populated states and its main actions.
3. Tests for `LogPanel` (including collapse staying collapsed),
   `ConfirmDialog`, `Notification`, `WorkloadPicker`, `Login`, and the hooks
   `useJobRunner`, `useWebSocket` and `useRunLogs`.
4. **Browser journeys against the real binary.** Playwright starts `labctl ui`
   with stub `kubectl`, `helm` and `k3d` on `PATH`, a temp state directory and
   the real content. The seven documented journeys are written against it,
   with an `axe` scan on each route.
5. Add ESLint with `react-hooks` and `jsx-a11y` to `make lint-ui`.

**Done when:** no path is excluded from the UI gate, all seven journeys run on
every pull request, and no view test stubs a module.

### Phase 4 — The cluster suite (5–8 days, plus CI time)

Some bugs exist only on a cluster: an alert that cannot fire on k3s, a
NetworkPolicy the CNI does not enforce, an operator's backoff.

1. `src/test/cluster/run.sh` runs one item end to end. For a scenario: `up`,
   `verify` must fail, run the item's reference `test/solve.sh`, `verify` must
   pass, `down`, assert nothing is left behind. For an incident: `inject`, the
   detection check fails and the expected alert fires, then both the
   `resolve` path and the hand-fix path, then the same leak assertion.
2. Each verified item gets a `test/solve.sh` written from its solution.
3. The nightly job runs every verified item as a matrix on kind. An item that
   fails loses `verified` until it passes.
4. The same script runs against a developer's lab (`make test-cluster
   ITEM=<name>`), replacing the mechanical steps of the review skills.
5. A record mode writes the `untouched` and `solved` fixtures of phase 1 from
   the live run, so hermetic fixtures stay faithful to a real cluster.

**Done when:** all 19 verified items pass nightly, and `verified: true` is
set only by that job's result.

### Phase 5 — Keeping it true (1–2 days)

- A weekly mutation run on the core packages with a floor on the kill rate.
- A nightly `go test -count=3 -shuffle=on` and three Playwright repeats to
  surface flaky tests.
- A time budget: a package over 20 seconds fails. `internal/incident` takes 68
  seconds under `-race` today, most of it in two script smoke tests.

### Order and effort

| Order | Phase | Effort (days) | Catches |
|---|---|---|---|
| 1 | 0 — Honest gates | 2–3 | Regressions and untested new code |
| 2 | 1 — Content fixtures | 6–9 | Checks that pass with no work or a wrong fix; leaked answers; raw templates |
| 3 | 2 — API routes and goldens (items 1–2) | 3–4 | Wrong or missing API responses |
| 4 | 3 — MSW and journeys (items 1, 4) | 3–4 | Go and UI drifting apart; broken flows |
| 5 | 2 — CLI, cancellation, fuzz (items 3–5) | 4–6 | Wrong CLI output and exit codes; orphaned work |
| 6 | 4 — Cluster suite | 5–8 | Anything only a cluster shows |
| 7 | 3 — Remaining views and components | 3–4 | UI state bugs |
| 8 | 5 — Mutation, flakes, time budget | 1–2 | Tests that stop meaning anything |

Total 27 to 40 days. Each phase is independent pull requests of a day or two.

### Progress

**Phase 0 is done.** The rule is in `CLAUDE.md`, `AGENT-CONTEXT.md`,
`CONTRIBUTING.md`, `TESTING.md` and the authoring skills. `make test-check`
and the changed-lines gate block a pull request. Coverage floors are raised
and follow the tests; the UI gate excludes nothing. The browser stubs use the
real API paths, are type-checked, and fail on an unstubbed request.

**Phase 1 is done for scripts.** All 33 scenario check scripts, the six
detection checks and the six faults' `inject.sh` and `resolve.sh` have
behaviour tests, and a gate fails any new one without. Two Go tests render all
content for a non-default app. The tests found and fixed:

| Defect | Where |
|---|---|
| The original value was written on the object the learner inspects | `service-selector-broken`, `crashloop-bad-config`, `bad-deploy-rollout`, `oom-kill` |
| The check failed with no message when the workload was scaled to zero or missing | `oom-kill` |
| The check passed on a lab seeded with a non-default baseline, with no rotation done | `secrets-management` |
| A probe that never answered counted as proof of enforcement | `security-compliance` |
| The check passed when the workload was scaled to zero | `node-drain-drill` (pods evicted) |
| The check passed when the cluster could not be queried | `node-drain-drill` (cordon, PDB), `cluster-upgrade-drill` (nodes ready) |
| The check passed with its activation checkpoint deleted | `cluster-upgrade-drill` (workload healthy) |
| A push that deleted the manifest passed | `gitops-cicd` (learner pushed) |
| A refused connection counted with the canary down | `mesh-traffic-management` (mTLS) |
| Resolve, run after a hand fix, undid a fix made a different way | `service-selector-broken`, `bad-deploy-rollout` |
| Resolve on a lab where the fault was never injected removed the workload's own memory settings | `oom-kill` |

**Phase 2 is done**, apart from the items listed at its end.

*API.* Every route has a contract row with a golden answer, a problem case and
its role rule (`server_contract_rows_test.go`), and a test fails a route
without one. `internal/httpapi` went from 60.9% to 87%. Writing the rows found
and fixed:

| Defect | Where |
|---|---|
| 21 errors were plain text, not `problem+json`, so the UI showed "HTTP 400 Bad Request" in place of the reason | challenges, learning paths, results |
| A missing challenge or path answered with the server's filesystem path | `GET /challenges/{name}`, `GET /learn/paths/{name}` |
| `202 accepted` for something that does not exist | scenario up and down, service up and down, runtime activate and deactivate, app build, deploy and destroy |
| The random pick ignored the app the caller chose | `POST /incidents/inject-random` |
| `elapsedSeconds` carried nanoseconds, so the Challenges history showed billions of minutes | `GET /challenges/history`, `POST /challenges/complete` |
| Progress for a path that does not exist answered `200` | `GET /learn/paths/{name}/progress` |
| A client could report its own challenge score; the route now grades on the server | `POST /challenges/complete` |
| A silent incident's name was sent to every client, and the UI hid it | `GET /incidents` |
| A snapshot or reset of a cluster that did not answer recorded or planned from an empty lab | `POST /lab/snapshots/{name}`, `POST /lab/reset` |
| A request body of any size was read; a malformed parameter body was ignored and the scenario activated with its defaults | every route with a body, `POST /scenarios/{name}/up` |

*CLI.* The harness (`internal/cli/root_harness_test.go`) runs the real command
tree in-process over the fixture lab in `src/test/fixtures`, which the API
suite now shares. Each command group has a journey compared with a golden
transcript, a failure table, and tests for single behaviours. `internal/cli`
went from 34% to 81%. The commands have no `--output json` yet, so there is no
schema to assert. Writing the tests found and fixed:

| Defect | Where |
|---|---|
| Silent mode printed the fault's name in the run line and marked it `ACTIVE` in the list | `incident inject --silent`, `incident list` |
| A cluster that did not answer was reported as "app not deployed", with advice to build and deploy it | `incident inject`, `challenge start` |
| A snapshot of a cluster that did not answer was saved as an empty lab; a reset reported the lab reset | `lab snapshot`, `lab reset` |
| "Platform uninstalled." and exit `0` when an uninstall had failed | `platform down` |
| A mistyped app name ran the engine script, which failed on its missing build settings | `app build`, `app deploy`, `app destroy` |
| A missing argument or unknown flag printed the error with no usage | every command |
| A name that does not exist answered with a filesystem path and no next step | `challenge info`, `challenge start`, `learn start`, `learn next`, `scenario up` |
| Nothing was printed, so a deleted snapshot looked like a command that did nothing | `lab delete` |
| A challenge whose grading resolved to no checks was recorded as passed with a score of 0 | `challenge submit` |
| A learning path could declare a `kubectl` check the runner never graded, and a `promql` check lost its operator and value | `labctl validate`, `learn next` |

*Smaller packages, cancellation, leaks and fuzzing.* `k8s`, `runtime`,
`services`, `lab`, `learn` and `pkg/extension` are over 80%; the exception list
holds only the `cmd/labctl` entrypoint. `goleak` runs in `run`, `executor` and
`httpapi`. Five fuzz targets hold check comparison, check parsing, template
expansion, step markers and API request bodies to their invariants. They found
and fixed:

| Defect | Where |
|---|---|
| A run picked up at the instant of shutdown was never cancelled: `Shutdown` timed out and the script kept running with no parent | `internal/run` (found by `goleak`) |
| A check passed on `NaN` or `Inf`, which is what a ratio answers with nothing to divide, so "no data" could satisfy `!=`, `>` and `>=` | `pkg/checks` (found by `FuzzCompare`) |
| An unset field was `0` for `>=` and `<=` but not for `==` and `!=`, so "ready replicas `!= 0`" passed with none ready | `pkg/checks` (found by `FuzzCompare`) |
| A placeholder nested inside another left a raw `{{.WorkloadName}}` in what was applied to the cluster; `labctl validate` now rejects it | `internal/tmpl` (found by `FuzzExpand`) |
| A test helper opened the developer's real run store in `~/.snowops` and left it open | `internal/httpapi` tests (found by `goleak`) |

Backlog item B17 is fixed here. The rest of phase 2 found and fixed:

| Defect | Where |
|---|---|
| Two writers could both take one lock: the check and the insert were separate statements (B15) | `internal/store`, now one guarded `INSERT` |
| `scenario down` reported success when a delete failed, and a run's summary dropped the error's next step (B8) | `internal/scenario`, `internal/run`; `scenario down --force` is the way past a stuck teardown |
| Ctrl-C left scripts running with no parent, `verify --watch` ignored it, and `labctl ui` stopped without draining requests (B14) | `internal/cli`, `internal/httpapi` |
| Admission let a cancelled request through | `internal/service/admission` |
| A learning module was marked complete on the client's word (B32) | `POST /learn/paths/{name}/complete` now grades on the server, through the same code as the CLI |
| A silent incident was named in the run history and its job broadcast (B33) | hidden runs: no target, no steps, logs refused |
| Two learning fields had no JSON tags, so the UI read `undefined` for every module's action | `internal/learn`, `internal/challenge` (found by the camel-case contract test) |
| `gitops-cicd`'s teardown printed success after a failed delete | `scenarios/gitops-cicd/scripts/remove-apps.sh` |

Not done in phase 2: `synctest` in place of the test sleeps, and cancellation
tests for every package that takes a context (they exist for `k8s`, `run`,
`cli`, `admission`, `service/challenge` and `pkg/extension`).

**Phase 3 is done.** Every view is rendered against the Go contract's
golden answers through the real API client (`src/ui/src/contract.test.tsx`),
so a changed response shape fails a UI test; a view without a row fails too.
The hooks and `lib/` are tested directly and sit at 100% of lines. Playwright
has a second project that drives the real `labctl` binary over the fixture
lab: seven journeys and an `axe` scan of every route. UI coverage went from
65% to 75% of lines, views from 59% to 72%. The work found and fixed:

| Defect | Where |
|---|---|
| The output panel scrolled but could not be reached by keyboard, and had no name for a screen reader | `LogPanel` (found by the browser `axe` scan) |
| The history routes were recorded empty, so nothing held the Results, Leaderboard and Compare views to the server's shape | contract goldens |

| Text failed AA colour contrast in both themes (B34) | the palette in `index.css`, adjusted and held by an `axe` scan of every route in light and dark |
| Cancelling a run from the web UI or `labctl runs cancel` marked it cancelled and freed its lock, but the script ran on in the process that owned it | `internal/run`: a running run re-reads its record and stops when it is cancelled (found by the cancel journey) |
| One failed request stopped a run's log view for good | `useRunLogs` retries a dropped connection or a server error from its cursor and stops only on a refusal (found by the stream journey) |
| The muted badge on the selected run failed AA contrast in the dark theme | `index.css` (found by the `axe` scan once the lab had runs) |
| ESLint's dependencies put a Go package from `node_modules` into `go test ./...`, which failed the coverage gate | `src/go.mod` ignores `ui/node_modules` |

Every view test now goes through the contract server; none stubs
`api/client`. ESLint runs with `react-hooks` and `jsx-a11y` in `make lint`. A
third Playwright project, `real-auth`, signs in against the real binary with
`LABCTL_AUTH` on. Journeys cancel a running inject from the Runs view and
resume its output after its log requests are dropped.

**Phase 4 is built, and has run on a cluster.**
`src/test/cluster/run.sh` runs one item end to end, and
`.github/workflows/cluster-suite.yaml` runs every item nightly, on kind
unless the scenario supports only k3d, with the workers it requires. Every
scenario and fault has a `test/solve.sh` with a hermetic test; the solves
share `src/test/cluster/solve-lib.sh`. With `RECORD=1` the runner records the
untouched and solved lab through `labctl scenario verify --record`, and
`TestCheckFixtures_Replay` replays those answers through the real check
runner: a result that changes, a query the lab was never asked, a pending
check that passes untouched or a check that fails solved breaks `make test`.
The nightly publish job sets each item's `verified` flag from its result and
lands the recorded fixtures as a pull request. The first end-to-end run
recorded all 13 scenarios, so the list of unrecorded ones is empty, and every
one of the 19 items passed: the six faults and twelve scenarios on kind,
`cluster-upgrade-drill` on k3d.
The hermetic work found:

| Defect | Where |
|---|---|
| bash 3.2, the bash macOS ships, never failed a test on a `[[ ]]` assertion that was not its last line, so 306 shell assertions could not fail on a Mac | every `.bats` file; `bats_assertions.bats` now requires `\|\| false` |
| The gitops solve reported failure after succeeding: its exit trap's `kill` failed under `set -e` once port-forward had exited | `scenarios/gitops-cicd/test/solve.sh` (found by its test) |
| The nightly built every item on one kind worker, so the two-worker and k3d-only drills could never pass | `items.sh` and the workflow matrix |

The first end-to-end run, on a three-node kind cluster on a developer's
machine, found and fixed:

| Defect | Where |
|---|---|
| An app with a chart of its own was always served on the default lab's host, so on any lab not named `snowops` the app answered 404 | `src/engine/deploy/helm.sh`, the go-api and echo-server charts |
| A kind lab named its Ingresses `nginx` while the platform installed traefik, so nothing it created was routed | `internal/config`: the class follows `INGRESS_PROVIDER` |
| Grafana, Loki and Tempo claimed volumes from `local-path`, which only k3d has, so on kind they never started | their installs take `STORAGE_CLASS` |
| `autoscaling-under-load` left the learner's ScaledObject behind, and KEDA scaled the shared workload back to one replica in every scenario after it | `scripts/remove-autoscaler.sh`, on activation and teardown |
| `security-compliance` failed its own solved lab: once the learner enforced the Pod Security policies, admission refused the isolation check's probe pod | `check-namespace-isolation.sh`: the probe meets the policies |
| `env-promotion` missed a real rollback when the releases were created within the same second, because it ordered ReplicaSets by creation time | `rollback-was-exercised.sh` reads the controller's `revision-history` |
| The runner counted an item's prerequisites as left behind, and could not see an object left in the workload's namespace | `run.sh`: a warm-up cycle, and a namespace object check |
| On Helm 4, the pinned version, `helm list --all` is rejected, so a scenario never saw a release it should adopt and upgraded the platform's ArgoCD with its own values | `helmReleaseExists` names every status instead |
| `mesh-traffic-management` asked for "a mesh", which has two providers, so `--deploy-prereqs` stopped unless `MESH_PROVIDER` was set; its checks read Istio's telemetry only | the prerequisite is `mesh/istio` |
| Five checks credited traffic from before activation: on a lab where another scenario had run, autoscaling's latency and error guards, node-drain's traffic and availability checks and cost's load check passed before any work | their windows are `{{.SinceActivation}}` (found by the replay test on the recorded fixtures) |
| backup-restore's `restore-data-pvc-present` was a pending learner step that activation itself satisfies | a plain lab-state check (found the same way) |
| A redirect was recorded without its target, so a check that follows one could not replay | `checkfixture` keeps `Location` |
| `cluster-upgrade-drill`'s `roll-node.sh` restarted the k3d load balancer, which also fronts the API server, and returned while it was down, so the learner's next `kubectl` was refused | it waits for `/readyz` |

Filed: B35, an incident solved by hand leaves its fault record in
`kube-system` and its alert rule (the runner runs `resolve` after the hand
fix to tidy them); B36,
`platform status` does not see components a scenario installed as
prerequisites.

**Phase 5 is done.** `.github/workflows/test-health.yaml` runs the Go tests
three times shuffled with `-race` and the browser journeys three times each,
nightly, and a time budget: every Go test within 5 seconds, each package
measured alone. A per-package budget measured the parallel run's contention,
and failed `internal/cli` for having 148 journeys rather than a slow one.
Weekly, `gremlins` mutation-tests six packages, each with a floor on the share
of mutants killed (`internal/run` is lowest at 60%). The surviving mutants
became tests; the cluster suite's own tests caught its runner reading
`NOT RESOLVED` as resolved.

## Alternatives considered

| Alternative | Why not |
|---|---|
| Raise the coverage gate to 90% everywhere | Coverage is already high where it is enforced, and the mutation sample shows those tests are sound. The bugs are in what the gate exempts and in content, which coverage does not measure |
| Test content only on a real cluster | It is the only way to catch cluster-specific bugs, but it takes minutes per item and runs nightly. Most grading bugs are logic errors a fixture catches in milliseconds on every pull request |
| Generate TypeScript types from an OpenAPI document | Stronger than shared goldens, but it needs the OpenAPI document first. Goldens give the same failure when a shape changes, for a fraction of the work, and can feed an OpenAPI document later |
| Keep stubbing `api/client` in view tests | It hides serialisation and path mistakes, which is the bug the browser tests have today |
| Run browser tests against `vite preview` with fixed stubs | It cannot catch routing, auth, embedding or streaming bugs in the binary, and its stubs drift from the API |

## Impact

- **CI time.** Phases 1 to 3 add hermetic tests, expected under two minutes in
  total. Phase 4 adds a nightly matrix of 19 jobs.
- **Authoring cost.** A new scenario needs fixtures and a `solve.sh`. Record
  mode in phase 4 writes the fixtures.
- **Pull requests.** The changed-lines gate and `make test-check` will fail
  changes that pass today. The trailer is the escape for a change that truly
  needs no test.
- **Docs.** `TESTING.md` is rewritten in phase 0 and updated by each phase;
  `CLAUDE.md`, `AGENT-CONTEXT.md`, `CONTRIBUTING.md`, the authoring guides and
  skills, and the scenario schema reference (the `test/` directory) change.
- **Backlog.** Phases 2 and 3 closed B8, B14, B15, B17, B31, B32, B33 and B34. B6 stays open: the
  fault tests prove the scripts honour a binding, but the silent `go-api`
  fallbacks for an unbound run are still there.

## Decisions

1. The changed-lines gate (85%) and `make test-check` block a pull request
   from the day they land. A change that needs no test carries a
   `Tests-Not-Needed: <reason>` trailer.
2. The browser journeys of phase 3 run the real binary with stub `kubectl`,
   `helm` and `k3d` on `PATH`, so no product code selects a fake.
3. ESLint is added in phase 3. Prettier and visual snapshots are not planned
   and are no longer listed in `TESTING.md`.

## Open questions

1. The nightly matrix needs runners that fit the larger scenarios
   (`cluster-upgrade-drill`, `node-drain-drill`). Run those weekly, or on a
   larger runner?
2. Should a scenario's `test/` directory ship in the release bundle, or be
   stripped from it?
