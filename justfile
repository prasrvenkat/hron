version := `cat VERSION`

# Run all tests across all languages
test-all: test-rust

# Rust
test-rust:
    cd rust && cargo test --workspace --all-features

build-rust:
    cd rust && cargo build --workspace --all-features

build-wasm:
    cd rust/wasm && cargo build --target wasm32-unknown-unknown

# Stamp VERSION into all language package manifests
stamp-versions:
    sed -i '0,/^version = .*/s//version = "{{version}}"/' rust/hron/Cargo.toml
    sed -i '0,/^version = .*/s//version = "{{version}}"/' rust/hron-cli/Cargo.toml
    sed -i '0,/^version = .*/s//version = "{{version}}"/' rust/wasm/Cargo.toml
    # Future: python/pyproject.toml, etc.

# Tag and push a release (CI takes over from here)
release: test-all stamp-versions
    git add -A
    git commit -m "release v{{version}}" || true
    git tag "v{{version}}"
    @echo "Tagged v{{version}}. Push with: git push && git push --tags"
