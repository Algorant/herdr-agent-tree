# Run the complete local gate, including the noninteractive isolated Herdr E2E test.
test:
    ./scripts/check.sh

# Build the optimized current-checkout agent-tree binary.
build:
    cargo build --locked --release --manifest-path Cargo.toml

# Rebuild, stage, register and reload this checkout against the live Herdr server.
deploy:
    ./scripts/deploy.sh
