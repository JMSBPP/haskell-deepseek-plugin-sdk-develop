---
phase: 01-protocol-freeze-and-toolchain-foundation
plan: 01
subsystem: infra
tags: [haskell, stack, hpack, cabal, ghc-9.10.3, lts-24.56, tasty, GHC2024]

# Dependency graph
requires: []
provides:
  - "lts-24.56 (GHC 9.10.3) snapshot pin with a committed stack.yaml.lock"
  - "package.yaml as the hpack source of truth for library + dsh-plugin-echo executable + conformance test-suite"
  - "committed, drift-free haskell-deepseek-plugin-sdk.cabal for cabal-only consumers"
  - "seven Haddock-only library module stubs under src/DeepSeek/Plugin/ that Phases 2-6 fill in"
  - "a linking conformance test-suite stanza with the full tasty + hedgehog dependency set declared"
affects: [02-wire-transport, 03-bidirectional-peer, 04-schema, 05-plugin-api, 06-guards-sections-subagents, 07-echo-plugin-and-ci]

# Tech tracking
tech-stack:
  added: [stack 3.11.1, hpack 0.39.6, GHC 9.10.3, aeson 2.2, async, safe-exceptions, stm, tasty, tasty-hunit, tasty-golden, tasty-hedgehog, tasty-expected-failure, hedgehog, typed-process, temporary, optparse-applicative]
  patterns:
    - "hpack is the single source of truth; the .cabal is generated and never hand-edited"
    - "warning policy lives in CI (stack build --pedantic), never as -Werror in package.yaml"
    - "stub modules with Haddock, never stub types"

key-files:
  created:
    - package.yaml
    - stack.yaml.lock
    - haskell-deepseek-plugin-sdk.cabal
    - src/DeepSeek/Plugin.hs
    - src/DeepSeek/Plugin/Wire.hs
    - src/DeepSeek/Plugin/Peer.hs
    - src/DeepSeek/Plugin/Schema.hs
    - src/DeepSeek/Plugin/Manifest.hs
    - src/DeepSeek/Plugin/Types.hs
    - src/DeepSeek/Plugin/Content.hs
    - app/echo/Main.hs
    - test/Main.hs
  modified:
    - stack.yaml
    - .gitignore

key-decisions:
  - "Snapshot repinned lts-22.43 -> lts-24.56 (GHC 9.10.3); no extra-deps are needed, the whole tasty + hedgehog set resolves inside the snapshot"
  - "-Werror is not in package.yaml; CI passes stack build --pedantic so a new GHC minor cannot make a clean clone unbuildable for contributors"
  - "base >= 4.18 && < 4.22 is deliberately wider than the pin (GHC 9.6-9.12) so a cabal-only user is not locked to 9.10.3"
  - "stack.yaml carries no system-ghc/install-ghc keys; CI supplies --system-ghc --no-install-ghc so a clean local clone still works with zero setup"
  - "Module stubs carry Haddock and an empty export list only; no stub types, which would create a false compile-time contract for Phase 2 to redesign"
  - "text is declared in the test stanza as well as the library, for plan 04's manifest meta-test that reads aeson String payloads"

patterns-established:
  - "Generated-artifact commitment: .cabal and stack.yaml.lock are committed and verified drift-free with git diff --exit-code -- '*.cabal' after a build"
  - "Anchored grep guard: grep -rqE '^(data|newtype|type) ' src/ must exit 1, so no stub type can slip in unnoticed"
  - "Placeholder binaries fail loud: dsh-plugin-echo exits non-zero until Phase 7 so no caller mistakes it for a working peer"

requirements-completed: [TOOL-01]

# Metrics
duration: 3min
completed: 2026-08-25
---

# Phase 1 Plan 01: Toolchain Foundation Summary

**lts-24.56/GHC 9.10.3 pinned with hpack as the source of truth: library + `dsh-plugin-echo` executable + `conformance` test-suite all compile warning-free under `GHC2024` with `--pedantic`.**

## Performance

- **Duration:** 3 min
- **Started:** 2026-08-25T20:37:58Z
- **Completed:** 2026-08-25T20:40:47Z
- **Tasks:** 2
- **Files modified:** 15 (13 created, 2 modified, 2 deleted)

## Accomplishments

- Repinned the snapshot from the `stack new simple` scaffold's `lts-22.43` to `lts-24.56` (GHC 9.10.3), the version that emits `integer` tool args as `integer` rather than `number`; `stack.yaml` is three lines with no `extra-deps`.
- Replaced the hand-written `.cabal` and the hello-world `src/Main.hs` with `package.yaml` declaring all three stanzas, and committed the hpack-generated `.cabal` plus `stack.yaml.lock` (snapshot sha256 `121a2b65…f277b`, matching the plan's verified value).
- Created seven Haddock-documented, declaration-free library module stubs plus an executable placeholder and a tasty placeholder, so the `-Wall -Wmissing-export-lists` regime is a Phase 1 fact rather than a Phase 2 surprise.
- `stack build --pedantic --test --no-run-tests` exits 0 with zero GHC warning lines on GHC 9.10.3.

## Task Commits

Each task was committed atomically:

1. **Task 1: Repin the snapshot and replace the scaffold with an hpack package** — `2955aa8` (chore)
2. **Task 2: Add the module stubs and regenerate the committed .cabal** — `7df7688` (feat)

## Files Created/Modified

- `stack.yaml` — three lines pinning `lts-24.56`; every `stack init` comment dropped
- `stack.yaml.lock` — committed snapshot sha256 for reproducibility
- `package.yaml` — hpack source of truth: top-level `language: GHC2024` and the nine-warning `ghc-options` set, library + `dsh-plugin-echo` + `conformance`
- `haskell-deepseek-plugin-sdk.cabal` — generated by hpack, committed for cabal-only consumers; `default-language: GHC2024` in all three stanzas, `-threaded -rtsopts -with-rtsopts=-N` on the executable and test-suite
- `src/DeepSeek/Plugin.hs` — public entry point; Phase 5 fills in `runPlugin`
- `src/DeepSeek/Plugin/Wire.hs` — JSON-RPC envelopes and NDJSON stdio transport; Phase 2
- `src/DeepSeek/Plugin/Peer.hs` — bidirectional peer, STM correlation map, `$/cancel` registry; Phase 3
- `src/DeepSeek/Plugin/Schema.hs` — `DshSchema` subset and argument validator; Phase 4
- `src/DeepSeek/Plugin/Manifest.hs` — handshake manifest projection; Phase 5
- `src/DeepSeek/Plugin/Types.hs` — author-facing records; Phases 5 and 6
- `src/DeepSeek/Plugin/Content.hs` — `ContentBlock` union with `Unknown Value` fall-through; Phase 5
- `app/echo/Main.hs` — placeholder that exits non-zero until Phase 7 (API-10)
- `test/Main.hs` — placeholder tasty entry point; plan 04 replaces it entirely
- `.gitignore` — added `conformance.log`
- Deleted: `src/Main.hs`, the hand-written `haskell-deepseek-plugin-sdk.cabal`

## Decisions Made

None beyond the plan — every decision above was specified and pre-verified in the plan's `<verified_facts>` block, and each verified value reproduced exactly on this machine (snapshot sha256, three `default-language: GHC2024` lines, two `-threaded -rtsopts -with-rtsopts=-N` lines).

## Deviations from Plan

None — plan executed exactly as written.

The single expected warning appeared and was correctly ignored: `Specified file "PROTOCOL.md" for extra-source-files does not exist`. Plan 01-02 creates `PROTOCOL.md` in the same wave; the build still exits 0 and the `.cabal` still lists the file.

## Issues Encountered

None.

## User Setup Required

None — no external service configuration required. A clean clone needs only ghcup and stack.

## Next Phase Readiness

- Plans 01-02 through 01-05 can proceed: the library stanza compiles, so any module they add to `src/` is picked up by `source-dirs`, and the `conformance` test-suite already declares the full tasty + hedgehog + `typed-process` + `temporary` set plan 04 needs.
- `PROTOCOL.md` is referenced by `extra-source-files` and by `src/DeepSeek/Plugin/Wire.hs` and `Manifest.hs` Haddock but does not exist yet; plan 01-02 clears the residual cabal warning.
- Phase 2 inherits a warning-free baseline: any new warning it introduces fails `--pedantic` immediately rather than accumulating.
- Note for Phase 7 packaging: hpack writes `cabal-version: 2.2`, but `default-language: GHC2024` requires Cabal >= 3.12 to parse; the minimum `cabal-install` needs documenting or the declared `cabal-version` raising before an sdist ships.

---
*Phase: 01-protocol-freeze-and-toolchain-foundation*
*Completed: 2026-08-25*

## Self-Check: PASSED

All 14 claimed files exist on disk, both task commits (`2955aa8`, `7df7688`) are present in history, and the deleted `src/Main.hs` is gone.
