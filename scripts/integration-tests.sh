#!/usr/bin/env bash
#
# Run the full tiberius integration test suite against a throwaway MS SQL Server
# container (built from docker/docker-mssql-2022.dockerfile, which bakes in the
# custom CA / server certificate the custom-cert tests need).
#
# The container is always torn down on exit (success, failure or Ctrl-C).
#
# Usage:
#   scripts/integration-tests.sh                 # default: rustls + aws_lc_rs
#   PROVIDER=ring scripts/integration-tests.sh   # rustls + ring
#   PROVIDER=native-tls scripts/integration-tests.sh
#   FEATURES="tds73,rustls,aws_lc_rs" scripts/integration-tests.sh   # full override
#
set -euo pipefail

# --- config ---------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER="tiberius-it-mssql"
IMAGE="tiberius-it-mssql:local"
DOCKERFILE="docker/docker-mssql-2022.dockerfile"
SA_PASSWORD='<YourStrong@Passw0rd>'   # hard-coded in tests/custom-cert.rs
PORT="1433"
PROVIDER="${PROVIDER:-aws_lc_rs}"     # aws_lc_rs | ring | native-tls

# Feature set: TLS-validating run across all three runtimes. Overridable.
if [[ -z "${FEATURES:-}" ]]; then
  RUNTIMES="tds73,sql-browser-tokio,sql-browser-async-std,sql-browser-smol,chrono,time,rust_decimal,bigdecimal"
  case "$PROVIDER" in
    aws_lc_rs) FEATURES="$RUNTIMES,rustls,aws_lc_rs" ;;
    ring)      FEATURES="$RUNTIMES,rustls,ring" ;;
    native-tls) FEATURES="$RUNTIMES,native-tls" ;;
    *) echo "Unknown PROVIDER '$PROVIDER' (expected aws_lc_rs|ring|native-tls)" >&2; exit 2 ;;
  esac
fi

cd "$REPO_ROOT"

# --- 0. preflight: docker present & running -------------------------------
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not installed or not on PATH." >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "ERROR: docker daemon is not running / not reachable." >&2
  exit 1
fi

# --- 1. refresh server cert if expired ------------------------------------
# tests/custom-cert.rs validates the server cert against docker/certs/customCA.crt.
if ! openssl x509 -checkend 0 -noout -in docker/certs/server.crt >/dev/null 2>&1; then
  echo ">> server certificate missing or expired -- regenerating (signed by customCA)"
  ( cd docker/certs && rm -f src.txt && ./generate-signed-cert.sh server )
fi

# --- 2. cleanup hook ------------------------------------------------------
cleanup() {
  echo ">> tearing down container $CONTAINER"
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

# --- 3. build + run the cert-configured MSSQL -----------------------------
echo ">> building $IMAGE"
docker build -f "$DOCKERFILE" -t "$IMAGE" docker/

echo ">> starting $CONTAINER"
docker run -d --name "$CONTAINER" \
  -e ACCEPT_EULA=Y \
  -e "MSSQL_SA_PASSWORD=$SA_PASSWORD" \
  -p "${PORT}:1433" \
  "$IMAGE" >/dev/null

# --- 4. wait until SQL Server accepts logins ------------------------------
echo ">> waiting for MS SQL Server to become ready"
ready=0
for i in $(seq 1 60); do
  for sqlcmd in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd; do
    if docker exec "$CONTAINER" "$sqlcmd" -S localhost -U sa -P "$SA_PASSWORD" -C \
         -Q "SELECT 1" >/dev/null 2>&1; then
      ready=1; break
    fi
  done
  [[ $ready -eq 1 ]] && { echo ">> ready after $((i*5))s"; break; }
  sleep 5
done
if [[ $ready -eq 0 ]]; then
  echo "ERROR: MS SQL Server did not become ready in time." >&2
  docker logs "$CONTAINER" 2>&1 | tail -20 >&2
  exit 1
fi

# --- 5. run the suite -----------------------------------------------------
# bulk/query/deadlocks read this; custom-cert.rs hard-codes its own config.
export TIBERIUS_TEST_CONNECTION_STRING="server=tcp:localhost,${PORT};uid=sa;pwd=${SA_PASSWORD};TrustServerCertificate=true"

echo ">> running test suite (PROVIDER=$PROVIDER)"
echo ">> features: $FEATURES"
cargo test --no-default-features --features "$FEATURES" --no-fail-fast
