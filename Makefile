NIX := nix develop . --command

.PHONY: build test clean lint coverage repl

build:
	$(NIX) cabal build

test:
	$(NIX) cabal test

coverage:
	$(NIX) cabal test --enable-coverage

lint:
	$(NIX) hlint src/ test/

clean:
	$(NIX) cabal clean

repl:
	$(NIX) cabal repl
