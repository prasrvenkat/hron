version := `cat VERSION`

# Run all tests
test-all: test-rust test-ts test-dart test-wasm

# Rust tests
test-rust:
    cd rust && cargo test --workspace --all-features

# TypeScript tests
test-ts:
    cd ts && pnpm install --frozen-lockfile && pnpm test

# Dart tests
test-dart:
    cd dart && dart pub get && dart test

# Rust build
build-rust:
    cd rust && cargo build --workspace --all-features

# WASM build
build-wasm:
    cd rust/wasm && cargo build --target wasm32-unknown-unknown

# WASM tests (build + run JS tests)
test-wasm:
    cd rust/wasm && wasm-pack build --release
    cd rust/wasm/test && pnpm install --frozen-lockfile && pnpm test

# Stamp VERSION into all package manifests and regenerate lockfiles
stamp-versions:
    sed -i '0,/^version = .*/s//version = "{{version}}"/' rust/hron/Cargo.toml
    sed -i '0,/^version = .*/s//version = "{{version}}"/' rust/hron-cli/Cargo.toml
    sed -i '0,/^version = .*/s//version = "{{version}}"/' rust/wasm/Cargo.toml
    sed -i 's/hron = { path = "..\/hron", version = "[^"]*"/hron = { path = "..\/hron", version = "{{version}}"/' rust/hron-cli/Cargo.toml
    sed -i 's/hron = { path = "..\/hron", version = "[^"]*"/hron = { path = "..\/hron", version = "{{version}}"/' rust/wasm/Cargo.toml
    cd rust && cargo generate-lockfile
    cd ts && sed -i 's/"version": "[^"]*"/"version": "{{version}}"/' package.json && pnpm install --no-frozen-lockfile
    cd dart && sed -i 's/^version: .*/version: {{version}}/' pubspec.yaml

# Create a release PR: just release 1.2.3
release new_version:
    #!/usr/bin/env bash
    set -euo pipefail

    # Validate semver
    if ! echo "{{new_version}}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        echo "Error: '{{new_version}}' is not valid semver (expected X.Y.Z)"
        exit 1
    fi

    # Ensure clean working tree
    if [ -n "$(git status --porcelain)" ]; then
        echo "Error: working tree is not clean"
        exit 1
    fi

    # Ensure on main
    branch=$(git branch --show-current)
    if [ "$branch" != "main" ]; then
        echo "Error: must be on main (currently on '$branch')"
        exit 1
    fi

    # Pull latest
    git pull --ff-only

    # Write version
    echo "{{new_version}}" > VERSION

    # Stamp versions into Cargo.tomls
    just version="{{new_version}}" stamp-versions

    # Create release branch, commit, push, open PR
    git checkout -b "release/v{{new_version}}"
    git add VERSION rust/hron/Cargo.toml rust/hron-cli/Cargo.toml rust/wasm/Cargo.toml rust/Cargo.lock ts/package.json ts/pnpm-lock.yaml dart/pubspec.yaml
    git commit -m "release: v{{new_version}}"
    git push -u origin "release/v{{new_version}}"
    gh pr create --title "release: v{{new_version}}" --body "Bump version to {{new_version}} and publish."
    echo "Release PR created for v{{new_version}}"

# --- Local fallback targets (mirror CI jobs) ---

# Publish hron library crate
publish-hron:
    cd rust/hron && cargo publish

# Publish hron-cli crate (run after hron is indexed)
publish-cli:
    cd rust/hron-cli && cargo publish

# Publish both crates in sequence
publish-crates: publish-hron
    @echo "Waiting 30s for crates.io index..."
    sleep 30
    just publish-cli

# Publish Dart package to pub.dev
publish-dart:
    cd dart && dart pub publish --force

# Build and publish native TS package to npm
publish-ts:
    cd ts && pnpm install --frozen-lockfile && pnpm build && pnpm publish --access public --no-git-checks

# Build and publish WASM package to npm
publish-wasm:
    cd rust/wasm && wasm-pack build --release
    cd rust/wasm/pkg && npm publish --access public

# Create a git tag via GitHub API (verified)
create-tag:
    #!/usr/bin/env bash
    set -euo pipefail
    version=$(cat VERSION)
    sha=$(git rev-parse HEAD)
    gh api repos/{owner}/{repo}/git/refs \
        -f "ref=refs/tags/v${version}" \
        -f "sha=${sha}"
    echo "Created tag v${version}"

# Create a draft GitHub release
create-release:
    #!/usr/bin/env bash
    set -euo pipefail
    version=$(cat VERSION)
    gh release create "v${version}" --draft --generate-notes --title "v${version}" dist/*

# Un-draft the GitHub release
publish-release:
    #!/usr/bin/env bash
    set -euo pipefail
    version=$(cat VERSION)
    gh release edit "v${version}" --draft=false
