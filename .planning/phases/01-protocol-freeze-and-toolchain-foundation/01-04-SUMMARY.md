---
phase: 01-protocol-freeze-and-toolchain-foundation
plan: 04
subsystem: testing
tags: [tasty, tasty-expected-failure, tasty-hedgehog, hedgehog, barbies, aeson, haskell, conformance]

# Dependency graph
requires:
  - phase: 01-01
    provides: the `conformance` test-suite stanza, its dependency set, and the warning flags the modules compile under
  - phase: 01-02
    provides: the 17 corpus scenario directories, their `host.jsonl`/`plugin.jsonl` frames, and the `EXPECTED.md` manifests
  - phase: 01-03
    provides: fourmolu.yaml, .hlint.yaml, and the CI workflow steps this gate feeds
provides:
  - a tasty suite that discovers one test per `corpus/<scenario>` directory at runtime, with no parallel list of names
  - `expectFailBecause` wrapping driven solely by `EXPECTED.md` presence, so a scenario cannot flip green while its manifest survives
  - five meta-tests keeping the corpus honest: required directories present, one JSON value per line, every `EXPECTED.md` naming an owning phase, and the handshake manifest declaring all four contribution kinds with frozen-character-set tool names
  - the four property-family signatures (codec round-trip, hostile-frame totality, schema subset closure, cancellation ordering), all visibly failing
  - `scripts/check-red-visible.sh`, the phase acceptance gate over a captured tasty log
affects: [02-transport-and-replay, 03-cancellation, 04-schema, 05-plugin-api-and-manifest, 07-linters-blocking]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Scenario tree built in IO before defaultMain (not withResource, which cannot change tree shape)"
    - "Filesystem-as-manifest: readExpected is the single decision point for expect-fail"
    - "Hedgehog 1.5 state machine over barbies FunctorB/TraversableB, not the deprecated HTraversable"
    - "Corpus is never a tasty-golden golden; --accept would rewrite the hand-authored spec"

key-files:
  created:
    - test/Conformance/Corpus.hs
    - test/Conformance/Properties.hs
    - scripts/check-red-visible.sh
  modified:
    - test/Main.hs
    - haskell-deepseek-plugin-sdk.cabal

key-decisions:
  - "The known-red manifest is the filesystem: EXPECTED.md presence alone decides expectFailBecause, so the meta-test can be semantic (does the headline name a phase?) rather than bookkeeping"
  - "manifestToolNamesAreWellFormed is the only executed check of PROTOCOL.md section 4's /^[A-Za-z0-9_-]{1,64}$/ rule, written as a Data.Char predicate because the test stanza declares no regex library"
  - "check-red-visible.sh parses a captured log rather than running stack test, so CI builds and runs the suite once and set -euo pipefail cannot swallow the suite's exit code"
  - "Conformance.Properties keeps the Haddock mention of the deprecated HTraversable as a migration warning for Phase 3; only the deriving clause matters, and it names FunctorB/TraversableB"

patterns-established:
  - "Red is an asset: every stub body must genuinely fail, because a pass under expectFailBecause is reported as OK (unexpected: …) and fails the suite"
  - "Every expect-fail wrapper names the phase that owns deleting it"
  - "Test-suite module additions regenerate the committed .cabal other-modules list via hpack in the same commit"

requirements-completed: [PROTO-02, PROTO-04, TOOL-01]

# Metrics
duration: 4min
completed: 2026-08-25
---

# Phase 1 Plan 04: Conformance Suite as Executable Specification Summary

**A tasty suite that discovers one test per corpus directory and reports `All 26 tests passed` while 21 of them are visibly, deliberately failing — 17 corpus scenarios and 4 property families, each naming the phase that owns turning it green.**

## Performance

- **Duration:** 4 min
- **Started:** 2026-08-25T20:47:53Z
- **Completed:** 2026-08-25T20:51:09Z
- **Tasks:** 3
- **Files modified:** 5 (3 created, 2 modified)

## Accomplishments

- `Conformance.Corpus` enumerates `corpus/` at runtime and wraps exactly the scenarios carrying `EXPECTED.md` in `expectFailBecause`. There is no parallel list, so the wrapper set cannot drift from the corpus.
- Five meta-tests pass and keep the corpus honest: all 17 required directories exist, every non-exempt `host.jsonl`/`plugin.jsonl` line decodes as one JSON value, every `EXPECTED.md` headline names an owning phase 2–7, the handshake manifest frame declares `tools`/`guards`/`sections`/`subagents`, and every manifest tool name matches the character set PROTOCOL.md section 4 freezes.
- `Conformance.Properties` carries the four property families as compiling, failing signatures; the cancellation state machine is written against hedgehog 1.5's barbies-based `Command`, so Phase 3 replaces the model rather than the plumbing.
- `scripts/check-red-visible.sh` turns the phase's acceptance from a manual read of test output into an executed gate: it fails when no `FAIL (expected:` line exists and when any `OK (unexpected:` line does.
- Both advisory linters are already clean against the real binaries: `hlint 3.10` reports `No hints` over `src app test`, and `fourmolu 0.20.1.0 --mode check --ghc-opt -XGHC2024` exits 0, so Phase 7's flip-to-blocking is a one-line CI change rather than a tree-wide reformat.

## Task Commits

Each task was committed atomically:

1. **Task 1: Corpus enumeration module and the real tasty entry point** - `18020fd` (test)
2. **Task 2: The four property-family signatures including the Hedgehog state machine** - `f42bedf` (test)
3. **Task 3: The red-visible acceptance script and the full phase gate** - `cecdcc1` (ci)

## Files Created/Modified

- `test/Conformance/Corpus.hs` (created, 210 lines) - `Scenario`, `corpusRoot`, `requiredScenarios`, `listScenarios`, `tests`; the expect-fail decision and the five meta-tests
- `test/Conformance/Properties.hs` (created, 91 lines) - the four property families, all `expectFailBecause`, plus the placeholder `ModelState`/`Issue`/`issueCommand` state machine
- `scripts/check-red-visible.sh` (created, executable) - the phase acceptance gate over a captured tasty log
- `test/Main.hs` (modified) - the placeholder replaced with the real entry point; the scenario tree is built in `IO` before `defaultMain`
- `haskell-deepseek-plugin-sdk.cabal` (modified) - hpack-regenerated `other-modules` for the two new test modules

## Verification Evidence

| Check | Result |
| --- | --- |
| `stack build --pedantic --test --no-run-tests` | exit 0, no warnings |
| `stack test` (end of task 1) | `All 22 tests passed`, 17 `FAIL (expected:`, 0 `OK (unexpected:` |
| `stack test --test-arguments='-p /meta/'` | `All 5 tests passed`, five `OK` lines |
| `stack test --test-arguments='-p /properties/'` | `All 4 tests passed`, four `(expected failure)` |
| `stack test` (end of task 2) | `All 26 tests passed`, 21 `FAIL (expected:`, 0 `OK (unexpected:` |
| `scripts/check-red-visible.sh conformance.log` | exit 0, `red state visible (21 expected failures)` |
| `check-red-visible.sh` on an unexpected-pass log | exit 1 |
| `check-red-visible.sh` on a no-red log | exit 1 |
| `git diff --exit-code -- '*.cabal'` after build | exit 0 |
| `git status --porcelain conformance.log` | empty (gitignored, uncommitted) |
| `hlint 3.10 src app test` | `No hints` |
| `fourmolu 0.20.1.0 --mode check --ghc-opt -XGHC2024` | exit 0 |

## Decisions Made

- Kept the plan's sources verbatim, including the four bodies that cannot hold (`n === n + 1`, `assert (length line < 0)`, `assert False`, `assert (n < 0)`) and `replayScenario`'s trailing `assertFailure`. Each is load-bearing: a stub that passes under `expectFailBecause` fails the suite, which is the forcing function that makes later phases delete both the stub and the `EXPECTED.md`.
- Committed the hpack-regenerated `.cabal` inside each task commit rather than as a separate cleanup, because the repo treats it as a committed generated artifact verified drift-free after every build.

## Deviations from Plan

### Documentation-only mismatch (no code change)

**1. [Plan inconsistency] Acceptance criterion `grep -q 'HTraversable' test/Conformance/Properties.hs` exits 1 is unsatisfiable against the plan's own verbatim source**
- **Found during:** Task 2 (property-family signatures)
- **Issue:** The plan requires the module be written verbatim, and its Haddock for `Issue` says "the @HTraversable@ class every older tutorial uses is deprecated and does not satisfy 'Command'". That sentence makes the acceptance grep match, so the criterion and the source it checks cannot both hold.
- **Resolution:** Kept the source verbatim — the Haddock mention is a useful migration warning for Phase 3 — and verified the criterion's substantive intent instead: `grep -n 'deriving' test/Conformance/Properties.hs` shows only `deriving (Eq, Show, Generic)` and `deriving anyclass (FunctorB, TraversableB)`, and the single `HTraversable` occurrence is on comment line 77. The deprecated class is named, never used.
- **Files modified:** none
- **Impact:** none on behavior; the grep line in a future plan should read `grep -q 'deriving.*HTraversable'`.

---

**Total deviations:** 0 code deviations; 1 documented plan/criterion inconsistency resolved in favor of the verified-compiling source.
**Impact on plan:** None. All three tasks executed as written; every other acceptance criterion passed as stated.

## Issues Encountered

None. The `<verified_facts>` figures reproduced exactly on this machine: 22 tests / 17 expected failures at the end of task 1, and 26 tests / 21 expected failures at the end of task 2, with zero unexpected passes at both points. Both linter downloads succeeded, so no signal had to be deferred to plan 05's CI run.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Plan 01-05 can wire `stack test 2>&1 | tee conformance.log` plus `scripts/check-red-visible.sh conformance.log` into the CI workflow as the phase's executed acceptance step.
- Phase 2 inherits the exact seam it needs: replace `replayScenario`'s `assertFailure` with a real replay through the in-memory transport pair, then delete each `EXPECTED.md` it turns green — the suite fails loudly if it forgets the second step.
- Phase 3 inherits a compiling hedgehog 1.5 state machine and replaces `ModelState`/`Issue`/`issueCommand`, not the plumbing.
- No blockers. The corpus is deliberately not wired as a `tasty-golden` golden; goldens start with Phase 5's `--dump-manifest` output.

---
*Phase: 01-protocol-freeze-and-toolchain-foundation*
*Completed: 2026-08-25*

## Self-Check: PASSED

All six claimed files exist on disk and all three task commits (`18020fd`, `f42bedf`, `cecdcc1`) are present in the repository history.
