#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# runtimes/_lib/move-domain.sh moves a lab's hostnames to another domain suffix
# in place: resources naming a host under the old suffix are rewritten, the
# rest are left untouched, and the cluster record takes the new suffix.

load 'helpers/stub'

setup() {
  stub_setup
  ROOT="$(project_root)"
  STATE="$STUB_DIR/state"
  mkdir -p "$STATE"
  export STATE
  export SNOWOPS_HOME="$STUB_DIR/snowops"
  mkdir -p "$SNOWOPS_HOME/clusters"
  printf 'HTTP_PORT=8080\nHTTPS_PORT=8443\nDOMAIN_SUFFIX=k3d.local\n' >"$SNOWOPS_HOME/clusters/lab.env"

  cat >"$STATE/monitoring-grafana.yaml" <<'EOF'
metadata:
  creationTimestamp: "2026-09-11T11:45:18Z"
  generation: 1
  name: grafana
  resourceVersion: "736"
  uid: 877f651b-32e0-47d2-8617-845bf3cd18e5
  annotations:
    note: http://grafana.k3d.local:8080/login
spec:
  rules:
    - host: grafana.k3d.local
    - host: grafana.k3d.localdomain
EOF
  cat >"$STATE/apps-go-api.yaml" <<'EOF'
spec:
  rules:
    - host: go-api.example.com
EOF
  cat >"$STATE/kube-system-traefik-dashboard.yaml" <<'EOF'
spec:
  routes:
    - match: Host(`traefik.k3d.local`)
EOF

  # kubectl lists and prints the fixtures above; the Certificate CRD is absent;
  # replace records what it was given.
  cat >"$STUB_BIN/kubectl" <<'EOF'
#!/usr/bin/env bash
case "$1 $2 $3" in
  "get ingresses -A") printf 'monitoring grafana\napps go-api\n' ;;
  "get ingressroutes.traefik.io -A") printf 'kube-system traefik-dashboard\n' ;;
  "get certificates.cert-manager.io -A") echo "error: the server doesn't have a resource type" >&2; exit 1 ;;
  "get "*" -n") cat "$STATE/$4-$5.yaml" ;;
  "replace -f -") { cat; echo ---; } >>"$STATE/replaced" ;;
esac
EOF
  chmod +x "$STUB_BIN/kubectl"
}

teardown() {
  stub_teardown
}

@test "move-domain rewrites hosts under the old suffix and records the new one" {
  run bash "$ROOT/runtimes/_lib/move-domain.sh" lab k3d.local lab.localhost
  [ "$status" -eq 0 ]
  grep -q "host: grafana.lab.localhost$" "$STATE/replaced"
  grep -q "http://grafana.lab.localhost:8080/login" "$STATE/replaced"
  grep -q 'Host(`traefik.lab.localhost`)' "$STATE/replaced"
  grep -qx "HTTP_PORT=8080" "$SNOWOPS_HOME/clusters/lab.env"
  grep -qx "DOMAIN_SUFFIX=lab.localhost" "$SNOWOPS_HOME/clusters/lab.env"
}

@test "move-domain leaves other names and other resources alone" {
  run bash "$ROOT/runtimes/_lib/move-domain.sh" lab k3d.local lab.localhost
  [ "$status" -eq 0 ]
  grep -q "host: grafana.k3d.localdomain" "$STATE/replaced"
  ! grep -q "go-api" "$STATE/replaced"
  [[ "$output" != *"apps/go-api"* ]] || false
}

@test "move-domain sends no server-set metadata, so a later kubectl apply still works" {
  run bash "$ROOT/runtimes/_lib/move-domain.sh" lab k3d.local lab.localhost
  [ "$status" -eq 0 ]
  grep -q "^  name: grafana$" "$STATE/replaced"
  ! grep -Eq "^  (resourceVersion|uid|creationTimestamp|generation):" "$STATE/replaced"
}
