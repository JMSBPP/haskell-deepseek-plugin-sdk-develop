---
phase: 01-protocol-freeze-and-toolchain-foundation
plan: 03
subsystem: infra
tags: [github-actions, hlint, fourmolu, stack, ghc2024, madr, adr, ci]

# Dependency graph
requires:
  - phase: none
    provides: wave-1 plan with no dependencies; the workflow forward-references artifacts from plans 01-01 and 01-04
provides:
  - "`.github/workflows/ci.yml` — one ubuntu job that builds with `--pedantic`, gates on generated-`.cabal` freshness, runs the conformance suite blocking, asserts the red state is visible, and reports hlint/fourmolu advisorily"
  - "`.hlint.yaml` — the `-XGHC2024` argument hlint needs to parse GHC2024 sources"
  - "`fourmolu.yaml` — verbatim `fourmolu 0.20.1.0 --print-defaults`, the formatter contract Phase 7 flips to blocking"
  - "`docs/adr/0001-harness-e2e-tiering.md` — the E2E-03 decision the Phase 10 bridge PR cites by path"
  - "`docs/adr/README.md` — the ADR index declaring MADR 4.0.0 and the numbering/immutability rules"
  - "`README.md` — a contributor path from clean clone to green `stack test` with the red state explained"
affects: [phase-2-transport, phase-5-golden-tests, phase-7-echo-example-and-conformance-gate, phase-8-bridge, phase-10-end-to-end-validation]

# Tech tracking
tech-stack:
  added: [haskell-actions/setup@v2.12.0, actions/cache@v5, actions/checkout@v6, haskell-actions/run-fourmolu@v13, hlint 3.10, fourmolu 0.20.1.0, MADR 4.0.0]
  patterns:
    - "Every GitHub Action pinned in this repo declares node24; node20 actions are rejected because GitHub removes Node 20 from runners on 2026-09-16"
    - "Advisory-then-blocking lint: `continue-on-error: true` carries an inline comment naming the phase that removes it"
    - "Generated config is generated, never transcribed: `fourmolu.yaml` comes from the same pinned binary CI runs"
    - "ADRs are MADR 4.0.0, immutable once accepted, superseded rather than edited"

key-files:
  created:
    - .github/workflows/ci.yml
    - .hlint.yaml
    - fourmolu.yaml
    - docs/adr/README.md
    - docs/adr/0001-harness-e2e-tiering.md
  modified:
    - README.md

key-decisions:
  - "E2E-03 resolved as ADR 0001: deepseek-harness CI runs a Node fixture plugin replaying `corpus/plugin.jsonl`; this repository owns both real-binary e2e tiers (E2E-01 keyless, E2E-02 keyed)"
  - "Option (a) — a GHC job in harness CI — is rejected on cost, not on principle; ADR 0001 records the `python-runtime` precedent at `ci.yml:301` honestly so the revisit trigger is unambiguous"
  - "`actions/cache@v5` rather than `@v4`: `@v4` is node20, and pinning it would reintroduce the exact runner deprecation that rules out `haskell-actions/hlint-setup`"
  - "hlint is installed from the 3.10 release tarball, not the tagged `hlint-setup`/`hlint-run` actions, because those still declare node20"
  - "`--system-ghc --no-install-ghc` stay CLI flags in the workflow and never enter `stack.yaml`, so a clean local clone still gets a Stack-managed GHC (TOOL-03)"
  - "`stack test` is not given `--test-arguments='--no-create'` until Phase 5 lands the first golden; the tasty-golden ingredient is unregistered before then and rejects the flag"
  - "Linux-only in Phase 1; the Windows/macOS matrix is deferred to Phase 2 with the NDJSON transport, and the deferral is recorded in the workflow itself rather than left as an omission"
  - "No CI status images in the README until plan 01-05 enables Actions on both remotes"

patterns-established:
  - "Pattern: every advisory CI step names, in a comment, the phase that makes it blocking — the flip is scheduled, not aspirational"
  - "Pattern: both linters are told about GHC2024 explicitly, because neither hlint nor fourmolu reads `default-language` from the `.cabal`"
  - "Pattern: the `.cabal` freshness gate (`git diff --exit-code -- '*.cabal'`) makes a stale hpack regeneration a CI failure rather than a silently-building tree"
  - "Pattern: `set -o pipefail` with an explicit `shell: bash` wherever a build command is piped through `tee`; the runner's default `bash -e` does not set it"

requirements-completed: [TOOL-02, E2E-03]

# Metrics
duration: 3min
completed: 2026-08-25
---

# Phase 1 Plan 03: CI, Linter Configuration, and ADR 0001 Summary

**A node24-only GitHub Actions workflow that builds `--pedantic`, gates `.cabal` freshness, runs the conformance suite blocking with an asserted-visible red state, and reports hlint 3.10 / fourmolu 0.20.1.0 advisorily — plus ADR 0001 fixing the harness e2e tier as the Node corpus fixture.**

## Performance

- **Duration:** 3 min
- **Started:** 2026-08-25T20:38:22Z
- **Completed:** 2026-08-25T20:41:44Z
- **Tasks:** 3
- **Files modified:** 6 (5 created, 1 rewritten)

## Accomplishments

- **E2E-03 is settled in writing before the bridge PR exists.** `docs/adr/0001-harness-e2e-tiering.md` records, in MADR 4.0.0 form, that deepseek-harness CI accepts a Node fixture plugin replaying the shared corpus, and that this repository owns E2E-01 and E2E-02. Its `### Confirmation` section argues the exception to the harness's "prefer the real implementation over a mock" rule on four checkable grounds — same corpus bytes, checksum-vendored corpus, `--dump-manifest` diffed against the harness's own `assertSupportedJsonSchema`, and both real-binary tiers owned here. Phase 10 can cite it by path instead of relitigating it in review.
- **TOOL-02 is live as a single workflow file.** `build` and `conformance` both carry `--pedantic` so they share one flag set and the second reuses the first's artifacts; `generated .cabal is current` fails on a stale hpack run; `red state is visible` is blocking.
- **No node20 action anywhere in the workflow.** `setup@v2.12.0`, `cache@v5`, `checkout@v6`, and `run-fourmolu@v13` are all node24; hlint comes from its release tarball precisely because `hlint-setup`/`hlint-run` are not.
- **`fourmolu.yaml` is machine-generated** from the same 0.20.1.0 binary CI pins (verified `fourmolu 0.20.1.0 … ghc-lib-parser 9.14.1.20251220`), so the Phase 7 flip-to-blocking cannot become a silent whole-tree reformat.
- **`docs/adr/README.md` pre-empts a format argument on ADR 0002** by declaring MADR 4.0.0, the `NNNN-kebab-title.md` naming, and the "accepted ADRs are superseded, never edited" rule.

## Task Commits

Each task was committed atomically:

1. **Task 1: ADR index and ADR 0001 (e2e tiering)** — `0ba412d` (docs)
2. **Task 2: CI workflow and hlint configuration** — `c5bdb25` (ci)
3. **Task 3: Generated `fourmolu.yaml` and README rewrite** — `e1477a7` (docs)

## Files Created/Modified

- `docs/adr/README.md` — ADR index: declares MADR 4.0.0, `NNNN-kebab-title.md` naming, the status-only edit rule, and the records table.
- `docs/adr/0001-harness-e2e-tiering.md` — the E2E-03 decision. Front matter uses MADR 4.0.0 keys (`status`, `date`, `decision-makers`, `consulted`, `informed`); sections cover Context, Drivers, three Considered Options, Decision Outcome, Consequences, Confirmation, per-option Pros and Cons, and More Information with the revisit trigger.
- `.github/workflows/ci.yml` — one `ubuntu-latest` job, 45-minute timeout, PR-only `cancel-in-progress`, Stack root + `.stack-work` cached on `hashFiles('stack.yaml.lock', 'package.yaml')`.
- `.hlint.yaml` — three lines: a comment explaining why, and `- arguments: [-XGHC2024]`.
- `fourmolu.yaml` — verbatim `--print-defaults` output; `indentation: 4`, `column-limit: none`, `function-arrows: trailing`, `comma-style: leading`, `import-export-style: diff-friendly`, `haddock-style: multi-line`, `single-constraint-parens: always`, `respectful: true`.
- `README.md` — rewritten from a one-line stub to 67 lines: purpose and honest red status, ghcup/Stack requirements with the Cabal ≥ 3.12 `GHC2024` caveat, four commands, the `--test-arguments` quoting trap, how `EXPECTED.md` and `OK (unexpected: …)` force the flip to green, layout, and the formatter/linter contract.

## Decisions Made

All decisions are recorded in the frontmatter `key-decisions` field. The two with the longest reach:

- **ADR 0001 chooses option (c), the Node fixture.** The harness gains no toolchain and no cross-repo build dependency, at the cost that a Haskell-only regression surfaces in this repository's CI rather than the harness's. The mitigation is structural, not procedural: the fixture and the Haskell conformance suite consume identical `corpus/plugin.jsonl` bytes, and Phase 8 vendors the corpus with a checksum test so drift fails loud.
- **node24 is a hard filter on every action.** GitHub removes Node 20 from the runners on 2026-09-16. This is why `hlint-setup`/`hlint-run` are avoided in favour of a tarball download — and, less obviously, why `actions/cache` is pinned at `@v5`. Pinning `@v4` would have quietly reintroduced the same deprecation the hlint decision exists to dodge.

## Deviations from Plan

None — plan executed exactly as written.

The plan's `<verified_facts>` block had already corrected three of the research document's claims (the fourmolu asset is a zip containing a directory rather than a tarball; `--no-create` is invalid before a golden exists; `-XGHC2024` is the right hlint flag spelling). Because those corrections were carried into the plan text, no discovery work was needed during execution and no deviation rule fired.

## Issues Encountered

- **The pinned fourmolu binary did not need re-downloading.** `fourmolu-0.20.1.0-linux-x86_64/fourmolu` was already unpacked on this machine from the research session that verified the plan's facts. Its `--version` was re-checked (`0.20.1.0 … ghc-lib-parser 9.14.1.20251220`) before generating `fourmolu.yaml`, so the generated file is the pinned version's output, not a stale artifact. The plan's stop-and-report instruction for a failed download was therefore never reached.
- **`fourmolu.yaml` ends with a trailing blank line**, because that is literally what `--print-defaults` emits. Kept verbatim rather than trimmed: the file's whole value is being byte-identical to the pinned binary's output, and the repository has no `git diff --check` pre-commit hook that would object.
- **Concurrent plans in the same tree.** Plans 01-01 and 01-02 were modifying `.planning/` and `src/` while this plan ran. Only this plan's six files were ever staged; no `git add -A` was used, and no commit raced.

## Forward References (not yet resolvable)

Two references in `.github/workflows/ci.yml` and `README.md` point at artifacts other plans create. Both resolve before CI first runs, since plan 01-05 is what enables Actions on the remotes:

- `scripts/check-red-visible.sh` — created by plan 01-04 (wave 2).
- `PROTOCOL.md` and `corpus/` — created by plan 01-02.

## User Setup Required

None — no external service configuration required. Plan 01-05 owns enabling GitHub Actions on both remotes; until then the workflow is committed but never triggered.

## Next Phase Readiness

- **Ready:** TOOL-02 and E2E-03 are complete. Phase 10's bridge PR has a citable decision at `docs/adr/0001-harness-e2e-tiering.md` and no longer carries the "keyless snapshot needs GHC, but harness CI has no GHC" risk as an open question (PITFALLS.md Pitfall 15).
- **Scheduled follow-ups, each recorded in the file that must change:**
  - Phase 2 adds the Windows/macOS matrix alongside the NDJSON transport; the deferral comment sits at the top of `jobs:` in the workflow.
  - Phase 5 restores `--test-arguments='--no-create'` once the first golden registers the tasty-golden ingredient; the README states why it fails today.
  - Phase 7 removes `continue-on-error` from both the hlint and fourmolu steps in the same change that deletes the last `corpus/*/EXPECTED.md`.
  - Plan 01-05 may add CI status images once Actions is enabled on both remotes.
- **Concern:** the workflow's first real execution happens in plan 01-05. Until a run exists, the YAML is verified structurally (it parses; step names, `continue-on-error` flags, and action pins were asserted) but not empirically — an action-input typo would surface only on that first run.

---
*Phase: 01-protocol-freeze-and-toolchain-foundation*
*Completed: 2026-08-25*

## Self-Check: PASSED

All 7 claimed files exist on disk; all 3 claimed task commits (`0ba412d`, `c5bdb25`, `e1477a7`) are present in `git log --all`.
