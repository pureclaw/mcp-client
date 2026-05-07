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
              # Filter the source to exclude cabal.project and
              # cabal.project.freeze — they pull in the server packages
              # (and thus jose 0.11 which doesn't compile here).
              # We provide our own cabalProject string below.
              src = builtins.path {
                path = ./..;
                name = "mcp-src";
                filter = path: type:
                  let base = builtins.baseNameOf path; in
                  base != "cabal.project" &&
                  base != "cabal.project.freeze" &&
                  base != "cabal.project.local" &&
                  base != ".git";
              };
              # Match pureclaw's GHC to reuse the already-built compiler
              compiler-nix-name = "ghc9123";
              # Only build mcp-types + mcp-client (not mcp-server).
              # mcp-server depends on jose 0.11 via servant-auth-server,
              # and jose 0.11 doesn't compile in this haskell.nix snapshot.
              # Tests disabled since test suite depends on the server.
              cabalProject = builtins.readFile (./.. + "/cabal-nix.project");
              cabalProjectLocal = "";
              cabalProjectFreeze = "";
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
