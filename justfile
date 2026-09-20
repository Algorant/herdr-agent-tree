# Run the complete local gate, including the noninteractive isolated Herdr E2E test.
test:
    ./scripts/check.sh

# Build the optimized current-checkout agent-tree binary.
build:
    cargo build --locked --release --manifest-path Cargo.toml

# Rebuild, stage, register and reload this checkout against the live Herdr server.
deploy:
    ./scripts/deploy.sh

# Deploy the current checkout to an explicitly named Herdr endpoint (local or saved machine).
deploy-endpoint endpoint:
    ./scripts/deploy-endpoint.sh --endpoint {{endpoint}}

# Read-only Agent Tree readiness report for one explicit endpoint.
doctor endpoint:
    ./scripts/doctor.sh --endpoint {{endpoint}}
