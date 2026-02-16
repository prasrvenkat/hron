version := `cat VERSION`

# Run all tests
test-all: test-rust test-ts test-dart test-python test-wasm test-go test-java test-csharp test-ruby

# Rust tests
test-rust:
    cd rust && cargo test --workspace --all-features

# TypeScript tests
test-ts:
    cd ts && pnpm install --frozen-lockfile && pnpm test

# Dart tests
test-dart:
    cd dart && dart pub get && dart test

# Python tests
test-python:
    cd python && uv run pytest -v

# Go tests
test-go:
    cd go && go test -v ./...

# Java tests
test-java:
    cd java && mvn test

# C# tests
test-csharp:
    dotnet test csharp/Hron.sln

# Ruby tests
test-ruby:
    cd ruby && bundle install && bundle exec rake test

# Install dependencies for all languages
setup: setup-rust setup-ts setup-python setup-go setup-ruby setup-dart setup-csharp setup-java

setup-rust:
    rustup component add rustfmt clippy

setup-ts:
    cd ts && pnpm install --frozen-lockfile

setup-python:
    cd python && uv sync --locked

setup-go:
    cd go && go mod download

setup-ruby:
    cd ruby && bundle install

setup-dart:
    cd dart && dart pub get

setup-csharp:
    dotnet restore csharp/Hron.sln

setup-java:
    cd java && mvn dependency:resolve -q

# Format all
fmt: fmt-rust fmt-ts fmt-python fmt-go fmt-ruby fmt-dart fmt-csharp fmt-java

# Lint/check all (CI-safe, no auto-fix)
lint: lint-rust lint-ts lint-python lint-go lint-ruby lint-dart lint-csharp lint-java

fmt-rust:
    cd rust && cargo fmt --all

fmt-ts:
    cd ts && pnpm lint --fix

fmt-python:
    cd python && uv run ruff format src/ tests/ && uv run ruff check --fix src/ tests/

fmt-go:
    cd go && gofmt -w .

fmt-ruby:
    cd ruby && bundle exec standardrb --fix

fmt-dart:
    cd dart && dart format .

fmt-csharp:
    dotnet format csharp/Hron.sln

fmt-java:
    cd java && mvn fmt:format

lint-rust:
    cd rust && cargo fmt --all --check
    cd rust && cargo clippy --workspace --all-features -- -D warnings

lint-ts:
    cd ts && pnpm lint

lint-python:
    cd python && uv run ruff check src/ tests/
    cd python && uv run ruff format --check src/ tests/

lint-go:
    #!/usr/bin/env bash
    set -euo pipefail
    cd go
    if [ -n "$(gofmt -l .)" ]; then
      echo "Code is not formatted. Run 'just fmt-go' to fix."
      gofmt -d .
      exit 1
    fi
    go vet ./...

lint-ruby:
    cd ruby && bundle exec standardrb

lint-dart:
    cd dart && dart format --output=none --set-exit-if-changed .
    cd dart && dart analyze

lint-csharp:
    dotnet format csharp/Hron.sln --verify-no-changes

lint-java:
    cd java && mvn fmt:check
    cd java && mvn javadoc:jar -q

# Rust build
build-rust:
    cd rust && cargo build --workspace --all-features

# Go build
build-go:
    cd go && go build ./...

# Java build
build-java:
    cd java && mvn compile -q

# C# build
build-csharp:
    dotnet build csharp/Hron.sln

# WASM build
build-wasm:
    cd rust/wasm && cargo build --target wasm32-unknown-unknown

# WASM tests (build + run JS tests)
test-wasm:
    cd rust/wasm && wasm-pack build --release
    cp rust/wasm/hron_wasm_entry.js rust/wasm/pkg/hron_wasm.js
    cd rust/wasm/test && pnpm install --frozen-lockfile && pnpm test

# Print all component versions (for CI validation and local checks)
versions:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "hron=$(cargo metadata --no-deps --format-version 1 --manifest-path rust/Cargo.toml | jq -r '.packages[] | select(.name == "hron") | .version')"
    echo "hron-cli=$(cargo metadata --no-deps --format-version 1 --manifest-path rust/Cargo.toml | jq -r '.packages[] | select(.name == "hron-cli") | .version')"
    echo "hron-wasm=$(cargo metadata --no-deps --format-version 1 --manifest-path rust/Cargo.toml | jq -r '.packages[] | select(.name == "hron-wasm") | .version')"
    echo "hron-ts=$(node -p "require('./ts/package.json').version")"
    echo "dart=$(grep '^version:' dart/pubspec.yaml | awk '{print $2}')"
    echo "python=$(python3 -c "import tomllib; print(tomllib.load(open('python/pyproject.toml','rb'))['project']['version'])")"
    echo "go=$(grep 'const Version' go/version.go | cut -d'"' -f2)"
    echo "java=$(mvn -f java/pom.xml help:evaluate -Dexpression=project.version -q -DforceStdout)"
    echo "csharp=$(grep '<Version>' csharp/Hron/Hron.csproj | sed 's/.*<Version>\(.*\)<\/Version>.*/\1/')"
    echo "ruby=$(ruby -r ./ruby/lib/hron/version.rb -e 'puts Hron::VERSION')"

# Stamp VERSION into all package manifests and regenerate lockfiles
stamp-versions:
    # Rust: hron, hron-cli, hron-wasm + internal deps
    sed -i '0,/^version = .*/s//version = "{{version}}"/' rust/hron/Cargo.toml
    sed -i '0,/^version = .*/s//version = "{{version}}"/' rust/hron-cli/Cargo.toml
    sed -i '0,/^version = .*/s//version = "{{version}}"/' rust/wasm/Cargo.toml
    sed -i 's/hron = { path = "..\/hron", version = "[^"]*"/hron = { path = "..\/hron", version = "{{version}}"/' rust/hron-cli/Cargo.toml
    sed -i 's/hron = { path = "..\/hron", version = "[^"]*"/hron = { path = "..\/hron", version = "{{version}}"/' rust/wasm/Cargo.toml
    cd rust && cargo generate-lockfile
    # TypeScript
    cd ts && sed -i 's/"version": "[^"]*"/"version": "{{version}}"/' package.json && pnpm install --no-frozen-lockfile
    # Dart
    sed -i 's/^version: .*/version: {{version}}/' dart/pubspec.yaml
    sed -i 's/^Current version: .*/Current version: {{version}}/' dart/CHANGELOG.md
    # Python
    sed -i '0,/^version = .*/s//version = "{{version}}"/' python/pyproject.toml
    cd python && uv lock
    # Go
    sed -i 's/const Version = "[^"]*"/const Version = "{{version}}"/' go/version.go
    # Java
    mvn -f java/pom.xml versions:set -DnewVersion={{version}} -DgenerateBackupPoms=false
    # C#
    sed -i 's/<Version>[^<]*<\/Version>/<Version>{{version}}<\/Version>/' csharp/Hron/Hron.csproj
    # Ruby
    sed -i 's/VERSION = "[^"]*"/VERSION = "{{version}}"/' ruby/lib/hron/version.rb

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
    git add .
    git commit -m "release: v{{new_version}}"
    git push -u origin "release/v{{new_version}}"
    gh pr create --title "release: v{{new_version}}" --body "Bump version to {{new_version}} and publish."
    echo "Release PR created for v{{new_version}}"

# Run Criterion benchmarks (Rust)
bench:
    cd rust && cargo bench -p hron

# Run fuzz targets (requires nightly). Default 3 minutes per target.
fuzz target="fuzz_parse" duration="180":
    cd rust/hron && cargo +nightly fuzz run {{target}} -- -max_total_time={{duration}}

# Playground dev server
dev-playground:
    cd playground && pnpm install && pnpm dev

# Build playground
build-playground:
    cd playground && pnpm install && pnpm build

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

# Build and publish Python package to PyPI
publish-python:
    cd python && uv build && uv publish

# Build and publish native TS package to npm
publish-ts:
    cd ts && pnpm install --frozen-lockfile && pnpm build && pnpm publish --access public --no-git-checks

# Build and publish WASM package to npm
publish-wasm:
    cd rust/wasm && wasm-pack build --release
    cp rust/wasm/hron_wasm_entry.js rust/wasm/pkg/hron_wasm.js
    cd rust/wasm/pkg && npm publish --access public

# Publish Java package to Maven Central
publish-java:
    cd java && mvn deploy -P release

# Publish C# package to NuGet
publish-csharp:
    cd csharp/Hron && dotnet pack -c Release
    cd csharp/Hron && dotnet nuget push bin/Release/*.nupkg --source nuget.org --api-key $NUGET_API_KEY

# Build and publish Ruby gem to RubyGems
publish-ruby:
    cd ruby && gem build hron.gemspec && gem push hron-$(cat ../VERSION).gem

# Trigger Go module indexing on pkg.go.dev
publish-go:
    #!/usr/bin/env bash
    set -euo pipefail
    version=$(cat VERSION)
    echo "Triggering pkg.go.dev indexing for go/v${version}..."
    curl -sfL "https://proxy.golang.org/github.com/prasrvenkat/hron/go/@v/v${version}.info" || {
        echo "Warning: proxy.golang.org returned an error (may need a few minutes to propagate)"
        exit 0
    }
    echo "Go module indexed successfully"

# Create git tags via GitHub API (verified)
create-tag:
    #!/usr/bin/env bash
    set -euo pipefail
    version=$(cat VERSION)
    sha=$(git rev-parse HEAD)
    # Main version tag
    gh api repos/{owner}/{repo}/git/refs \
        -f "ref=refs/tags/v${version}" \
        -f "sha=${sha}"
    echo "Created tag v${version}"
    # Go subdirectory module tag (required for pkg.go.dev)
    gh api repos/{owner}/{repo}/git/refs \
        -f "ref=refs/tags/go/v${version}" \
        -f "sha=${sha}"
    echo "Created tag go/v${version}"

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
