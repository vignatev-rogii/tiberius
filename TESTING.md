# Integration tests

The connector's integration tests (`bulk`, `query`, `deadlocks`, `custom-cert`, …)
need a real **MS SQL Server**. A throwaway one is provisioned via Docker, with the
custom CA / server certificate baked in (for `custom-cert.rs`). The container is
always torn down afterwards.

Unit tests need nothing: `cargo test --lib`.

## Run

**Local dev (Rust + Docker on host):**
```bash
scripts/integration-tests.sh
```

**CI / hermetic (Docker only, no Rust on host):**
```bash
docker compose -f docker-compose.test.yml up \
  --build --abort-on-container-exit --exit-code-from tests
```

Both run the full suite and exit non-zero on failure.

## TLS provider

Default is **`aws_lc_rs`** (FIPS-capable). Override:
```bash
PROVIDER=ring        scripts/integration-tests.sh
PROVIDER=native-tls  scripts/integration-tests.sh
# same var works for compose:
PROVIDER=ring docker compose -f docker-compose.test.yml up --build ...
```

## Requirements
- Docker (running).
- Variant 1 also needs the Rust toolchain.
- First run pulls the MS SQL image (~1.5 GB); on Apple Silicon it runs emulated (amd64).

## Notes
- `scripts/integration-tests.sh` auto-regenerates the server cert if it has expired.
- Certs live in `docker/certs/`; regenerate manually with
  `cd docker/certs && ./generate-ca.sh && ./generate-signed-cert.sh server`.
- `TIBERIUS_TEST_CONNECTION_STRING` is set automatically; set it yourself to target
  an external server instead.
