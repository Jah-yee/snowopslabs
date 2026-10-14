#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# security-compliance grades a workload fixed at the source, policies that are
# enforced and not merely written, an exemption that covers one workload only,
# and a namespace whose isolation holds on the wire. Each check is run against
# the solved lab, the lab before the work, and the shortcuts that turn the
# report green without the property being true.

load 'helpers/stub'

setup() {
  stub_setup
  ROOT="$(project_root)"
  CHECKS="$ROOT/scenarios/security-compliance/checks"
  export WORKLOAD_NAME=cart WORKLOAD_NAMESPACE=shop MONITORING_NAMESPACE=monitoring
  stub_script kubectl <<'STUB'
# Container fields are per index: ESC/NONROOT/CPU/MEM/IMAGE for container 0,
# the same names with _1 for container 1.
field() {
  case "$1" in *"containers[1]"*) suffix=_1 ;; *) suffix="" ;; esac
  var="$2$suffix"
  printf '%s' "${!var-}"
}
deny_selector='{}'
deny_types='["Ingress","Egress"]'
case "$*" in
  *"apply"*"--dry-run=server"*)
    case "$(cat)" in
      *"compliance.snowops.net/exempt"*) [ "${ADMIT_LABELLED:-no}" = yes ] || exit 1 ;;
      *) [ "${ADMIT_ROOT:-yes}" = yes ] || exit 1 ;;
    esac
    ;;
  *"get clusterpolicy"*"rules[0].validate.failureAction"*) printf '%s' "${ACTION-Audit}" ;;
  *"get clusterpolicy"*"validationFailureAction"*) printf '%s' "${OLD_STYLE_ACTION-}" ;;

  *"get deployment legacy-reporter -o jsonpath={.status.readyReplicas}"*) printf '%s' "${LEGACY_READY-1}" ;;
  *"get deployment legacy-reporter"*) [ "${LEGACY_EXISTS:-yes}" = yes ] || exit 1 ;;

  *"get deployment cart -o jsonpath={range .spec.template.spec.containers"*) printf '%s\n' ${CONTAINERS-app} ;;
  *"get deployment cart"*"allowPrivilegeEscalation}"*) field "$*" ESC ;;
  *"get deployment cart"*"runAsNonRoot}"*) field "$*" NONROOT ;;
  *"get deployment cart"*"limits.cpu}"*) field "$*" CPU ;;
  *"get deployment cart"*"limits.memory}"*) field "$*" MEM ;;
  *"get deployment cart"*"].image}"*) field "$*" IMAGE ;;
  *"get deployment cart"*) [ "${WORKLOAD_EXISTS:-yes}" = yes ] || exit 1 ;;

  *"get networkpolicies -o name"*) [ -z "${POLICY_NAMES-set}" ] || printf '%s\n' ${POLICY_NAMES-default-deny-all allow-dns allow-ingress allow-monitoring} ;;
  *"get networkpolicy default-deny-all -o jsonpath={.spec.podSelector}"*) printf '%s' "${DENY_SELECTOR-$deny_selector}" ;;
  *"get networkpolicy default-deny-all -o jsonpath={.spec.policyTypes}"*) printf '%s' "${DENY_TYPES-$deny_types}" ;;
  *"get networkpolicy default-deny-all -o jsonpath={.spec.ingress}"*) printf '%s' "${DENY_RULES-}" ;;
  *"get networkpolicy default-deny-all"*) [ "${DENY_EXISTS:-yes}" = yes ] || exit 1 ;;
  *"get networkpolicies -o go-template"*) printf '%s' "${OPEN_RULES-}" ;;
  *"get networkpolicies -o jsonpath={.items[*].spec.egress"*) printf '%s' "${EGRESS_PORTS-53 53 8080}" ;;
  *"get networkpolicies -o jsonpath={.items[*].spec.ingress"*)
    default_from='{"kubernetes.io/metadata.name":"traefik"} {"kubernetes.io/metadata.name":"monitoring"}'
    printf '%s' "${INGRESS_FROM-$default_from}"
    ;;
  *" run isolation-probe-"*)
    # With the Pod Security policies enforced, admission refuses a pod that
    # does not declare a non-root, non-escalating container with limits.
    if [ "${POLICIES_ENFORCED:-no}" = yes ]; then
      case "$*" in
        *'"runAsNonRoot":true'*'"allowPrivilegeEscalation":false'*'"limits"'*) ;;
        *) echo "admission webhook denied the request: require-non-root-user" >&2; exit 1 ;;
      esac
    fi
    printf '%s' "${PROBE_CODE-000}"
    ;;
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

# compliant sets a workload that satisfies all four policies.
compliant() {
  export ESC=false NONROOT=true CPU=100m MEM=64Mi IMAGE=registry.lab:5000/cart:v1.2.0
}

# enforced sets policies in Enforce with a webhook that rejects a root pod.
enforced() {
  export ACTION=Enforce ADMIT_ROOT=no
}

# ── workload-compliant ────────────────────────────────────────────────────────

@test "workload-compliant fails on the workload as activation leaves it, naming each violation" {
  export IMAGE=cart:latest
  check check-workload-compliant
  [ "$status" -ne 0 ]
  [[ "$output" == *"allowPrivilegeEscalation is 'unset'"* ]] || false
  [[ "$output" == *"runAsNonRoot is 'unset'"* ]] || false
  [[ "$output" == *"limits.cpu is unset"* ]] || false
  [[ "$output" == *"limits.memory is unset"* ]] || false
  [[ "$output" == *"uses the :latest tag"* ]] || false
}

@test "workload-compliant passes a workload fixed at the source" {
  compliant
  check check-workload-compliant
  [ "$status" -eq 0 ]
}

@test "workload-compliant fails each single violation on its own" {
  while IFS='|' read -r var value want; do
    compliant
    export "$var=$value"
    check check-workload-compliant
    [ "$status" -ne 0 ] || { echo "$var=$value passed"; return 1; }
    [[ "$output" == *"$want"* ]] || { echo "$var=$value: $output"; return 1; }
  done <<'EOF_CASES'
ESC|true|must be false
ESC||must be false
NONROOT|false|must be true
CPU||limits.cpu is unset
MEM||limits.memory is unset
IMAGE|registry.lab:5000/cart:latest|uses the :latest tag
IMAGE|cart|has no explicit tag
EOF_CASES
}

@test "workload-compliant checks every container, not just the first" {
  compliant
  export CONTAINERS="app sidecar" ESC_1=false NONROOT_1=false CPU_1=10m MEM_1=16Mi IMAGE_1=envoy:v1.30
  check check-workload-compliant
  [ "$status" -ne 0 ]
  [[ "$output" == *"container 'sidecar': securityContext.runAsNonRoot is 'false'"* ]] || false
  [[ "$output" != *"container 'app'"* ]] || false
}

@test "workload-compliant fails when the workload is not deployed" {
  WORKLOAD_EXISTS=no check check-workload-compliant
  [ "$status" -ne 0 ]
  [[ "$output" == *"deployment/cart not found in shop"* ]] || false
}

# ── policies-enforcing ────────────────────────────────────────────────────────

@test "policies-enforcing fails while the policies are in Audit" {
  check check-policies-enforcing
  [ "$status" -ne 0 ]
  [[ "$output" == *"still in Audit mode"* ]] || false
}

@test "policies-enforcing passes when Enforce is set and a root pod is rejected" {
  enforced
  check check-policies-enforcing
  [ "$status" -eq 0 ]
}

@test "policies-enforcing fails the wrong fix: Enforce on paper while the webhook admits a root pod" {
  ACTION=Enforce ADMIT_ROOT=yes check check-policies-enforcing
  [ "$status" -ne 0 ]
  [[ "$output" == *"ACCEPTED a Pod"* ]] || false
}

@test "policies-enforcing reads the field older policies carry" {
  ACTION="" OLD_STYLE_ACTION=Enforce ADMIT_ROOT=no check check-policies-enforcing
  [ "$status" -eq 0 ]
}

@test "policies-enforcing fails when a policy is missing" {
  ACTION="" check check-policies-enforcing
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]] || false
}

# ── legacy-exception ──────────────────────────────────────────────────────────

@test "legacy-exception fails before anything is enforced" {
  check check-legacy-exception
  [ "$status" -ne 0 ]
  [[ "$output" == *"still in Audit"* ]] || false
}

@test "legacy-exception passes a scoped exemption: labelled pods in, unlabelled root pods out" {
  enforced
  ADMIT_LABELLED=yes check check-legacy-exception
  [ "$status" -eq 0 ]
}

@test "legacy-exception fails when nothing exempts the labelled pod" {
  enforced
  ADMIT_LABELLED=no check check-legacy-exception
  [ "$status" -ne 0 ]
  [[ "$output" == *"still rejected"* ]] || false
}

@test "legacy-exception fails the wrong fix: an exemption wide enough to admit any root pod" {
  ACTION=Enforce ADMIT_ROOT=yes ADMIT_LABELLED=yes check check-legacy-exception
  [ "$status" -ne 0 ]
  [[ "$output" == *"too wide"* ]] || false
}

@test "legacy-exception fails while the legacy workload has no ready replica" {
  enforced
  for ready in 0 ""; do
    ADMIT_LABELLED=yes LEGACY_READY="$ready" check check-legacy-exception
    [ "$status" -ne 0 ]
    [[ "$output" == *"no ready replicas"* ]] || false
  done
}

@test "legacy-exception fails when the legacy workload is gone" {
  LEGACY_EXISTS=no check check-legacy-exception
  [ "$status" -ne 0 ]
  [[ "$output" == *"legacy-reporter not found"* ]] || false
}

# ── namespace-isolation ───────────────────────────────────────────────────────

@test "namespace-isolation passes the intended policy set when the probe is refused" {
  check check-namespace-isolation
  [ "$status" -eq 0 ]
  [[ "$output" == *"Enforcement confirmed live"* ]] || false
}

@test "namespace-isolation fails a namespace with no policies" {
  POLICY_NAMES="" check check-namespace-isolation
  [ "$status" -ne 0 ]
  [[ "$output" == *"wide open"* ]] || false
}

@test "namespace-isolation fails each way the policy set can be hollowed out" {
  while IFS='|' read -r var value want; do
    export "$var=$value"
    check check-namespace-isolation
    [ "$status" -ne 0 ] || { echo "$var=$value passed"; return 1; }
    [[ "$output" == *"$want"* ]] || { echo "$var=$value: $output"; return 1; }
    unset "$var"
  done <<'EOF_CASES'
DENY_EXISTS|no|default-deny-all is missing
DENY_SELECTOR|{"matchLabels":{"app":"other"}}|denies only some pods
DENY_TYPES|["Ingress"]|does not cover Egress
DENY_TYPES|["Egress"]|does not cover Ingress
DENY_RULES|[{"from":[]}]|carries allow rules
OPEN_RULES|allow-all accepts traffic from ANY source (an ingress rule with no "from")|cancels default-deny-all
EGRESS_PORTS|8080|no egress rule allows DNS
INGRESS_FROM|{"kubernetes.io/metadata.name":"monitoring"}|no ingress rule allows the traefik namespace
INGRESS_FROM|{"kubernetes.io/metadata.name":"traefik"}|no ingress rule allows the monitoring namespace
EOF_CASES
}

@test "namespace-isolation fails policies that read correctly but are not enforced" {
  PROBE_CODE=200 check check-namespace-isolation
  [ "$status" -ne 0 ]
  [[ "$output" == *"got HTTP 200"* ]] || false
  [[ "$output" == *"not being ENFORCED"* ]] || false
}

@test "namespace-isolation does not take a probe that never answered for a refusal" {
  PROBE_CODE="" check check-namespace-isolation
  [ "$status" -ne 0 ]
  [[ "$output" == *"gave no answer, so enforcement is unverified"* ]] || false
}

@test "namespace-isolation still probes once the learner enforces the Pod Security policies" {
  POLICIES_ENFORCED=yes check check-namespace-isolation
  [ "$status" -eq 0 ]
  [[ "$output" == *"Enforcement confirmed live"* ]] || false
}

@test "namespace-isolation removes its probe pod" {
  check check-namespace-isolation
  assert_called kubectl "-n default delete pod isolation-probe-"
}

@test "every check refuses to run without a workload binding" {
  unset WORKLOAD_NAME WORKLOAD_NAMESPACE
  for c in check-workload-compliant check-policies-enforcing check-legacy-exception check-namespace-isolation; do
    check "$c"
    [ "$status" -eq 2 ]
  done
}
