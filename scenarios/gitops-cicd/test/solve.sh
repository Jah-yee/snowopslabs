#!/bin/sh
# The drill a learner walks, for the cluster suite: clone the lab repo, push a
# new declared state, scale the demo by hand and let selfHeal revert it, prune
# a manifest from Git, and repair the broken app's image tag in Git.
set -eu
. "$PROJECT_ROOT/src/test/cluster/solve-lib.sh"
port="${GIT_PORT:-9418}"
work=$(mktemp -d "${TMPDIR:-/tmp}/gitops-solve.XXXXXX")
kubectl -n gitops port-forward svc/git-server "$port:9418" >/dev/null 2>&1 &
forward=$!
trap 'kill "$forward" 2>/dev/null || :; rm -rf "$work"' EXIT

wait_until 30 "the git server answering on port $port" \
  git ls-remote "git://127.0.0.1:$port/platform.git"
git clone "git://127.0.0.1:$port/platform.git" "$work/platform"
cd "$work/platform"
git config user.email solve@snowops.test
git config user.name "cluster suite"

# Sync now rather than waiting for ArgoCD's poll.
sync() {
  kubectl -n argocd patch application "$1" --type merge \
    -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"main"}}}'
}
replicas_are() {
  [ "$(kubectl -n gitops-demo get deployment gitops-demo -o "jsonpath={.$1}")" = "$2" ]
}

sed -e 's|nginx:1.27.3-alpine|nginx:1.27.4-alpine|' -e 's|replicas: 2|replicas: 3|' \
  demo/deployment.yaml >demo/deployment.yaml.new
mv demo/deployment.yaml.new demo/deployment.yaml
git commit -am 'promote nginx 1.27.4, scale to 3'
git push origin main
sync gitops-demo
wait_until 180 "gitops-demo running 3 ready replicas" replicas_are status.readyReplicas 3
# A scale during the rollout is split across both ReplicaSets, and the
# self-heal check grades a single ReplicaSet returning to the declared count.
kubectl -n gitops-demo rollout status deployment/gitops-demo --timeout=180s

kubectl -n gitops-demo scale deployment/gitops-demo --replicas=7
wait_until 180 "ArgoCD reverting gitops-demo to 3 replicas" replicas_are spec.replicas 3

git rm demo/service.yaml
git commit -m 'drop the service'
git push origin main
sync gitops-demo
service_gone() { ! kubectl -n gitops-demo get service gitops-demo >/dev/null 2>&1; }
wait_until 180 "ArgoCD pruning Service gitops-demo" service_gone

sed 's|nginx:1.27.3-alpine-THIS-TAG-DOES-NOT-EXIST|nginx:1.27.3-alpine|' \
  broken/deployment.yaml >broken/deployment.yaml.new
mv broken/deployment.yaml.new broken/deployment.yaml
git commit -am 'fix the image tag that never existed'
git push origin main
sync gitops-broken
healthy() {
  [ "$(kubectl -n argocd get application gitops-broken -o 'jsonpath={.status.sync.status}/{.status.health.status}')" = Synced/Healthy ]
}
wait_until 300 "gitops-broken Synced and Healthy" healthy
