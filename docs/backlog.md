# Engineering backlog

Deferred work that is understood but not yet done. Each item says what is
wrong, how it was found, the proposed approach, and where to start, so a later
session can pick one up without re-deriving it.

To pick one up: read the item, read the documents it links, and follow the
[definition of done](AGENT-CONTEXT.md#definition-of-done). When it lands, delete
the item — git history keeps the record.

Effort is in engineering days and is an estimate, not a commitment.

| # | Item | Area | Effort |
|---|---|---|---|
| [B1](#b1--activate-one-scenario-for-two-apps-at-once) | Activate one scenario for two apps at once | engine, content, UI | 18–22 |
| [B2](#b2--k6-metrics-carry-no-app-label) | k6 metrics carry no app label | traffic, dashboards | 1–1.5 |
| [B3](#b3--the-shared-request-dashboard-only-sees-the-default-metric-name) | The shared request dashboard only sees the default metric name | dashboards | 1–2 |
| [B4](#b4--two-scenarios-can-mutate-the-same-app-at-once) | Two scenarios can mutate the same app at once | engine | 1–2 |
| [B5](#b5--activating-from-the-ui-does-not-report-missing-hostnames) | Activating from the UI does not report missing hostnames | API, UI | 0.5–1 |
| [B6](#b6--incident-scripts-still-fall-back-to-go-api) | Incident scripts still fall back to go-api | content | 0.5–1 |
| [B7](#b7--a-docker-vm-restart-silently-kills-k3d-nodes) | A Docker VM restart silently kills k3d nodes | runtime, CLI | 1 |
| [B9](#b9--latency-below-5ms-is-invisible-and-it-hides-tail-amplification) | Latency below 5ms is invisible, and it hides tail amplification | apps, grading | 1–2 |
| [B10](#b10--chaos-network-faults-never-reach-the-traffic-generator) | Chaos network faults never reach the traffic generator | content, traffic | 1–2 |
| [B11](#b11--secrets-management-only-works-for-the-app-the-platform-was-installed-for) | secrets-management only works for the app the platform was installed for | platform, content | 1 |
| [B12](#b12--every-k3d-node-promises-the-whole-machines-memory) | Every k3d node promises the whole machine's memory | runtime | 1 |
| [B16](#b16--web-ui-actions-bypass-the-run-engine) | Web UI actions bypass the run engine | API, UI | 5–7 |
| [B18](#b18--internalcli-runs-on-package-level-state) | `internal/cli` runs on package-level state | CLI | 3–4 |
| [B19](#b19--smaller-go-clean-ups) | Smaller Go clean-ups | Go | 1–2 |
| [B20](#b20--installsh-leaves-a-fresh-mac-stuck-on-path) | `install.sh` leaves a fresh Mac stuck on `PATH` | install | 0.5 |
| [B21](#b21--init-floods-the-screen-with-metricsk8sio-discovery-errors) | `init` floods the screen with `metrics.k8s.io` discovery errors | platform | 0.5–1 |
| [B22](#b22--cost-right-sizing-cannot-activate-on-a-2-cpu-lab) | cost-right-sizing cannot activate on a 2 CPU lab | content | 0.5–1 |
| [B23](#b23--scenario-explore-links-point-at-dashboards-that-do-not-exist-yet) | Scenario Explore links point at dashboards that do not exist yet | UI, content | 0.5 |
| [B28](#b28--the-pod-memory-panel-cannot-show-one-small-pod) | The pod memory panel cannot show one small pod | dashboards, content | 0.5 |
| [B29](#b29--oom-kills-output-gives-the-fault-away-and-its-solution-describes-an-older-fault) | oom-kill's output gives the fault away, and its solution describes an older fault | content | 0.5–1 |
| [B30](#b30--rollout-undo-brings-old-fault-markers-back-onto-the-deployment) | `rollout undo` brings old fault markers back onto the Deployment | content | 0.5 |
| [B35](#b35--a-hand-fixed-incident-leaves-its-fault-record-and-alert-rule-behind) | A hand-fixed incident leaves its fault record and alert rule behind | engine, content | 0.5–1 |
| [B36](#b36--platform-status-misses-components-a-scenario-installed) | `platform status` misses components a scenario installed | CLI, engine | 0.5–1 |

---

## B1 — Activate one scenario for two apps at once

**Problem.** A scenario can be active for exactly one app. Its name is the only
identity everywhere: the `.active` marker, the run lock (`LockKey(name)`), the
component inventory's `owner`, the API routes (`/api/v2/scenarios/{name}/…`),
the dashboard ConfigMap (`scenario-<name>-<file>`) and verify results. A second
activation overwrites the first, and `down` for one app uninstalls shared pieces
(Loki, Tempo, Kyverno, ArgoCD, dashboards) the other still uses.

**Already parallel-ready.** Scripts take `--app`/`--namespace` flags
([ADR-0015](adr/0015-learner-facing-workload-binding.md)), scenario dashboards
select the app with `$app`, and `labctl hosts add` reads hostnames from Ingress.
None of those need to change.

**Proposed approach.**

1. Make an activation `(scenario, app)`: marker `<name>@<app>.active`, lock key
   per activation plus a scenario-level key for shared components, inventory
   owner including the app, results keyed by both.
2. Reference-count shared components (helm charts, cluster-scoped manifests,
   ServiceMonitors, dashboards) so `down` removes them only with the last
   activation. This is the real engine work.
3. API: `/api/v2/scenarios/{name}/activations/{app}` or an `app` query parameter;
   CLI `verify`/`down`/`status` require `--app` when more than one is active.
4. UI: a scenario card lists its activations; verify and teardown per activation.
5. One traffic run per app (see [B2](#b2--k6-metrics-carry-no-app-label)).
6. Content, by readiness:
   - ready once the engine supports it — autoscaling-under-load,
     backup-restore-drill, secrets-management, mesh-traffic-management,
     cost-right-sizing, chaos-engineering;
   - needs redesign — env-promotion (fixed `env-dev/staging/prod` namespaces and
     one `env-metadata` ConfigMap per env), observability-sre (fixed
     PrometheusRule name, alert checks keyed on the scenario), security-compliance
     (cluster-wide ClusterPolicies change what the other activation is graded on);
   - single-instance by nature, refuse a second activation in preflight —
     node-drain-drill and cluster-upgrade-drill (they drain or replace nodes under
     every app), event-driven-arch and gitops-cicd (they do not use the app).

**Caveat.** Two apps under load on one k3d node contend for CPU, which is why
`labctl compare` runs apps one at a time. Parallel activation is for learning,
not for comparing performance grades.

**Start at.** `src/internal/scenario/engine.go` (`markActive`, `activationRecord`),
`src/internal/service/scenario/scenario.go` (`LockKey`),
`src/internal/store/migrations/0002_components.sql`.

---

## B2 — k6 metrics carry no app label

**Problem.** There is one cluster-wide k6 Job (`traffic-k6`) and its remote-written
metrics (`k6_http_reqs_total`, `k6_http_req_duration_p95`, …) have no `app`
label. Application Request Metrics works around it: the k6 panels match the App
selector against the `url` label (`url=~"https?://$app\\..*"`) and rebuild
`app` with `label_replace`. That holds only while the target's hostname starts
with the app name, and `k6_dropped_iterations_total` has no `url` label, so the
dropped share of "Offered vs served" belongs to no app. Two activations can
never both be under load.

**Proposed approach.** Pass the target app into the run (`labctl traffic start
--app` already resolves it) and tag it: `k6 run --tag app=<app>`, which the
Prometheus remote-write output turns into a label. Name the Job per app
(`traffic-k6-<app>`) so runs can coexist, and make `traffic stop`/`status` accept
`--app`. Then select the k6 series by `app=~"$app"` and drop the `url` matching
and the `label_replace` calls. Verify the label on a live lab before changing
dashboards.

**Start at.** `src/services/traffic/start.sh`, `src/internal/traffic/traffic.go`,
`src/internal/cli/traffic.go`,
`platform/monitoring/grafana/provisioning/dashboards/app-requests.json`.

---

## B3 — The shared request dashboard only sees the default metric name

**Problem.** An app declares its request histogram in `app.env`
(`APP_REQUEST_METRIC`, free-form). Scenario dashboards render the bound app's
name, but the platform dashboards ship as a raw ConfigMap and cannot be
templated, so Application Request Metrics queries
`http_server_request_duration_seconds` literally. A bring-your-own app that
declares a different name never appears there, and never appears in a scenario
dashboard's App selector either.

**Proposed approach.** Either make the contract require the semconv name (and
reject anything else in `workload.ParseContract`), or add a recording rule per
deployed app that normalises its histogram to one series name with the `app`
label, installed by `labctl app deploy`. Prefer the first unless a real app needs
the second.

**Start at.** `src/internal/workload/contract.go`, `apps/README.md`.

---

## B4 — Two scenarios can mutate the same app at once

**Problem.** Scenarios share the app they are bound to. cost-right-sizing inflates
its resource requests, autoscaling-under-load scales it and measures latency,
node-drain-drill and cluster-upgrade-drill scale it to several replicas, and
observability-sre rewrites its environment. Nothing warns when two such scenarios
are active for the same app, so one silently changes what the other grades.

**Proposed approach.** Declare in `scenario.yaml` whether a scenario mutates its
workload (e.g. `workload: exclusive`) and have preflight refuse, or warn about, a
second exclusive activation on the same app. Measure which scenarios actually
conflict before choosing refuse over warn.

**Start at.** `src/internal/scenario/engine.go` (preflight),
`docs/reference/scenario-schema.md`.

---

## B5 — Activating from the UI does not report missing hostnames

**Problem.** Only a lab on a `DOMAIN_SUFFIX` the user set is affected: the
default `*.localhost` names resolve without hosts entries, and `labctl init`
moves a lab on the old `*.k3d.local` default to them. On such a lab,
`labctl scenario up` and `labctl app deploy` print Ingress hostnames that
`/etc/hosts` does not list yet (`warnMissingHosts`). Activating from the UI
prints nothing, so a learner there first learns of a new hostname when the
browser fails to resolve it — env-promotion's `<app>-dev|staging|prod` hosts are
the common case.

**Proposed approach.** Expose the missing hosts on the scenario detail or status
response (reading `/etc/hosts` needs no privileges), and show a notice with the
`labctl hosts add` command after activation.

**Start at.** `src/internal/cli/hosts.go` (`unlistedHosts`),
`src/internal/httpapi/handlers.go`, `src/ui/src/views/Scenarios.tsx`.

---

## B6 — Incident scripts still fall back to go-api

**Problem.** Scenario scripts take the binding through
`scenarios/_lib/workload.sh` and fail loudly without one. Incident scripts
(`incidents/*/inject.sh`, `resolve.sh`, `checks/resolved.sh`,
`incidents/_lib/render.sh`) still read `${TARGET_WORKLOAD:-go-api}`. The engine
always exports the target, so this is not a live bug, but a missing binding would
silently act on go-api instead of failing.

**Proposed approach.** Give incidents the same rule: a shared helper that requires
`TARGET_NAMESPACE`/`TARGET_WORKLOAD` (flags for hand runs), and remove the
fallbacks. Review each fault with the incident review harness afterwards.

**Start at.** `incidents/_lib/`, [incidents/README.md](../incidents/README.md).

---

## B7 — A Docker VM restart silently kills k3d nodes

**Problem.** k3d nodes share the Docker VM's kernel, whose
`fs.inotify.max_user_instances` defaults to 128 on colima. `runtimes/k3d/up.sh`
raises it to 512 (`raise_inotify_limits`), but only when `up` runs. A VM restart
resets it, and a node's k3s agent later dies with `failed to create inotify fd:
too many open files`. The container stays `Up`, so nothing looks wrong from
Docker; the node goes NotReady, its pods sit in `Terminating` forever and their
replacements go `Pending`. Found on a live lab where one node had been NotReady
for 21 hours, wedging `env-prod` in `Terminating` and leaving the chaos,
external-secrets, gitops and Kafka workloads half-scheduled.

**Recovery today.** Raise the limit on every node, then restart the dead node's
container:

```bash
for n in $(docker ps --filter label=k3d.cluster=snowops --format '{{.Names}}'); do
  docker exec "$n" sysctl -w fs.inotify.max_user_instances=512
done
docker restart k3d-snowops-agent-1-0
```

**Proposed approach.** Re-apply the limit wherever labctl touches a running
cluster, not only at creation — `labctl status`, `labctl doctor`, and the start of
every run-engine operation are candidates. Have `labctl status` report a node
whose k3s process is gone while its container is up, with the recovery above.

**Start at.** `runtimes/k3d/up.sh` (`raise_inotify_limits`),
`src/internal/cli/status.go`, `src/internal/cli/doctor.go`.

---

## B9 — Latency below 5ms is invisible, and it hides tail amplification

**Problem.** The request histogram's first bucket ends at 5ms (`le` = 0.005, 0.01,
0.025, …, 10). Go and the JVM both answer the lab's routes in about a
millisecond, so every request lands in that bucket and `histogram_quantile` can
only interpolate inside it. Measured under k6 load on go-api, echo-server and
java-api at once: p50 = 2.5ms, p95 = 4.75ms and p99 = 4.95ms for every app, while
k6 measured p95 around 0.7ms. The dashboards now say so in the panel
description, but grading cannot be fixed with a description:
autoscaling-under-load's `latency-did-not-degrade` divides p99 by p50, which is
pinned at 4.95 / 2.5 = 1.98 until the p50 itself passes 5ms. With the default
`MaxTailAmplification` of 10, the check cannot fail while the service is fast,
and only starts measuring once it is already badly saturated.

**Proposed approach.** Add sub-5ms buckets to the app contract (for example
0.0005, 0.001, 0.0025 ahead of the semconv set) in go-api, echo-server, java-api
and the shared chart's documentation, and state the required bucket floor in
`apps/README.md`. Then re-measure tail amplification under the spike profile on
each app and recalibrate the `MaxTailAmplification` default, as the scenario
review harness does. Consider whether `labctl app verify` should reject a
histogram with no bucket below 5ms.

**Start at.** the histogram definitions in `apps/go-api`, `apps/echo-server` and
`apps/java-api`, `scenarios/autoscaling-under-load/scenario.yaml`,
[scenario review](authoring/scenario-review.md).

---

## B10 — Chaos network faults never reach the traffic generator

**Problem.** chaos-engineering's `network-delay` and `network-partition`
experiments act only between the workload and the `traefik` namespace
(`direction: both`, `target.selector.namespaces: [traefik]`). `labctl traffic`
runs k6 inside the cluster against the Service, which never crosses Traefik. So
under the scenario's own load the client-side panels cannot show either fault:
with a 300ms delay injected against echo-server, k6's p99 stayed at 1.4ms and the
server-side p99 did not move either. The dashboard panel was titled "where a
network delay shows up"; it now says the fault is not on k6's path and points to
the Explore tab's curl through the ingress. The `blast-radius-contained` check
and the scenario prose should be re-read with this in mind.

**Proposed approach.** Either route k6 through the ingress (target Traefik's
Service with the app's `Host` header, which `labctl traffic start` would need a
`--via-ingress` option for), or widen the experiments' target to also include
the `traffic` namespace so in-cluster load is affected. Re-review the scenario
with the scenario review harness afterwards.

**Start at.** `scenarios/chaos-engineering/manifests/chaos-experiments.yaml`,
`src/services/traffic/start.sh`, [scenario review](authoring/scenario-review.md).

---

## B11 — secrets-management only works for the app the platform was installed for

**Problem.** `platform/secrets/external-secrets/install.sh` creates the
SecretStore and the `<workload>-secret` ExternalSecret for whichever app is bound
when the platform component is installed (`${WORKLOAD_NAME:-go-api}`). The
scenario then assumes that ExternalSecret exists for the app it is activated
with. On a lab whose platform was installed for go-api, `labctl scenario up
secrets-management --app java-api` fails in `seed-baseline.sh` with
`externalsecrets.external-secrets.io "java-api-secret" not found` — and the
failed activation leaves `secret-consumer` and `env-consumer` running in the
`java-api` namespace, because a failed `up` does not roll back what it already
applied (compare [B8](#b8--scenario-down-reports-success-when-its-deletes-fail)).

**Proposed approach.** Move the per-app wiring out of the platform component:
the platform installs ESO, Vault and a ClusterSecretStore; the scenario applies
the `<workload>-secret` ExternalSecret for its own binding as a manifest
component, so any app works and teardown removes it. Separately, decide whether
a failed `scenario up` should uninstall the components it already applied.

**Start at.** `platform/secrets/external-secrets/install.sh`,
`scenarios/secrets-management/scenario.yaml`,
`scenarios/secrets-management/scripts/seed-baseline.sh`.

---

## B12 — Every k3d node promises the whole machine's memory

**Problem.** k3d nodes are containers on one Docker VM, and each kubelet reports
the VM's full memory as allocatable. On an 8GB colima VM the three nodes
advertised 8.3GB each, about 25GB in total, so the scheduler kept placing pods
(the server node alone reached 4.3GB of requests) until the VM had 34MB free and
a load average near 440. The API server then timed out, a node's k3s agent died,
and `scenario down` silently failed its deletes (see
[B7](#b7--a-docker-vm-restart-silently-kills-k3d-nodes) and
[B8](#b8--scenario-down-reports-success-when-its-deletes-fail)). Seven scenarios
active at once is enough to get there.

**Proposed approach.** Give each node a real share when the cluster is created:
`--kubelet-arg=system-reserved=memory=…` (or `kube-reserved`) sized so that the
nodes' allocatable memory sums to what the VM has, computed from `docker info`
in `runtimes/k3d/up.sh`. Have `labctl doctor` or `labctl status` warn when total
memory requests approach the VM's memory, and document a memory budget per
scenario so learners know how many they can run at once.

**Start at.** `runtimes/k3d/up.sh` (`create_cluster`), `src/internal/cli/doctor.go`.

---

## B16 — Web UI actions bypass the run engine

**Problem.** The `/api/v2` handlers for app deploy, destroy and build, platform
install and uninstall, scenario up and down, incident inject, services,
runtimes, lab restore and reset, and traffic start their work in a detached
`go func()`, or synchronously, through `internal/executor`. That executor calls
`exec.Command` with no context, takes no lock, and keeps its job history in
memory. None of that work can be cancelled, none of it is refused on a
conflict, none of it survives a restart, and none of it appears in the Runs
view. The CLI's `lab`, `platform`, `scenario` and `incident` commands go
through `internal/service` and the run engine. The two interfaces therefore
behave differently for the same operation, against both the
[architecture](architecture/ARCHITECTURE.md#1-the-shape-of-the-system) and the
"everything that shells out goes through `internal/run`" invariant. The
browser journeys for cancelling a run and resuming its log stream have to
start the run from the CLI (`$E2E_HOLD.labctl`) because no route creates one.

**What is already in place.** `internal/service/{platform,lab,scenario,incident}`
submit `run.Spec`s with lock keys. A run cancelled from another process stops
within a second (the worker watches its record), the Runs view cancels and
streams any run, and its log stream resumes after a dropped request.

**Proposed approach.** One route family per pull request, each with its
contract rows (`202` with the run ID, `409 lock_conflict` on a held lock,
operator-only) and the UI action switched from the job panel to the run:

1. Platform install and uninstall, onto `service/platform` (complete today).
2. Scenario up and down, onto `service/scenario`.
3. Incident inject and resolve, onto `service/incident`; the cancel and
   stream journeys then start their run from the browser.
4. Lab restore and reset, onto `service/lab`.
5. App build, deploy and destroy: a new `service/app`.
6. Traffic start and stop: a new `service/traffic` (GitHub issue #13).
7. Services and runtimes, then delete `internal/executor`, the in-memory job
   list and `/api/v2/jobs` with the job WebSocket, and point the UI's output
   panel at runs.

**Start at.** `src/internal/httpapi/handlers.go` (every `go func()`),
`src/internal/httpapi/incident.go`, `src/internal/httpapi/lab.go`,
`src/internal/httpapi/traffic.go`, `src/internal/service/`.
---

## B18 — `internal/cli` runs on package-level state

**Problem.** The CLI's configuration, executor and engines (`cfg`,
`scriptExec`, `reg`, `scenes`, `incEng`, `svcReg`, `rtm`) are package
variables that `PersistentPreRunE` assigns and `bindWorkload` reassigns. Most
commands are also package variables, registered in `init()`, with their flags
bound to more package variables. The newer `learn`, `challenge`, `lab`,
`runs`, `validate` and `doctor` trees are built by constructors instead. As a result:

- Tests share state and can't run in parallel.
- Command wiring depends on file init order.
- A reader can't tell from a function's signature what it depends on.

The CLI harness (`internal/cli/root_harness_test.go`) works around this:
`resetCommands` puts every flag back between runs, and the journey goldens
pin what each command prints, so a conversion that changes behaviour fails a
golden.

**Proposed approach.** Introduce an `app` struct holding what
`PersistentPreRunE` builds, and give each command a constructor that takes it
(`func scenarioCmd(a *app) *cobra.Command`). Convert one command group per PR,
starting with the smallest (`runtime`, `service`, `check`).
[Go conventions §6](GO-CONVENTIONS.md#6-cli-commands) already requires the
constructor form for new commands.

**Start at.** `src/internal/cli/root.go`.

---

## B19 — Smaller Go clean-ups

Each is small, safe and independent:

- `scenario.NewEngine` takes `monitoringNamespace ...string` to fake an
  optional parameter. The one production caller passes three arguments and then
  sets the field anyway. Drop the variadic and set the field.
- `runDoctor` and `dockerResourceWarning` accept a `nil` context and replace it
  with `Background`, only because their tests pass `nil`. Pass `t.Context()` in
  the tests and delete the nil checks.
- `labctl ui` launches the browser before checking that the port is free. It
  also probes the port with `net.Listen`, closes it and then listens again,
  which is racy. Build the listener once and hand it to `http.Server.Serve`,
  and open the browser only after that succeeds.
- `fs.Sub(webui.DistFS, "dist")` discards its error in `ui.go`.
- Seven JSON struct fields carry `omitempty` on a struct type, where it has no
  effect. Decide per field whether the API should omit the zero value
  (`omitzero`) or always send it (drop the tag). `omitzero` changes the
  response, so check the UI first.
- `pkg/checks` and `pkg/extension` shell out with `exec.CommandContext`
  directly. That's allowed, because `pkg/` can't import `internal/run`, but
  `pkg/checks.NewRunner` builds an `http.Client` with no `Timeout`. Only the
  per-check context bounds a request. Set a client timeout as a second guard.
- The largest files mix several concerns and are the hardest to review:
  `internal/scenario/engine.go` (1,490 lines), `internal/httpapi/handlers.go`
  (1,090), `internal/incident/incident.go` (755). Split them by concern
  (install, state, templates; one handler file per resource), moving code
  without changing it.

**Start at.** The file named in each bullet.

---

## B20 — `install.sh` leaves a fresh Mac stuck on `PATH`

**Problem.** On a fresh macOS user `install.sh` prints "`~/.local/bin` is not on
your PATH. Add this line to ~/.bashrc or ~/.zshrc" and the export line. A fresh
Mac has no `~/.zshrc`, and hand-writing the `echo … >> ~/.zshrc` gets the nested
quotes wrong easily, which breaks every new shell with `.zshrc:2: unmatched "`.

**Found.** Recording the macOS setup video: about seven minutes went on this
step (a Google search, two broken `echo` lines, a fix in `vi`).

**Proposed approach.** Detect the login shell from `$SHELL` and print one exact
command that is safe to paste: `echo 'export PATH="$HOME/.local/bin:$PATH"' >>
~/.zshrc && source ~/.zshrc` (`~/.bash_profile` for bash on macOS, `~/.bashrc`
on Linux). Say that the file is created if it is missing. Never edit the file
for the user.

**Start at.** `install.sh` (the `case ":$PATH:"` block), the README Install
section, `docs/getting-started/macos.md`, the install tests in `src/test/shell`.

---

## B21 — `init` floods the screen with `metrics.k8s.io` discovery errors

**Problem.** A clean `labctl init` prints dozens of lines such as
`E0929 … memcache.go:287] couldn't get resource list for metrics.k8s.io/v1beta1:
the server is currently unable to handle the request` and `… monitoring.coreos.com/v1:
the server could not find the requested resource` while Traefik and
kube-prometheus-stack install. They come from client-go API discovery in helm
and kubectl while the metrics APIService and the new CRDs are not served yet.
They are harmless, but a first-time user reads them as failure.

**Found.** Recording the macOS setup video, on a new k3d cluster.

**Proposed approach.** Find which calls trigger discovery. Wait for the
`v1beta1.metrics.k8s.io` APIService to be Available before those installs, or
filter only these known discovery lines from stderr and keep them under
`--verbose`. Real errors must still show.

**Start at.** `platform/ingress/traefik/install.sh`,
`platform/monitoring/metrics/prometheus/install.sh`, `platform/_lib/helm.sh`,
[R05](runbooks/R05-platform-components.md).

---

## B22 — cost-right-sizing cannot activate on a 2 CPU lab

**Problem.** `scenario up cost-right-sizing --deploy-prereqs` fails after five
minutes in the inflate stage with `error: timed out waiting for the condition`
(`Waiting for deployment "go-api" rollout to finish: 1 old replicas are pending
termination`). `inflate.sh` sets go-api's CPU request to `2000m`. On the minimum
lab (2 CPU / 4 GB Docker, which the README says runs one scenario at a time), no
node has 2 CPUs free once the platform runs, so the new pod stays Pending and
the rollout never finishes.

**Found.** Recording the UI and CLI tour for the setup video, on a 2 CPU / 4 GB
colima.

**Proposed approach.** Size the inflated request from what the lab can
schedule (for example a share of the node's allocatable CPU, still far above
the right-sized 50m), or inflate replicas' memory and a smaller CPU request that
fits. Add the scenario's real peak to its resources check so `up` refuses early
instead of timing out. Re-run the scenario review on a 2 CPU lab.

**Start at.** `scenarios/cost-right-sizing/scripts/inflate.sh`, the scenario's
resource figures in [Resources](resources.md).

---

## B23 — Scenario Explore links point at dashboards that do not exist yet

**Problem.** The Explore tab of an inactive scenario links to its Grafana
dashboard (for example `/d/autoscaling-under-load`). The dashboard is installed
only when the scenario activates, so the link opens Grafana's "Not found" page.

**Found.** Recording the UI tour for the setup video.

**Proposed approach.** Show dashboard links as "available after you activate
this scenario" (disabled) while the scenario is inactive, or link to the
dashboards list instead.

**Start at.** The scenario details panel in `src/ui/src/`, and the explore
links in each `scenario.yaml`.

---

## B28 — The pod memory panel cannot show one small pod

**Problem.** "Pod memory working set" on the Pod Resources dashboard is
`sum by (namespace, pod) (container_memory_working_set_bytes{container!=""})`
with no dashboard variable, so every pod in the cluster shares one linear
axis. go-api uses 4–8Mi and sits flat on the floor under Prometheus and
Grafana. `oom-kill` sends the learner there twice: hint 3 ("Grafana's container
memory panels") and `solution.md` ("the pod memory panel shows usage slamming
into a flat ceiling right before each restart"). Neither can be seen. The only
way to read one pod is to click it in the legend, and the panel does not draw
the container's limit, so there is no ceiling to slam into.

**Found.** Recording VID-14 (OOMKilled). The take picks the fixed pod in the
legend to show its memory going level after the fix. During the fault there is
nothing to show: each restart is a new container with one or two samples.

**Proposed approach.** Give the dashboard a namespace variable (default: all)
and draw the memory limit as a dashed series on the panel
(`kube_pod_container_resource_limits{resource="memory"}`), so a pod near its
limit is visible as such. Then reword hint 3 and the solution to what the panel
really shows: a pod killed every twenty seconds leaves dots, not a line, and
`kubectl describe pod` is where the limit is read.

**Start at.** `platform/monitoring/grafana/provisioning/dashboards/pod-resources.json`,
`incidents/oom-kill/hints.md`, `incidents/oom-kill/solution.md`.

---

## B29 — oom-kill's output gives the fault away, and its solution describes an older fault

**Problem.** Two things, both in `incidents/oom-kill`:

1. `inject.sh` says "Nothing printed here names the fault", then prints
   "Sizing the change from its resting working set of 4Mi.", "Applying a
   resource change to go-api/go-api..." and, when the first limit does not
   bite, "Still healthy — tightening to 7Mi." The lab UI shows these lines in
   its output panel while the learner waits for the fault.
2. `solution.md` says the limit "was cut to a quarter of its own memory
   request" and "will read as a quarter of the request below it".
   [incidents/README.md](../incidents/README.md) says the same. `inject.sh`
   sizes the limit from the pod's resting working set (three times `kubectl
   top`), halves it until the first OOMKill, and sets the request to half the
   limit. A learner comparing the two numbers finds the request below the
   limit, not above it.

**Found.** Recording VID-14 (OOMKilled). The plan closes the output panel
before the inject, reads the limit with `kubectl describe pod`, and the script
follows the take, not the solution.

**Proposed approach.** Print only neutral lines from `inject.sh` ("Applying a
change…", "Waiting for it to take effect…"), with the sizing detail behind
`--verbose`, and extend the answer-leak test in
`src/test/shell/incident_faults.bats` to fail on the words that give it away
("memory", "limit", "working set"). Rewrite the "What happened" and "Diagnosis
path" sections of `solution.md`, and the calibration paragraph of the README,
from what `inject.sh` does today.

**Start at.** `incidents/oom-kill/inject.sh`, `incidents/oom-kill/solution.md`,
`incidents/README.md`, `src/test/shell/incident_faults.bats`.

---

## B30 — `rollout undo` brings old fault markers back onto the Deployment

**Problem.** Faults keep their bookkeeping in a record of their own
(`incidents/_lib/state.sh`), so a new drill writes nothing on the workload.
A lab that ran drills before that still has `labfault-*` annotations on its
older ReplicaSets, and `kubectl rollout undo` copies the target ReplicaSet's
annotations back onto the Deployment. After a rollback on such a lab the
Deployment carried `labfault-oom-kill: injected`,
`labfault-oom-kill-original-limit: 128Mi` and `-original-request: 32Mi` again,
with no such fault active. No script reads them any more, but
`kubectl describe deploy` prints them, and one from an earlier run of the same
drill is that drill's answer.

**Found.** Recording VID-15 (bad deploy, rollback), in the off-camera run. The
take reads the image with `kubectl get deploy -o wide` and from the revisions,
never from the Deployment's YAML.

**Proposed approach.** Have every `resolve.sh` clear all `labfault-*`
annotations from the Deployment and its ReplicaSets, not only its own:
`clear_marks` in `incidents/_lib/marks.sh` takes the keys to remove, so give it
a mode that lists them from the object. Cover it in
`src/test/shell/incident_faults.bats`.

**Start at.** `incidents/_lib/marks.sh`, the `clear_marks` calls in
`incidents/*/resolve.sh`.

---

## B35 — A hand-fixed incident leaves its fault record and alert rule behind

**Problem.** When `labctl incident status` sees the detection check pass, it
closes the incident as solved by hand, but what `inject.sh` added for its own
bookkeeping stays: the record (`configmap/labfault-<name>` in `kube-system`)
and, for every fault with `expectAlert`, its alert rule (a `PrometheusRule` in
the monitoring namespace). Only `resolve.sh` removes them. A later forced
`labctl incident resolve <name>` then restores the values recorded at inject
over whatever the learner has done since. Found by the cluster suite on kind;
its runner runs `resolve` after the hand fix to tidy up, which hides it.

**Proposed approach.** Every `resolve.sh` is already required, and tested in
`incident_faults.bats`, to leave a hand fix alone, so it is the tidy-up:

1. When `Status` closes an incident as solved by hand, submit the fault's
   `resolve.sh` through the run engine as a hidden run of its own kind
   (`incident.tidy`), after the MTTR record is written, so the history still
   says "manual".
2. Cover it in `internal/incident` and `internal/service/incident`: a passing
   status submits the tidy run, a failing one does not, a silent incident's
   tidy run stays hidden.
3. Drop the tidy-up `resolve` from `src/test/cluster/run.sh`, so the nightly
   proves that nothing is left after a hand fix alone.

**Start at.** `src/internal/incident/incident.go` (`Status`, the
`result.Pass` branch), `src/internal/service/incident/`, `src/test/cluster/run.sh`.
---

## B36 — `platform status` misses components a scenario installed

**Problem.** `labctl platform status` lists components from the run history,
which only `labctl platform up` writes. A component that `scenario up
--deploy-prereqs` installs as a prerequisite is installed synchronously by
`ensurePlatformPrereqs` (`reg.Install`, not the run engine) and never recorded,
so on a lab running KEDA, Vault, Kafka and a dozen more Helm releases the
command said "No platform components have been installed through labctl yet."
The API's `GET /platform` and `labctl platform status --live` read the cluster
and are right. Found by the cluster suite on kind.

**Proposed approach.**

1. Make the cluster the source of truth for the default `platform status`:
   one function, shared with `handlePlatformStatus`, that reads every
   provider's state from a single `helm list -A` (with explicit status flags,
   which Helm 3 and 4 both accept) and one namespace listing, with the last run
   from the history as a column. `--live` then has nothing left to add.
2. Install prerequisites through `service/platform`, so they get a run, a lock
   and the inventory record like any `platform up` (part of B16 for the API).
3. A CLI journey step: activate a scenario with `--deploy-prereqs` against the
   fixture lab, then `platform status` lists the component it installed.

**Start at.** `src/internal/cli/platform_lifecycle.go`
(`platformStatusFromStore`), `src/internal/cli/prereqs.go`
(`ensurePlatformPrereqs`), `src/internal/httpapi/handlers.go`
(`handlePlatformStatus`).
