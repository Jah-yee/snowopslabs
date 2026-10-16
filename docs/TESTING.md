# Testing

Tests exist so that a bug is found by `make test` or a CI job, not by a learner
on a lab. This page says what every change must bring, what the gates enforce
today, and what is still being built. The plan behind it is
[RFC 0001](rfcs/0001-test-strategy.md).

## The rule

- Every change ships its tests in the same commit, at the layer that owns the
  behaviour. The table below says which.
- A bug fix starts with a test that fails because of that bug. A bug that only
  a live cluster can reproduce becomes a step in that content's review guide
  ([scenario](authoring/scenario-review.md), [incident](authoring/incident-review.md),
  [learning](authoring/learning-review.md)).
- A test asserts an outcome a user would notice. Break the behaviour once and
  watch the test fail before you trust it; "ran without error" is not a test.
- A check, grader or detection script has a test per lab state: solved
  passes; the work not done, each known wrong fix, and a cluster that cannot
  answer all fail.
- Tests are table-driven and hermetic. No live cluster, network or real
  credentials.
- No new coverage exceptions or exclusions. Floors only go up.

## What each change needs

| You add or change | Tests required in the same change |
|---|---|
| A Go function or method with logic | A table-driven test in the file named after the source file: the happy path, every error return, boundary inputs. A `context.Context` argument adds a cancelled case and a deadline case |
| A new Go package | 80% from its first commit; no exception entry |
| An API route | A row in the contract table (`server_contract_rows_test.go`): the correct request and its golden answer, one wrong request with its problem `type`, and whether it is operator-only |
| A CLI command or flag | A step in that command group's journey test, so its output is in a golden transcript, and a row in the group's failure table for each way it can fail: the exit status and what the error tells the user to do next |
| A shell script with branching | bats: the calls it makes, a second run makes no destructive call, a failing tool makes it exit non-zero |
| A check, grader or detection script | A test per lab state, as in the rule: [testing a check script](reference/scenario-schema.md#testing-a-check-script), [testing a fault](../incidents/README.md#testing-a-fault) |
| `inject.sh` / `resolve.sh` | What it changes, that `resolve` restores what `inject` recorded, and that nothing it prints or writes on the learner's objects names the fault |
| A new fault or scenario | A `test/solve.sh` that does the learner's work, for the [cluster suite](#real-cluster) |
| A UI component, hook or view | Loading, empty, error and populated states, and each interaction |
| A user journey | A Playwright journey |
| A bug fix | The failing test first, named in the commit message |

## Gates on a change

Three gates look at the change itself. All three block a pull request.

| Gate | What fails | Run it |
|---|---|---|
| Code changed, test changed | Go source with no `_test.go` changed in the same directory; a shell script with no bats file, Go test or test fixture changed; UI source with no component test or journey changed | `make test-check` (also the last step of `make test`) |
| Changed-lines coverage | Fewer than 85% of the code lines the change adds or edits are run by a test. Applies to every Go package and all UI source, including packages below the per-package bar | `make test-go`, `make test-ui` |
| Coverage floors | A Go package below 80%, or below its floor in `src/.coverage-exceptions`; a UI path below its threshold in `src/ui/vitest.config.ts` | `make test-go`, `make test-ui` |

All three compare against `origin/main` (set `BASE_REF` to change that) and
include uncommitted work. On a machine with no such ref they skip with a
message; in CI they fail instead.

A change that needs no test, such as a comment or a pure move, says so in a
commit message trailer, and the gate prints the reason for the reviewer:

```
Tests-Not-Needed: pure move, covered by the existing engine tests
```

For work that is not committed yet, `TESTS_NOT_NEEDED="<reason>" make
test-check` does the same. The changed-lines gate has no waiver.

**Floors.** Every Go package is held to 80%. `src/.coverage-exceptions` lists
one exception, the `cmd/labctl` entrypoint, which a test keeps to a single
statement. The file's rules still apply to any entry added later: a package
below its floor fails, one two or more points above it fails until the floor
is raised, and one that reaches 80% fails until its entry is deleted. The UI
thresholds are per path and are raised by hand in the pull request that adds
the tests.

## Writing a Go test

- **Table-driven** whenever two or more cases share a shape, with a named
  subtest per case.
- **Hermetic.** `t.TempDir()` for disk, `toolchain.Fake` for every external
  binary, a temp-file SQLite for the store.
- **Named after the source file.** `engine.go` is tested in `engine_test.go`.
- **Race detector and shuffled order.** `make test-go` runs with `-race
  -shuffle=on`; a test that depends on another test's leftovers fails.

Edge cases to cover wherever they apply, because these are where real systems
break:

| Class | Examples |
|---|---|
| Cancellation | ctx cancelled before start, mid-execution, during cleanup |
| Timeouts | deadline exceeded, timeout during a child process |
| Concurrency | two runs on the same lock key, N concurrent readers, shutdown mid-write |
| Partial failure | script fails at step 3 of 7; resume converges |
| Malformed input | truncated YAML, wrong types, unknown fields, cyclic references |
| Boundary | empty list, single item, 10k items, unicode names, very long output lines |
| Filesystem | missing file, permission denied, symlink escaping the content root |

## The layers today

Each layer lists what runs on every pull request now, then what is missing and
the RFC phase that adds it.

### Go unit and contract tests

`make test-go` runs every package under `src/` with the race detector and both
coverage gates.

**The fixture lab.** `src/test/fixtures/lab` is a complete, tiny project root:
two apps, a scenario, a fault, a learning path, a challenge, a shared service,
a runtime and the platform baseline, each a few lines of script. Beside it,
`src/test/fixtures/bin` holds stand-ins for `kubectl`, `helm`, `docker` and
`k3d` that answer as a healthy cluster and record every call. `labtest.New(t)`
copies both into temp directories and points the process at them: `PATH` is
the stand-ins plus the system directories, and `HOME` and `SNOWOPS_HOME` are
empty. The API contract suite and the CLI harness both run over it, so a test
never reaches a real cluster, the network or the developer's own lab. A test
that needs the cluster to answer differently replaces a stand-in with
`lab.Stub`.

**The route contract.** `src/internal/httpapi/server_contract_rows_test.go`
has one row per route. The suite runs the real server over a small lab built
in a temp directory, with `kubectl`, `helm` and `docker` replaced by scripts
on `PATH`, and asserts for every row:

- the correct request answers the row's status, as JSON, with an
  `X-Request-ID`, and its body matches the golden file in
  `internal/httpapi/testdata/contract/`;
- the wrong request answers `application/problem+json` with the row's status
  and `type` slug, the request's path as `instance`, the request ID, and no
  filesystem path in `detail`;
- with auth on, no session is `401 unauthorized`, a participant is
  `403 forbidden_role` on an operator-only route and allowed elsewhere, and an
  operator is allowed;
- a method the route does not serve answers a `405` or `404` problem.

A route with no row fails `TestContract_EveryRouteHasARow`. When an answer
changes on purpose, `make golden-update` rewrites the golden files; review the
diff, because that diff is the API change.

**The CLI harness.** `src/internal/cli/root_harness_test.go` runs the real
command tree in-process over the fixture lab. `newTerminal(t)` is one test's
lab; `run("scenario", "up", "drill")` returns what the command printed to
stdout and stderr and how it ended. Every command group has three kinds of
test in the file named after its source file:

- a **journey**: the commands a user types in order, each asserted for what it
  changed in the lab, and the whole session compared with a golden transcript
  in `internal/cli/testdata/golden/`. Paths, times, run IDs and ports are
  replaced by placeholders;
- a **failure table**: one row per way the command fails, asserting exit
  status `1` and the part of the error that tells the user what to do;
- tests for single behaviours a journey cannot show, such as "a failed setup
  is undone" or "silent mode never names the fault".

`TestClusterDown_CommandsSayTheClusterIsUnreachable` runs the commands that
read the cluster against one that does not answer. When a transcript changes
on purpose, `make golden-update` rewrites it; review the diff, because that
diff is what users will see.

Not yet: cancellation tests in every package that takes a context, and
`synctest` in place of the sleeps some tests still use.

### Shell tests (bats)

`make test-shell` runs the suites in `src/test/shell/`. `kubectl`, `helm`,
`k3d` and `kind` are replaced by recording stubs on `PATH`
(`helpers/stub.bash`), and tests assert on the calls a script made. Runtime,
bootstrap, install and release scripts have behaviour tests. Every platform
`install.sh`, `uninstall.sh` and `status.sh` is run once under the stubs.

An assertion written as `[[ … ]]` ends in `|| false`. bash 3.2, the bash
macOS ships, does not stop a test when a `[[ ]]` that is not its last command
fails, so without it the assertion never fails there.
`bats_assertions.bats` fails for one that does not.

Content is graded code, so it is tested as code:

- Every scenario check script runs against the lab as activated, solved, each
  shortcut that fakes the result, and a cluster that cannot answer
  (`scenario_*_checks.bats`).
- Every fault's detection check runs against the solved lab, the injected lab
  and each wrong fix (`incident_checks.bats`); its `inject.sh` and `resolve.sh`
  are tested for the change they make, idempotency, failure, what resolve
  restores, and that nothing gives the answer away (`incident_faults.bats`).
- `content_tests_complete.bats` fails for a check or fault script with no test.
- Go tests render every scenario and fault for an app that is not the default,
  and fail on an unexpanded template variable or a hardcoded app name.

A script test asserts at least:

- **Idempotency**: a second run makes no destructive call.
- **Failure propagation**: a stubbed tool failing makes the script exit
  non-zero.
- **Environment contract**: the script reads `${VAR:-default}` from the
  executor's environment and does not source `.env` itself.

Not yet: scenario stage scripts (seeding, staging, teardown) and the declared
`kubectl`, `promql` and `http` checks, which need recorded cluster state to
test honestly. Phase 4.

### UI component tests

`make test-ui` runs Vitest with Testing Library in jsdom, then both coverage
gates. `a11y.test.tsx` runs `axe` on the shared components and the app shell.

**The server contract.** `src/ui/src/contract.test.tsx` renders every view
against the answers the Go contract suite records. `test/contract.ts` replaces
`fetch` with a stand-in that serves the golden files in
`internal/httpapi/testdata/contract/` by method and route, so a view goes
through the real API client and reads exactly what the server sends for the
fixture lab. Each row asserts what the view shows and that it reports no
error. A Go change that renames, retypes or drops a field a view reads empties
that view and fails its row; three tests at the end of the file prove that. A
new view needs a row, and a test fails without one.

Hooks and `lib/` are covered directly: the job runner, the WebSocket
reconnect, the run-log cursor, the theme and job tracking each have a test per
behaviour.

Every view test uses `serveContract()` and overrides only the answers its
case needs; a test fails any view test that stubs the `api/client` module.

### Browser journeys

`make test-e2e` runs Playwright in three projects.

- **`chromium`** runs against the built SPA served by `vite preview`, with the
  API stubbed in `e2e/fixtures.ts`. The stubs are checked against the client's
  TypeScript types, and a request with no stub fails the journey.
- **`real`** runs against the real `labctl` binary. `e2e/real/start-lab.sh`
  builds it and starts `labctl ui` over a private copy of the fixture lab,
  with the stand-in `kubectl`, `helm` and `docker` on its `PATH` and an empty
  home directory. Nothing is stubbed in the browser, so a journey passes only
  when the UI, the API and the scripts they run agree: activating a scenario
  runs its real setup script as a real job, and the page shows it active
  because the server says so.

The real journeys cover: the dashboard, a deep link surviving a reload, the
API's 404 problem beside the SPA fallback, activating, verifying and
deactivating a scenario, injecting, checking and resolving an incident,
checking a learning module and resetting its progress, the results and
leaderboard showing what was done, a running inject's output resuming after its log requests are dropped,
and cancelling a running inject from the Runs view. The last two start the run
from the CLI against the same lab (`$E2E_HOLD.labctl`, written by
`start-lab.sh`) and hold the fixture fault's inject open while the file
`E2E_HOLD` names exists, so the cancel crosses processes as it does for a
user. Every route is then scanned with `axe` in a real browser, which sees
what jsdom cannot, such as focus order and computed colours.

The server keeps its state between tests, so the `real` and `real-auth`
projects run on one worker each, repeats included, and every journey leaves
the lab as it found it: the nightly `--repeat-each=3` run starts each repeat
on the same lab.

Each route is scanned in both the light and the dark theme, colour contrast
included.

A third project, **`real-auth`**, starts the same server with
`LABCTL_AUTH=true` and two users, and covers signing in, a wrong password,
signing out, and a participant refused an operator-only route.

### Fuzzing

`make fuzz` runs every `Fuzz*` target for 20 seconds; CI runs 10 seconds each.
`go test` runs each target's seeds as ordinary tests, so a seed is a regression
test. A target states what must hold for any input, not only that nothing
panics:

| Target | What must hold |
|---|---|
| `FuzzLoad*` (`internal/catalog`) | malformed content is reported as a problem, never a crash |
| `FuzzCompare` (`pkg/checks`) | `==` and `!=` disagree; exactly one of `<`, `==`, `>` holds; a value that is not a finite number never passes |
| `FuzzCheckYAML` (`pkg/checks`) | a check that validates has a known type and the field it is graded from |
| `FuzzExpand` (`internal/tmpl`) | content that validates has every known placeholder filled in one pass |
| `FuzzParseStepMarker` (`internal/run`) | only a line that starts with the marker names a step |
| `FuzzRequestBodies` (`internal/httpapi`) | any body gets JSON or a problem, never a 5xx |

When the fuzzer finds a failing input it writes it under the package's
`testdata/fuzz/`; commit that file with the fix.

### Goroutine leaks

`internal/run`, `internal/executor` and `internal/httpapi` run their tests
under `goleak`: a test that leaves a worker, stream reader or open store behind
fails the package. A new package that starts goroutines adds the same
`TestMain`.

### Real cluster

**The cluster suite.** `src/test/cluster/run.sh <scenario|incident> <name>`
runs one item end to end against whatever cluster `kubectl` points at. A
warm-up cycle (`up` and `down`, or `inject` and `resolve`) first installs the
item's prerequisites, which stay by design; then:

- a scenario: `up`, `verify` must fail on the untouched lab, the item's
  `test/solve.sh`, `verify --watch` must pass, `down`;
- a fault: `inject`, its detection check must fail, `resolve` must restore the
  lab; then `inject` again, the item's `test/solve.sh` (the hand fix from its
  `solution.md`), the check must pass, and `resolve` tidies up without undoing
  the fix.

After each, nothing may be left behind: no new namespace, no fault record, and
no new object in the workload's namespace (pods, ReplicaSets, events and other
objects that controllers replace on their own are not counted). A drill object
the learner applied by hand, such as a ScaledObject, is the scenario's to
remove on teardown.

`make test-cluster ITEM=incident/oom-kill` runs it against your own lab.
`.github/workflows/cluster-suite.yaml` runs every item nightly, one matrix job
each. `src/test/cluster/items.sh` lists them, each on kind unless its
`runtimes` leave kind out, with the workers its `requirements.agents` asks for.

Every scenario and fault has a `test/solve.sh`. A solve does the learner's
work with the tools the learner uses, sourcing
`src/test/cluster/solve-lib.sh` for `wait_until` (poll until something
happens, and fail naming it), `render` (a scenario file rendered for the bound
app) and `prom`/`at_least` (an instant query through the lab's ingress). It
may start `labctl traffic` (`$LABCTL` names the binary under test); the runner
stops it before `down`. The runner has hermetic tests in
`src/test/shell/cluster_suite.bats` and every solve in
`src/test/shell/cluster_solves.bats`; a scenario or verified fault without a
solve fails them.

**Recorded check fixtures.** With `RECORD=1`, the runner verifies the
untouched and the solved lab with `labctl scenario verify --record` (the
solved one is the `--watch` verify that grades the solve), which
writes `scenarios/<name>/test/fixtures/untouched.json` and `solved.json`: the
variables the declared `kubectl`, `promql` and `http` checks were rendered
with, every answer the lab gave them, and each result.
`TestCheckFixtures_Replay` (`src/internal/scenario`) renders the scenario's
current checks with those variables, replays the answers through the real
check runner, and fails when:

- a result changes, or a check asks the lab something it was not asked (a
  changed query, jsonpath or URL: re-record it);
- a check marked `pending` passes on the untouched lab, so it grades nothing;
- a check fails on the solved lab.

`TestCheckFixtures_EveryScenarioIsRecorded` fails for a scenario without both
fixtures unless it is listed in
`src/internal/scenario/testdata/unrecorded-scenarios.txt`, a list that only
shrinks.

**`verified` comes from the nightly run.** The nightly job records every
scenario and saves each item's result. Its publish job applies them with
`src/test/cluster/apply-results.sh`: an item's `verified` flag follows its
result, a passing scenario's fixtures replace its old ones and it leaves the
unrecorded list. The changes arrive as a pull request; do not set `verified`
by hand.

Also running against a real cluster:

- **Onboarding** (`.github/workflows/onboarding.yaml`), on every pull request
  that touches it and nightly: a fresh Ubuntu runner builds a release
  snapshot, runs the clone's `./install.sh`, then `labctl doctor`, `labctl
  init` and a scenario from the home directory. macOS and WSL2 are covered by
  hand in [R14](runbooks/R14-fresh-machine-onboarding.md).
- **Nightly kind** (`.github/workflows/e2e-kind.yaml`): activates
  `env-promotion`, promotes a release through its environments, verifies, and
  tears down.
- **Release acceptance**, before a release merges:
  [`scripts/release-acceptance.sh`](release-acceptance.md) walks a live lab on
  the developer's machine. Its harness contract is pinned by
  `src/test/shell/release_acceptance.bats`.

### Keeping the tests honest

| Check | When | Run it |
|---|---|---|
| The Go tests three times, shuffled, with the race detector | nightly | `make flake-hunt` |
| Every Go test within 5 seconds, each package measured alone | nightly | `make time-budget` |
| The browser journeys three times each | nightly | `npx playwright test --repeat-each=3` |
| Mutation testing of `pkg/checks`, `internal/tmpl`, `challenge`, `learn`, `store` and `run`, each with a floor on the share of mutants killed | weekly | `gremlins unleash ./pkg/checks` |

All four run in `.github/workflows/test-health.yaml`. A mutant that survives
is a behaviour no test pins: add the test, then raise the package's floor.

## Static analysis

Every gate fails the build.

| Gate | Tool |
|---|---|
| Go lint | `golangci-lint` with the set in `src/.golangci.yml`. See [Go conventions §9](GO-CONVENTIONS.md#9-linting) |
| Go security | `gosec`, run through `golangci-lint` so it reads the one policy in `src/.golangci.yml` |
| Dependency CVEs | `govulncheck` |
| Shell lint | `shellcheck` on every script, and `shfmt -d` where it is installed |
| Portability | `src/scripts/lint-portability.sh` rejects GNU-only constructs |
| TypeScript | `tsc --noEmit` with `strict: true`, over the app, the tests and the journeys |
| UI lint | ESLint with the TypeScript, rules-of-hooks and `jsx-a11y` rules (`src/ui/eslint.config.js`) |
| Licence | dependency licence scan |
| Formatting | `gofmt -l` must be empty |
| Content | `labctl validate` over every scenario, incident, path and challenge |
| Docs | `make docs-check` |

## Make targets

```bash
make test              # Go + apps + shell tests, coverage gates, test-check
make test-go           # Go tests: race, shuffle, floors, changed lines
make test-apps         # unit tests for the demo apps
make test-shell        # bats
make test-api          # the HTTP and CLI packages only
make test-ui           # vitest: thresholds, changed lines
make test-e2e          # playwright journeys
make test-check        # the change brought tests with it
make golden-update     # rewrite the API and CLI golden files; review the diff
make flake-hunt        # Go tests three times, shuffled
make time-budget       # every Go test within TIME_BUDGET seconds
make test-cluster ITEM=incident/oom-kill   # one item end to end on your lab
make test-coverage     # HTML coverage report
make fuzz              # every fuzz target, briefly
make lint              # every static analysis gate
```
