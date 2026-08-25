# haskell-deepseek-plugin-sdk

A Haskell SDK for writing DeepSeek Harness out-of-process plugins, plus the
TypeScript bridge that mounts them. A plugin written against this library speaks
the harness's JSON-RPC plugin protocol over NDJSON on stdio, contributing tools,
guards, and subagents to a running `dsh` session.

**Status.** The wire is frozen in [`PROTOCOL.md`](PROTOCOL.md) and pinned by the
byte-for-byte transcripts in [`corpus/`](corpus/). No runtime is implemented yet,
so the conformance suite is deliberately red: every unimplemented scenario is
wrapped as an expected failure, and the suite passes while they all still fail.

## Requirements

[ghcup](https://www.haskell.org/ghcup/) and [Stack](https://docs.haskellstack.org/).
Nothing else. GHC 9.10.3 comes from the `lts-24.56` snapshot, and a clean clone
lets Stack install it — the `--system-ghc --no-install-ghc` flags are passed only
by CI, never written into `stack.yaml`.

If you build with `cabal-install` instead of Stack, note that the generated
`.cabal` declares `default-language: GHC2024`, which needs **Cabal ≥ 3.12** to
parse. An older `cabal-install` fails on the field even though Stack is fine.

## Commands

```sh
stack build                 # library + dsh-plugin-echo + conformance suite
stack test                  # the conformance suite
stack test 2>&1 | tee conformance.log && scripts/check-red-visible.sh conformance.log
stack build --pedantic --test --no-run-tests   # what CI builds: -Wall -Werror
```

`stack test --test-arguments='--no-create'` does not work yet. The `--no-create`
option is contributed by the `tasty-golden` ingredient, which is registered only
once a golden test exists in the tree; the first one lands in Phase 5, and until
then tasty rejects the flag as invalid. When you do pass `--test-arguments`, put
single quotes around the whole value and none inside it — Stack forwards the
value without a shell, so an inner quote arrives at tasty as a literal character
and the option silently stops matching.

## Reading the red state

A scenario is wrapped as an expected failure if and only if
`corpus/<scenario>/EXPECTED.md` exists, and that file's first line names the
phase that must turn the scenario green. While the file is there, a failing
scenario is reported as a known gap and the suite still exits 0. When a wrapped
scenario starts passing, tasty reports `OK (unexpected: …)` and **fails the
suite** — which is what forces the implementing phase to delete the
`EXPECTED.md` in the same change that makes the scenario work.

## Repository layout

- `PROTOCOL.md` — the frozen wire: methods, directions, manifest fields, error codes.
- `corpus/` — the executable spec; both the Haskell suite and the Node bridge fixture replay these bytes.
- `src/` — the library.
- `app/echo/` — `dsh-plugin-echo`, the example binary.
- `test/` — the conformance suite.
- `docs/adr/` — architecture decision records.
- `scripts/` — repository gates.

## Formatting and linting

`fourmolu.yaml` is the unmodified `--print-defaults` output of fourmolu 0.20.1.0,
the version CI pins; regenerate it from that binary rather than editing it by
hand. `.hlint.yaml` adds nothing but `-XGHC2024`, which both tools need because
neither reads `default-language` from the `.cabal` file. Both run advisorily in
CI until Phase 7 makes them blocking.
