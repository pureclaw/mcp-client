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

# Run tests with coverage (uncomment -fhpc flag in baldr.cabal first)
cabal test --enable-coverage

# Run specific test module (tests are in test/ directory)
cabal test --test-options="--match FooSpec"
```
