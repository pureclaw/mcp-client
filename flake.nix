{
  description = "MCP Client — Haskell client library for the Model Context Protocol";
  # Pin to the same haskell.nix rev as pureclaw so we reuse its cached GHC
  inputs.haskellNix.url = "github:input-output-hk/haskell.nix/78278f5063d26702b62e46ebaede1a2fbf5f72c7";
  inputs.nixpkgs.follows = "haskellNix/nixpkgs-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  outputs = { self, nixpkgs, flake-utils, haskellNix }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-darwin" ] (system:
    let
      overlays = [ haskellNix.overlay
        (final: prev: {
          mcp-client-project =
            final.haskell-nix.cabalProject' {
              src = ./.;
              compiler-nix-name = "ghc9123";
              shell.withHoogle = false;
              shell.exactDeps = true;
              shell.tools = {
                cabal = {};
                hlint = {};
              };
            };
        })
      ];
      pkgs = import nixpkgs { inherit system overlays; inherit (haskellNix) config; };
      flake = pkgs.mcp-client-project.flake {};
    in flake // {
      packages.default = flake.packages."mcp-client:lib:mcp-client";
      inherit pkgs;
    });
  nixConfig = {
    extra-substituters = [
      "https://cache.iog.io"
    ];
    extra-trusted-public-keys = [
      "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
    ];
  };
}
