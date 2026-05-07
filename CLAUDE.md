# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build and Development Commands

### Building
```bash
# Incremental build (standard approach)
nix develop --command cabal build

# Full Nix flake build
nix build

# Enter development shell with tools (cabal, ghcid, hlint)
nix develop
```

### Running Tests
```bash
# Run all tests
nix develop --command cabal test

# Run tests with coverage
nix develop --command cabal test --enable-coverage

# Run specific test module (tests are in test/ directory)
cabal test --test-options="--match FooSpec"
```

### Code Coverage

100% test coverage is required. Coverage thresholds are defined in `.coverage-thresholds.json` — this is the single source of truth.

- **Enforcement:** Coverage gates block PR creation and task completion
- **Command:** `nix develop --command cabal test --enable-coverage` (or `make coverage`)
- **CI:** Coverage reports are generated and deployed to GitHub Pages on every push/PR
- If a GitHub Issue specifies different thresholds, update `.coverage-thresholds.json` first
