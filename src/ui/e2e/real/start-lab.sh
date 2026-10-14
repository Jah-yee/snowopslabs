#!/bin/sh
# Starts the real labctl server for the browser journeys: a private copy of the
# fixture lab, the stand-in kubectl, helm, docker and k3d first on PATH, and an
# empty home directory. Nothing it does reaches a real cluster or the
# developer's own lab. Usage: [LAB_AUTH=on] start-lab.sh <port>
set -eu

port="${1:?usage: start-lab.sh <port>}"
here=$(cd "$(dirname "$0")" && pwd)
src=$(cd "$here/../../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/labctl-e2e.XXXXXX")
server=""
cleanup() {
  [ -n "$server" ] && kill "$server" 2>/dev/null
  [ -z "${E2E_HOLD:-}" ] || rm -f "$E2E_HOLD.labctl"
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 0' INT TERM

cp -R "$src/test/fixtures/lab" "$work/lab"
cp -R "$src/test/fixtures/bin" "$work/bin"
mkdir -p "$work/home"

# labctl ui opens the URL in a browser; these stand-ins make that a no-op.
for opener in open xdg-open wslview; do
  printf '#!/bin/sh\nexit 0\n' >"$work/bin/$opener"
  chmod +x "$work/bin/$opener"
done

(cd "$src" && go build -o "$work/labctl" ./cmd/labctl)

export PATH="$work/bin:/usr/bin:/bin" HOME="$work/home" SNOWOPS_HOME="$work/home/.snowops"
export APP_NAME=demo-app CLUSTER_NAME=e2e

# With LAB_AUTH=on the server requires a session: one operator and one
# participant, both with the password "e2e-password".
if [ "${LAB_AUTH:-off}" = on ]; then
  for user in olive:operator pat:participant; do
    "$work/labctl" --project-dir "$work/lab" users add "${user%%:*}" \
      --role "${user#*:}" --password e2e-password >/dev/null
  done
  export LABCTL_AUTH=true
fi

# With E2E_HOLD set, $E2E_HOLD.labctl runs labctl against this lab, so a
# journey can start a run from the CLI and watch it in the browser.
if [ -n "${E2E_HOLD:-}" ]; then
  {
    echo '#!/bin/sh'
    echo "export PATH='$PATH' HOME='$HOME' SNOWOPS_HOME='$SNOWOPS_HOME' APP_NAME=demo-app CLUSTER_NAME=e2e E2E_HOLD='$E2E_HOLD'"
    echo "exec '$work/labctl' --project-dir '$work/lab' \"\$@\""
  } >"$E2E_HOLD.labctl"
  chmod +x "$E2E_HOLD.labctl"
fi

"$work/labctl" ui --port "$port" --bind 127.0.0.1 \
  --project-dir "$work/lab" --ui-dir "$src/ui/dist" &
server=$!
wait "$server"
