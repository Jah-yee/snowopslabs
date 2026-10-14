#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# gitops-cicd grades changes made through Git and reconciled by ArgoCD. Each
# check is run against the lab as activation leaves it, the solved lab, and
# the shortcut of changing the cluster with kubectl instead of Git.

load 'helpers/stub'

setup() {
  stub_setup
  ROOT="$(project_root)"
  CHECKS="$ROOT/scenarios/gitops-cicd/checks"
  # The lab right after activation: one seed commit, the demo app in sync, the
  # broken app degraded, the Service tracked in Git and running.
  export COMMITS=1 SEED_IMAGE=nginx:1.27.3-alpine SEED_REPLICAS=2
  export GIT_IMAGE=nginx:1.27.3-alpine GIT_REPLICAS=2
  export LIVE_IMAGE=nginx:1.27.3-alpine LIVE_REPLICAS=2
  export FILES="$(printf 'demo/deployment.yaml\ndemo/service.yaml\nbroken/deployment.yaml')"
  export LIVE_SERVICE=yes
  export SYNC_demo=Synced HEALTH_demo=Healthy SYNC_broken=Synced HEALTH_broken=Degraded
  stub_script kubectl <<'STUB'
manifest() {
  printf 'spec:\n  replicas: %s\n  template:\n    spec:\n      containers:\n        - name: web\n          image: %s\n' "$2" "$1"
}
app_field() {
  case "$1" in *"application gitops-broken"*) app=broken ;; *) app=demo ;; esac
  var="$2_$app"
  printf '%s' "${!var-}"
}
case "$*" in
  *"get pod -l app=git-server"*) printf '%s' "${GIT_POD-git-server-abc}" ;;

  # git, run inside the git-server pod
  *"-- git -C /srv/git/platform.git rev-list --count HEAD"*) echo "$COMMITS" ;;
  *"-- git -C /srv/git/platform.git rev-list --max-parents=0 HEAD"*) echo "seed000" ;;
  *"-- git -C /srv/git/platform.git show HEAD:demo/deployment.yaml"*)
    [ "${DEMO_AT_HEAD:-yes}" = yes ] || exit 128
    manifest "$GIT_IMAGE" "$GIT_REPLICAS"
    ;;
  *"-- git -C /srv/git/platform.git show seed000:demo/deployment.yaml"*) manifest "$SEED_IMAGE" "$SEED_REPLICAS" ;;
  *"-- git -C /srv/git/platform.git show HEAD:broken/deployment.yaml"*) manifest "${BROKEN_IMAGE-nginx:1.27.3-alpine}" 1 ;;
  *"-- git -C /srv/git/platform.git ls-tree"*) [ -z "$FILES" ] || printf '%s\n' "$FILES" ;;
  *"-- git -C /srv/git/platform.git log -p"*) [ -z "${GIT_HISTORY-}" ] || printf '%s\n' "$GIT_HISTORY" ;;

  # ArgoCD Applications
  *"get application"*"jsonpath={.status.sync.status}"*) app_field "$*" SYNC ;;
  *"get application"*"jsonpath={.status.health.status}"*) app_field "$*" HEALTH ;;
  *"get application gitops-broken"*) [ "${BROKEN_APP:-yes}" = yes ] || exit 1 ;;
  *"get application gitops-demo"*) [ "${DEMO_APP:-yes}" = yes ] || exit 1 ;;

  # the live demo workload
  *"-n gitops-demo get deployment gitops-demo"*"image}"*) printf '%s' "${LIVE_IMAGE-}" ;;
  *"-n gitops-demo get deployment gitops-demo"*"replicas}"*) printf '%s' "${LIVE_REPLICAS-}" ;;
  *"-n gitops-demo get service gitops-demo"*) [ "$LIVE_SERVICE" = yes ] || exit 1 ;;
  *"-n gitops-demo get events"*) [ -z "${EVENTS-}" ] || printf '%s\n' "$EVENTS" ;;

  *"get configmap selfheal-witness -o jsonpath"*) printf '%s' "${HEAL_RECORD-}" ;;
  *"get configmap selfheal-witness"*) [ -n "${HEAL_RECORD-}" ] || exit 1 ;;
  *"create configmap"*) echo "kind: ConfigMap" ;;
esac
exit 0
STUB
}

teardown() {
  stub_teardown
}

check() {
  run bash "$CHECKS/$1.sh"
}

# ── the work has not been done ────────────────────────────────────────────────

@test "the learner-graded checks are pending on the lab as activation leaves it" {
  for c in check-learner-pushed broken-app-repaired prune-removed-a-resource self-heal-observed; do
    check "$c"
    [ "$status" -ne 0 ] || { echo "$c passed with no work done: $output"; return 1; }
    [[ "$output" == *"PENDING"* ]] || { echo "$c: $output"; return 1; }
  done
}

@test "the health checks pass on the lab as activation leaves it" {
  for c in check-sync-healthy check-git-matches-live; do
    check "$c"
    [ "$status" -eq 0 ] || { echo "$c: $output"; return 1; }
  done
}

# ── learner pushed ────────────────────────────────────────────────────────────

@test "learner-pushed passes when a pushed commit changes what the cluster is asked to run" {
  COMMITS=2 GIT_IMAGE=nginx:1.27.4-alpine GIT_REPLICAS=3 check check-learner-pushed
  [ "$status" -eq 0 ]
  [[ "$output" == *"now declares nginx:1.27.4-alpine 3"* ]] || false
}

@test "learner-pushed is not satisfied by commits that change nothing deployed" {
  COMMITS=4 check check-learner-pushed
  [ "$status" -ne 0 ]
  [[ "$output" == *"still declares the seed values"* ]] || false
}

@test "learner-pushed is pending when the manifest was pushed away or the repo is down" {
  COMMITS=2 DEMO_AT_HEAD=no check check-learner-pushed
  [ "$status" -ne 0 ]
  [[ "$output" == *"demo/deployment.yaml is missing at HEAD"* ]] || false
  GIT_POD="" check check-learner-pushed
  [ "$status" -ne 0 ]
  [[ "$output" == *"no running git-server pod"* ]] || false
}

# ── Git matches live ──────────────────────────────────────────────────────────

@test "git-matches-live fails the kubectl shortcut: the cluster changed, Git did not" {
  LIVE_REPLICAS=7 check check-git-matches-live
  [ "$status" -ne 0 ]
  [[ "$output" == *"Git declares 2 replicas; the cluster runs 7"* ]] || false

  LIVE_IMAGE=nginx:1.27.4-alpine check check-git-matches-live
  [ "$status" -ne 0 ]
  [[ "$output" == *"Git declares image nginx:1.27.3-alpine; the cluster runs nginx:1.27.4-alpine"* ]] || false
}

@test "git-matches-live fails a push the cluster has not converged on" {
  GIT_IMAGE=nginx:1.27.4-alpine GIT_REPLICAS=3 check check-git-matches-live
  [ "$status" -ne 0 ]
  [[ "$output" == *"do not fix this with kubectl"* ]] || false
}

@test "git-matches-live fails when either side cannot be read" {
  LIVE_IMAGE="" check check-git-matches-live
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not present"* ]] || false
  DEMO_AT_HEAD=no check check-git-matches-live
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not read demo/deployment.yaml"* ]] || false
  GIT_POD="" check check-git-matches-live
  [ "$status" -ne 0 ]
}

# ── sync and health ───────────────────────────────────────────────────────────

@test "sync-healthy fails each way the Application can be off" {
  while IFS='|' read -r var value want; do
    env "$var=$value" bash "$CHECKS/check-sync-healthy.sh" >"$STUB_DIR/out" 2>&1 && {
      echo "$var=$value passed"
      return 1
    }
    grep -q "$want" "$STUB_DIR/out" || { cat "$STUB_DIR/out"; return 1; }
  done <<'CASES'
SYNC_demo|OutOfSync|not Synced
SYNC_demo||'Unknown', not Synced
HEALTH_demo|Degraded|not Healthy
HEALTH_demo|Progressing|not Healthy
DEMO_APP|no|does not exist
CASES
}

# ── the broken app ────────────────────────────────────────────────────────────

@test "broken-app-repaired passes once the Application is Synced and Healthy, naming Git's image" {
  HEALTH_broken=Healthy BROKEN_IMAGE=nginx:1.27.4-alpine check broken-app-repaired
  [ "$status" -eq 0 ]
  [[ "$output" == *"Git now declares nginx:1.27.4-alpine"* ]] || false
}

@test "broken-app-repaired is pending for a kubectl fix ArgoCD sees as drift" {
  SYNC_broken=OutOfSync HEALTH_broken=Healthy check broken-app-repaired
  [ "$status" -ne 0 ]
  [[ "$output" == *"sync=OutOfSync health=Healthy"* ]] || false
}

@test "broken-app-repaired is pending when the Application was deleted" {
  BROKEN_APP=no check broken-app-repaired
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not present"* ]] || false
}

# ── prune ─────────────────────────────────────────────────────────────────────

without_service="$(printf 'demo/deployment.yaml\nbroken/deployment.yaml')"

@test "prune passes when the file is gone from Git and the Service from the cluster" {
  FILES="$without_service" LIVE_SERVICE=no check prune-removed-a-resource
  [ "$status" -eq 0 ]
}

@test "prune is pending for the kubectl shortcut: the Service deleted, the file still in Git" {
  LIVE_SERVICE=no check prune-removed-a-resource
  [ "$status" -ne 0 ]
  [[ "$output" == *"still tracked in Git"* ]] || false
}

@test "prune fails a deletion in Git the cluster has not reconciled" {
  FILES="$without_service" check prune-removed-a-resource
  [ "$status" -ne 0 ]
  [[ "$output" == *"is still running"* ]] || false
}

@test "prune is pending when the repo cannot be read" {
  FILES="" check prune-removed-a-resource
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not read the lab repo"* ]] || false
}

# ── selfHeal ──────────────────────────────────────────────────────────────────

@test "self-heal passes on a scale-down to Git's count from a count Git never declared, and records it" {
  EVENTS="Scaled down replica set gitops-demo-5d8 from 7 to 2" GIT_HISTORY="+  replicas: 2" check self-heal-observed
  [ "$status" -eq 0 ]
  [[ "$output" == *"back from 7 to the 2 replicas Git declares"* ]] || false
  assert_called kubectl "create configmap selfheal-witness"
}

@test "self-heal is not satisfied by a scale-down that Git itself asked for" {
  EVENTS="Scaled down replica set gitops-demo-5d8 from 3 to 2" \
    GIT_HISTORY="$(printf '+  replicas: 2\n+  replicas: 3')" check self-heal-observed
  [ "$status" -ne 0 ]
  refute_called kubectl "create configmap"
}

@test "self-heal is not satisfied by a scale-down to some other count" {
  EVENTS="Scaled down replica set gitops-demo-5d8 from 7 to 5" GIT_HISTORY="+  replicas: 2" check self-heal-observed
  [ "$status" -ne 0 ]
}

@test "self-heal passes from its record after the events have aged out" {
  HEAL_RECORD="ArgoCD scaled gitops-demo/gitops-demo back from 7 to the 2 replicas Git declares" check self-heal-observed
  [ "$status" -eq 0 ]
  [[ "$output" == *"back from 7"* ]] || false
}

@test "self-heal is pending when the declared count cannot be read" {
  DEMO_AT_HEAD=no check self-heal-observed
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not read the declared replica count"* ]] || false
}
