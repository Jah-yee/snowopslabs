#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# Detection checks grade a learner's fix. Each one is run against the state of
# a solved lab, the state the fault leaves behind, and the wrong fixes that
# silence the symptom without repairing the cause. A check that passes any
# state but the first tells a learner they are done when they are not.

load 'helpers/stub'

setup() {
  stub_setup
  ROOT="$(project_root)"
  export TARGET_NAMESPACE=shop TARGET_WORKLOAD=cart
  export DOMAIN_SUFFIX=lab.test INGRESS_URL_SUFFIX=lab.test:8081
  stub_script curl <<'STUB'
if [ "${HTTP_CODE:-200}" = "000" ]; then printf '000'; exit 7; fi
printf '%s' "${HTTP_CODE:-200}"
STUB
}

teardown() {
  stub_teardown
}

check() {
  run bash "$ROOT/incidents/$1/checks/resolved.sh"
}

# ── A workload that must be serving: crashloop-bad-config, bad-deploy-rollout ──

# REPLICAS, READY and ROLLED_OUT describe the Deployment the check asks about.
workload_stub() {
  stub_script kubectl <<'STUB'
case "$*" in
  *"rollout status"*) [ "${ROLLED_OUT:-yes}" = yes ] || exit 1 ;;
  *"get deploy"*"jsonpath={.spec.replicas}"*)
    [ "${DEPLOY_EXISTS:-yes}" = yes ] || exit 1
    echo "${REPLICAS:-2}"
    ;;
  *"get deploy"*"jsonpath={.status.readyReplicas}"*) echo "${READY-2}" ;;
  *"get pods"*) echo "cart-7d9f-abcde   false   CrashLoopBackOff   7" ;;
esac
STUB
}

serving_checks() {
  echo crashloop-bad-config
  echo bad-deploy-rollout
}

@test "serving checks pass when every replica is ready after a completed rollout" {
  workload_stub
  for fault in $(serving_checks); do
    check "$fault"
    [ "$status" -eq 0 ] || { echo "$fault: $output"; return 1; }
  done
}

@test "serving checks fail while the fault is in: the rollout has not completed" {
  workload_stub
  for fault in $(serving_checks); do
    ROLLED_OUT=no READY="" check "$fault"
    [ "$status" -ne 0 ] || { echo "$fault passed a stalled rollout"; return 1; }
    [[ "$output" == *"rollout of shop/cart has not completed"* ]] || false
    [[ "$output" == *"CrashLoopBackOff"* ]] || false
  done
}

@test "serving checks fail the wrong fix: scaled to zero" {
  workload_stub
  for fault in $(serving_checks); do
    REPLICAS=0 READY="" check "$fault"
    [ "$status" -ne 0 ] || { echo "$fault passed a workload scaled to zero"; return 1; }
    [[ "$output" == *"scaled to 0 replicas"* ]] || false
  done
}

@test "serving checks fail when fewer replicas are ready than asked for" {
  workload_stub
  for fault in $(serving_checks); do
    REPLICAS=3 READY=1 check "$fault"
    [ "$status" -ne 0 ]
    [[ "$output" == *"1/3 replicas ready"* ]] || false
  done
}

@test "serving checks fail when the workload is gone" {
  workload_stub
  for fault in $(serving_checks); do
    DEPLOY_EXISTS=no check "$fault"
    [ "$status" -ne 0 ]
    [[ "$output" == *"deployment shop/cart not found"* ]] || false
  done
}

# ── oom-kill ──────────────────────────────────────────────────────────────────

# RS lists "<owner>=<pod-template-hash>" for each ReplicaSet scaled above zero;
# TERMINATED is the last-terminated reason of the pods in the serving one.
oom_stub() {
  stub_script kubectl <<'STUB'
case "$*" in
  *"rollout status"*) [ "${ROLLED_OUT:-yes}" = yes ] || exit 1 ;;
  *"get deploy"*"jsonpath={.spec.replicas}"*) echo "${REPLICAS-2}" ;;
  *"get deploy"*"jsonpath={.status.readyReplicas}"*) echo "${READY-2}" ;;
  *"get rs"*) [ -z "${RS-cart=abc123}" ] || printf '%s\n' "${RS-cart=abc123}" ;;
  *"get pods"*"pod-template-hash=abc123"*) printf '%s' "${TERMINATED:-}" ;;
  *"get pods"*) echo "cart-abc123-xyz   false   OOMKilled   4" ;;
esac
STUB
}

@test "oom-kill passes when the serving pods have not been OOMKilled" {
  oom_stub
  check oom-kill
  [ "$status" -eq 0 ]
}

@test "oom-kill fails while the fault is in: the serving pods are OOMKilled" {
  oom_stub
  TERMINATED="OOMKilled OOMKilled" check oom-kill
  [ "$status" -ne 0 ]
  [[ "$output" == *"OOMKilled"* ]] || false
}

@test "oom-kill fails while the rollout is stalled, and shows the pods" {
  oom_stub
  ROLLED_OUT=no check oom-kill
  [ "$status" -ne 0 ]
  [[ "$output" == *"rollout of shop/cart has not completed"* ]] || false
  [[ "$output" == *"cart-abc123-xyz"* ]] || false
}

@test "oom-kill ignores the history of pods outside the serving ReplicaSet" {
  oom_stub
  RS="$(printf 'other=zzz999\ncart=abc123')" check oom-kill
  [ "$status" -eq 0 ]
}

@test "oom-kill fails the wrong fix: scaled to zero, and says so" {
  oom_stub
  REPLICAS=0 READY="" RS="" check oom-kill
  [ "$status" -ne 0 ]
  [[ "$output" == *"scaled to 0 replicas"* ]] || false
}

@test "oom-kill fails with a reason when the serving ReplicaSet cannot be found" {
  oom_stub
  RS="" check oom-kill
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot find the ReplicaSet serving shop/cart"* ]] || false
}

@test "oom-kill fails when the workload is gone" {
  oom_stub
  REPLICAS="" check oom-kill
  [ "$status" -ne 0 ]
  [[ "$output" == *"deployment shop/cart not found"* ]] || false
}

# ── service-selector-broken ───────────────────────────────────────────────────

selector_stub() {
  stub_script kubectl <<'STUB'
healthy_selector='{"app.kubernetes.io/name":"cart"}'
healthy_labels='{"app.kubernetes.io/name":"cart","tier":"web"}'
case "$*" in
  *"get svc"*"jsonpath={.spec.selector}"*) printf '%s' "${SELECTOR-$healthy_selector}" ;;
  *"get deploy"*"jsonpath={.spec.template.metadata.labels}"*) printf '%s' "${LABELS-$healthy_labels}" ;;
esac
STUB
}

@test "service-selector-broken passes when the Service selects the pod template's labels" {
  selector_stub
  check service-selector-broken
  [ "$status" -eq 0 ]
  [[ "$output" == *"answers 200"* ]] || false
}

@test "service-selector-broken fails while the fault is in, naming the label that differs" {
  selector_stub
  SELECTOR='{"app.kubernetes.io/name":"cart-v2"}' check service-selector-broken
  [ "$status" -ne 0 ]
  [[ "$output" == *'Service wants "cart-v2", pods are labelled "cart"'* ]] || false
}

@test "service-selector-broken fails the wrong fix: a pod relabelled to match, so the URL answers" {
  selector_stub
  SELECTOR='{"app.kubernetes.io/name":"cart-v2"}' HTTP_CODE=200 check service-selector-broken
  [ "$status" -ne 0 ]
}

@test "service-selector-broken fails when one key of several is wrong" {
  selector_stub
  SELECTOR='{"app.kubernetes.io/name":"cart","tier":"api"}' check service-selector-broken
  [ "$status" -ne 0 ]
  [[ "$output" == *'tier: Service wants "api", pods are labelled "web"'* ]] || false
}

@test "service-selector-broken fails the wrong fix: the selector deleted outright" {
  selector_stub
  SELECTOR='{}' check service-selector-broken
  [ "$status" -ne 0 ]
  [[ "$output" == *"no selector at all"* ]] || false
}

@test "service-selector-broken fails when the selector matches but nothing answers" {
  selector_stub
  HTTP_CODE=503 check service-selector-broken
  [ "$status" -ne 0 ]
  [[ "$output" == *"returned 503"* ]] || false
}

# ── network-blackhole ─────────────────────────────────────────────────────────

# POLICIES lists "<name>|<policyTypes>|<ingress rules>" for each NetworkPolicy
# in the workload's namespace.
policy_stub() {
  stub_script kubectl <<'STUB'
case "$*" in
  *"get networkpolicy"*)
    [ "${CLUSTER:-up}" = up ] || exit 1
    [ -z "${POLICIES:-}" ] || printf '%s\n' "$POLICIES"
    ;;
esac
STUB
}

@test "network-blackhole passes when no policy denies ingress and the app answers" {
  policy_stub
  check network-blackhole
  [ "$status" -eq 0 ]
}

@test "network-blackhole fails while the fault is in, naming the policy" {
  policy_stub
  POLICIES='default-deny-ingress|["Ingress"]|' HTTP_CODE=000 check network-blackhole
  [ "$status" -ne 0 ]
  [[ "$output" == *"default-deny-ingress"* ]] || false
}

@test "network-blackhole fails a deny-all policy even while old connections still answer" {
  policy_stub
  POLICIES='default-deny-ingress|["Ingress"]|[]' HTTP_CODE=200 check network-blackhole
  [ "$status" -ne 0 ]
}

@test "network-blackhole passes a policy the learner opened with an allow rule" {
  policy_stub
  POLICIES='default-deny-ingress|["Ingress"]|[{"from":[{"namespaceSelector":{}}]}]' check network-blackhole
  [ "$status" -eq 0 ]
}

@test "network-blackhole leaves another deny baseline with its own allows alone" {
  policy_stub
  POLICIES="$(printf 'default-deny-all|["Ingress","Egress"]|\nallow-ingress-traffic|["Ingress"]|[{"from":[]}]')" \
    check network-blackhole
  [ "$status" -eq 0 ]
}

@test "network-blackhole fails when the policy is gone but the app does not answer" {
  policy_stub
  HTTP_CODE=502 check network-blackhole
  [ "$status" -ne 0 ]
  [[ "$output" == *"returned 502"* ]] || false
}

@test "network-blackhole fails with a reason when the policies cannot be listed" {
  policy_stub
  CLUSTER=down check network-blackhole
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not list the NetworkPolicies in shop"* ]] || false
}

# ── noisy-neighbor ────────────────────────────────────────────────────────────

# LIMITS is one CPU limit per running pod (an empty line for a pod with none).
neighbor_stub() {
  export TARGET_NAMESPACE=labfault-batch TARGET_WORKLOAD=report-batch
  stub_script kubectl <<'STUB'
case "$*" in
  "get deployment"*) [ "${DEPLOY_EXISTS:-yes}" = yes ] || exit 1 ;;
  *"get deploy"*"jsonpath={.spec.replicas}"*) echo "${REPLICAS:-2}" ;;
  *"get rs"*) echo "2026-01-01T00:00:00Z ${REPLICAS:-2} abc123" ;;
  *"get pods"*"resources.limits.cpu"*) printf '%s\n' "${LIMITS-}" ;;
  *"get pods"*"nodeName"*) printf 'node-1' ;;
  *"get node"*) printf '%s' "${NODE_CPU:-4}" ;;
esac
STUB
}

@test "noisy-neighbor passes when the batch workload is gone or scaled to zero" {
  neighbor_stub
  DEPLOY_EXISTS=no check noisy-neighbor
  [ "$status" -eq 0 ]
  REPLICAS=0 check noisy-neighbor
  [ "$status" -eq 0 ]
}

@test "noisy-neighbor fails while the fault is in: the pods carry no CPU limit" {
  neighbor_stub
  LIMITS="" check noisy-neighbor
  [ "$status" -ne 0 ]
  [[ "$output" == *"only 0 of 2 pod(s)"* ]] || false
}

@test "noisy-neighbor fails when only some pods are capped" {
  neighbor_stub
  LIMITS="$(printf '500m\n\n')" check noisy-neighbor
  [ "$status" -ne 0 ]
  [[ "$output" == *"only 1 of 2 pod(s)"* ]] || false
}

@test "noisy-neighbor fails the wrong fix: a limit too large to bound anything" {
  neighbor_stub
  LIMITS="$(printf '4\n4')" check noisy-neighbor
  [ "$status" -ne 0 ]
  [[ "$output" == *"too big to be one"* ]] || false
}

@test "noisy-neighbor passes when every pod is capped within half the node" {
  neighbor_stub
  LIMITS="$(printf '500m\n500m')" check noisy-neighbor
  [ "$status" -eq 0 ]
  [[ "$output" == *"capped at 500m, 1000m in total on a 4000m node"* ]] || false
}

# ── pending-unschedulable ─────────────────────────────────────────────────────

# PENDING lists the workload's Pending pods; PODS=fail makes listing them fail.
pending_stub() {
  stub_script kubectl <<'STUB'
case "$*" in
  *"go-template"*) printf '%s' "${SELECTOR-app.kubernetes.io/name=cart,tier=web,}" ;;
  *"get pods -l app.kubernetes.io/name=cart,tier=web --field-selector=status.phase=Pending,spec.nodeName= "*)
    [ "${PODS:-ok}" = ok ] || exit 1
    [ -z "${PENDING:-}" ] || printf '%s\n' $PENDING
    ;;
  *"rollout status"*) [ "${ROLLED_OUT:-yes}" = yes ] || exit 1 ;;
  *"get deploy"*"jsonpath={.spec.replicas}"*)
    [ "${DEPLOY_EXISTS:-yes}" = yes ] || exit 1
    echo "${REPLICAS:-4}"
    ;;
  *"get deploy"*"jsonpath={.status.readyReplicas}"*) echo "${READY-4}" ;;
  *"get pods"*) echo "cart-7d9f-abcde   true   <none>   0" ;;
esac
STUB
}

@test "pending-unschedulable passes when every replica is scheduled and ready" {
  pending_stub
  check pending-unschedulable
  [ "$status" -eq 0 ]
  [[ "$output" == *"every replica of shop/cart is scheduled and ready"* ]] || false
}

@test "pending-unschedulable fails while the fault is in: replicas are Pending" {
  pending_stub
  PENDING="pod/cart-new-1 pod/cart-new-2 pod/cart-new-3" ROLLED_OUT=no READY=2 check pending-unschedulable
  [ "$status" -ne 0 ]
  [[ "$output" == *"3 pod(s) of shop/cart are Pending"* ]] || false
}

@test "pending-unschedulable fails the wrong fix: scaled back to the old count, one new pod still Pending" {
  pending_stub
  PENDING="pod/cart-new-1" REPLICAS=2 READY=2 ROLLED_OUT=no check pending-unschedulable
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 pod(s) of shop/cart are Pending"* ]] || false
}

@test "pending-unschedulable fails while recreated pods have not finished rolling out" {
  pending_stub
  ROLLED_OUT=no READY=2 check pending-unschedulable
  [ "$status" -ne 0 ]
  [[ "$output" == *"rollout of shop/cart has not completed"* ]] || false
}

@test "pending-unschedulable fails the wrong fix: scaled to zero" {
  pending_stub
  REPLICAS=0 check pending-unschedulable
  [ "$status" -ne 0 ]
  [[ "$output" == *"scaled to 0 replicas"* ]] || false
}

@test "pending-unschedulable fails with a reason when the pods cannot be listed" {
  pending_stub
  PODS=fail check pending-unschedulable
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not list the pods of shop/cart"* ]] || false
}

@test "pending-unschedulable fails with a reason when the selector cannot be read" {
  pending_stub
  SELECTOR="" check pending-unschedulable
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot read the pod selector of shop/cart"* ]] || false
}

@test "pending-unschedulable fails when the workload is gone" {
  pending_stub
  DEPLOY_EXISTS=no check pending-unschedulable
  [ "$status" -ne 0 ]
  [[ "$output" == *"deployment shop/cart not found"* ]] || false
}
