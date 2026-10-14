#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# security-compliance's check-ingress-tls.sh grades the TLS handshake. openssl
# asks the system resolver, which often cannot resolve a *.localhost name, so a
# *.localhost host is dialled on loopback with the name sent as SNI, on the
# HTTPS port the lab bound.

load 'helpers/stub'

setup() {
  stub_setup
  ROOT="$(project_root)"
  CHECK="$ROOT/scenarios/security-compliance/checks/check-ingress-tls.sh"
  export WORKLOAD_NAME=go-api WORKLOAD_NAMESPACE=go-api
  # The Ingress exists and references the certificate Secret.
  cat >"$STUB_BIN/kubectl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *jsonpath*) echo "go-api-tls-secret" ;;
esac
EOF
  # s_client records where it dialled; x509 reports $ISSUER, by default the lab
  # CA as OpenSSL 3 prints it.
  cat >"$STUB_BIN/openssl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  s_client) echo "$*" >"$STUB_DIR/dialled"; cat >/dev/null ;;
  x509) cat >/dev/null; printf 'issuer=%s\nsubject=CN = go-api\n' "${ISSUER:-CN = lab-ca}" ;;
esac
EOF
  chmod +x "$STUB_BIN/kubectl" "$STUB_BIN/openssl"
}

teardown() {
  stub_teardown
}

@test "a *.localhost host is dialled on loopback at the lab's HTTPS port, with its name as SNI" {
  DOMAIN_SUFFIX=snowops.localhost HTTPS_PORT=8443 run bash "$CHECK"
  [ "$status" -eq 0 ]
  grep -q -- "-connect 127.0.0.1:8443 -servername go-api.snowops.localhost" "$STUB_DIR/dialled"
}

@test "another suffix is dialled by name" {
  DOMAIN_SUFFIX=lab.internal HTTPS_PORT=443 run bash "$CHECK"
  [ "$status" -eq 0 ]
  grep -q -- "-connect go-api.lab.internal:443 -servername go-api.lab.internal" "$STUB_DIR/dialled"
}

@test "the lab CA is recognised however openssl or LibreSSL formats the issuer" {
  for issuer in "CN = lab-ca" " /CN=lab-ca" "CN=lab-ca"; do
    ISSUER="$issuer" DOMAIN_SUFFIX=snowops.localhost run bash "$CHECK"
    [ "$status" -eq 0 ]
  done
}

@test "a certificate from another issuer fails" {
  for issuer in "CN = TRAEFIK DEFAULT CERT" "CN = lab-ca-evil"; do
    ISSUER="$issuer" DOMAIN_SUFFIX=snowops.localhost run bash "$CHECK"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not sign"* ]] || false
  done
}
