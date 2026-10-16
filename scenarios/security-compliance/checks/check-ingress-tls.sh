#!/usr/bin/env bash
# shellcheck disable=SC2001  # sed is the clearest way to indent a multi-line block
set -euo pipefail
. "$(dirname "$0")/../../_lib/workload.sh"

# Grades the last mile of the certificate task: a Certificate that reached Ready
# has proved cert-manager works, but nothing is actually protected until the
# Ingress serves it. So this asserts on the wire, not on the manifest.
#
# The handshake is the outcome. Traefik answers 443 either way - with its own
# CN=TRAEFIK DEFAULT CERT when no route matches, or with the lab-signed leaf
# once the Ingress references the Secret. Only the second one passes.

NS="${WORKLOAD_NAMESPACE}"
INGRESS="${WORKLOAD_NAME}"
HOST="${WORKLOAD_NAME}.${DOMAIN_SUFFIX:-${CLUSTER_NAME:-snowops}.localhost}"
SECRET="${WORKLOAD_NAME}-tls-secret"
# A *.localhost name is always this machine, but openssl asks the system
# resolver, which often cannot resolve one, so it dials loopback and sends the
# name as SNI. HTTPS_PORT is the port the lab's ingress actually bound.
case "$HOST" in
  *.localhost) CONNECT="127.0.0.1:${HTTPS_PORT:-443}" ;;
  *) CONNECT="${HOST}:${HTTPS_PORT:-443}" ;;
esac

if ! kubectl -n "$NS" get ingress "$INGRESS" >/dev/null 2>&1; then
  echo "FAIL: ingress/$INGRESS not found in $NS." >&2
  echo "      Deploy the app: labctl app deploy ${WORKLOAD_NAME}" >&2
  exit 1
fi

tls_secret=$(kubectl -n "$NS" get ingress "$INGRESS" \
  -o jsonpath="{.spec.tls[?(@.secretName=='$SECRET')].secretName}" 2>/dev/null || echo "")

if [ "$tls_secret" != "$SECRET" ]; then
  echo "FAIL: ingress/$INGRESS does not reference the certificate Secret '$SECRET'." >&2
  echo "      A Ready Certificate protects nothing until the Ingress serves it. Wire it up:" >&2
  echo "        kubectl -n $NS patch ingress $INGRESS --type=merge -p \\" >&2
  echo "          '{\"metadata\":{\"annotations\":{\"traefik.ingress.kubernetes.io/router.entrypoints\":\"web,websecure\"}}," >&2
  echo "            \"spec\":{\"tls\":[{\"hosts\":[\"$HOST\"],\"secretName\":\"$SECRET\"}]}}'" >&2
  exit 1
fi

# What is actually presented on the wire for this SNI name?
served=$(echo | openssl s_client -connect "$CONNECT" -servername "$HOST" 2>/dev/null |
  openssl x509 -noout -issuer -subject 2>/dev/null || echo "")

if [ -z "$served" ]; then
  echo "FAIL: nothing completed a TLS handshake for $HOST at $CONNECT." >&2
  echo "      Check the ingress controller is running and listening on its HTTPS port:" >&2
  echo "        kubectl get pods -A -l app.kubernetes.io/name=traefik" >&2
  exit 1
fi

# OpenSSL prints "issuer=CN = lab-ca" and LibreSSL "issuer= /CN=lab-ca", so the
# issuer is compared with its spaces and slashes removed.
issuer=$(printf '%s\n' "$served" | sed -n 's/^issuer=//p' | tr -d ' /')

case "$issuer" in
  "CN=lab-ca") ;;
  *)
    echo "FAIL: ${HOST} is served by a certificate the lab CA did not sign:" >&2
    echo "$served" | sed 's/^/        /' >&2
    echo "      'CN=TRAEFIK DEFAULT CERT' means the Ingress TLS block is not routing to" >&2
    echo "      $SECRET - check the host in spec.tls[].hosts matches $HOST exactly, and" >&2
    echo "      that the websecure entrypoint is enabled on the router." >&2
    exit 1
    ;;
esac

echo "${HOST} is served by the lab-signed leaf:"
echo "$served" | sed 's/^/  /'
