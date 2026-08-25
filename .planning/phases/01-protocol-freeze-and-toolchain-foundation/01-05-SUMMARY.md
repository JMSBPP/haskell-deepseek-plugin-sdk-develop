---
phase: 01-protocol-freeze-and-toolchain-foundation
plan: 05
subsystem: infra
tags: [github-actions, ci, stack, ghc-9.10.3, hlint, fourmolu, git-remotes]

# Dependency graph
requires:
  - phase: 01-01
    provides: the `lts-24.56` / GHC 9.10.3 pin, `package.yaml`, and the committed `.cabal` + `stack.yaml.lock` the runner resolves against
  - phase: 01-02
    provides: the 17 corpus scenario directories the conformance step replays
  - phase: 01-03
    provides: `.github/workflows/ci.yml`, `.hlint.yaml`, and `fourmolu.yaml` — the workflow definition this plan executes remotely
  - phase: 01-04
    provides: the tasty conformance suite and `scripts/check-red-visible.sh`, the two steps that turn the build into a phase gate
provides:
  - two recorded `ci` workflow runs, both concluded `success` on the same commit `242ebfa`, one per remote
  - confirmation that GitHub Actions is enabled with `allowed_actions: all` on both the fork and the parent repository
  - the Phase 7 advisory-linter baseline measured on the runner rather than locally — `hlint` reports `No hints` and `fourmolu --mode check --check-idempotence` exits 0 on both remotes
  - proof that the conformance figures reproduce off this machine: `All 26 tests passed` with `21 expected failures, no unexpected passes` on both runners
affects: [02-transport-and-replay, 07-linters-blocking, 10-end-to-end-validation]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "TOOL-02's signal is two runs, not one workflow file: a green parent says nothing about the fork"
    - "`gh api repos/<r>/actions/permissions` answers 'are Actions on?' automatically, so a silent repository is distinguished from a failing one before any run is asserted"

key-files:
  created:
    - .planning/phases/01-protocol-freeze-and-toolchain-foundation/01-05-SUMMARY.md
  modified:
    - .planning/STATE.md
    - .planning/ROADMAP.md

key-decisions:
  - "The task 2 checkpoint resolved as a no-op confirmation: both repositories already reported {enabled: true, allowed_actions: all}, so no Settings visit and no re-trigger was needed"
  - "The advisory linters passed on the runner as well as locally, so Phase 7's flip to blocking remains a two-line deletion of `continue-on-error` with no reformat debt"

patterns-established:
  - "Every phase that changes CI-visible behavior records both run URLs, not one"
  - "Advisory-linter results are recorded as a dated baseline at the moment they are still advisory, so the phase that makes them blocking knows what it is inheriting"

requirements-completed: [TOOL-02]

# Metrics
duration: 15min
completed: 2026-08-25
---

# Phase 1 Plan 05: Remote CI Proof on Both Remotes Summary

**Commit `242ebfa` pushed to the fork and the parent, producing two independent `ci` runs that both concluded `success` in ~7.5 min on a cold cache — each building under `--pedantic`, replaying the 17-scenario corpus to `All 26 tests passed`, and passing the red-visible gate at `21 expected failures, no unexpected passes`.**

## Performance

- **Duration:** 15 min (dominated by two cold-cache Stack builds running concurrently)
- **Started:** 2026-08-25T20:53:47Z
- **Completed:** 2026-08-25T21:08:38Z
- **Tasks:** 3
- **Files modified:** 3 (1 created, 2 modified — all planning documents; the plan changes no source)

## The Two Run URLs

| Remote | Repository | Run URL | Head SHA | Conclusion | Duration |
| --- | --- | --- | --- | --- | --- |
| `origin` | `JMSBPP/haskell-deepseek-plugin-sdk-develop` (fork) | https://github.com/JMSBPP/haskell-deepseek-plugin-sdk-develop/actions/runs/32898033180 | `242ebfa` | **success** | 7m38s |
| `upstream` | `d2p-finance/haskell-deepseek-plugin-sdk` (parent) | https://github.com/d2p-finance/haskell-deepseek-plugin-sdk/actions/runs/32898035528 | `242ebfa` | **success** | 7m11s |

Both runs are `event=push`, `run_attempt=1`, triggered within one second of each other by the two pushes of the same commit. Neither needed a re-run.

## Accomplishments

- Both remotes fast-forwarded `21d7ac4 → 242ebfa`, a 15-commit range carrying the whole phase: `PROTOCOL.md`, the 17-scenario `corpus/`, the hpack package layout, the conformance suite, and `.github/workflows/ci.yml`. No force-push and no history rewrite, so the two runs are comparable by construction.
- Actions confirmed enabled on both repositories before any run was asserted, closing RESEARCH Pitfall 8 — the failure mode where a disabled fork produces silence that a script reads as success.
- All 11 workflow steps concluded `success` on both runners, including the two steps that make the build a phase gate rather than a compile check.
- The conformance figures reproduced exactly off this machine, which is the first evidence that the suite is not machine-dependent.

## Task Commits

This plan changes no source files — its three tasks are `git push`, a GitHub settings read, and `gh` queries. The artifacts are the two remote run records, not a diff. Per-task commits therefore do not apply; the only commit is the plan metadata.

1. **Task 1: Push the phase to both remotes** - no commit (push of existing `242ebfa`; `git status --porcelain` empty before and after)
2. **Task 2: Confirm GitHub Actions is enabled on both repositories** - no commit (no-op confirmation, see below)
3. **Task 3: Confirm both runs concluded successfully and record the URLs** - no commit (`gh` queries only)

**Plan metadata:** see the `docs(01-05)` commit carrying this summary, `.planning/STATE.md`, and `.planning/ROADMAP.md`.

## Task 2: No-Op Confirmation, Not a Settings Change

The plan required recording *which* of the two this was, because it is the difference between "the setting held" and "the setting had drifted". **It was a no-op confirmation.** No Settings page was opened, nothing was changed, and no run had to be re-triggered.

Both repositories returned identical payloads from `gh api repos/<r>/actions/permissions` immediately after the pushes:

```json
{"enabled":true,"allowed_actions":"all","sha_pinning_required":false}
```

and both immediately listed a queued `ci` run for `242ebfa`, so the "no runs at all" branch of the checkpoint never opened. The checkpoint was still worth keeping: the payload is a per-repository setting a human can change and no local command can restore, and `sha_pinning_required: false` matters because the workflow pins actions by tag (`actions/checkout@v6`, `haskell-actions/setup@v2.12.0`) rather than by SHA — if that setting is ever enabled, this workflow stops running.

## Per-Step Results (identical on both runs)

| # | Step | origin | upstream |
| --- | --- | --- | --- |
| 1 | Set up job | success | success |
| 2 | `actions/checkout@v6` | success | success |
| 3 | `haskell-actions/setup@v2.12.0` | success | success |
| 4 | `actions/cache@v5` | success | success |
| 5 | build dependencies | success | success |
| 6 | build (`--pedantic`) | success | success |
| 7 | generated `.cabal` is current | success | success |
| 8 | conformance | success | success |
| 9 | red state is visible | success | success |
| 10 | hlint *(advisory)* | success | success |
| 11 | fourmolu *(advisory)* | success | success |

Log evidence, identical on both runners:

```
All 26 tests passed (0.01s)
check-red-visible: red state visible (21 expected failures), no unexpected passes
```

`stack build --pedantic` (`-Werror`) passed on both, confirming Phase 1's decision to keep `-Werror` in CI rather than `package.yaml` costs no signal: the runner's GHC 9.10.3 is the pinned version, so a clean-tree warning would have failed here.

## Phase 7 Advisory-Linter Baseline

Recorded because Phase 7 makes both steps blocking and needs to know what it inherits. **Neither linter reported a finding on either remote — both are already green, so the flip to blocking is a deletion of two `continue-on-error: true` lines with no reformat debt.**

| Tool | Version | Invocation | origin | upstream |
| --- | --- | --- | --- | --- |
| hlint | 3.10 (release tarball) | `hlint src app test` | `No hints` | `No hints` |
| fourmolu | 0.20.1.0 (`ba1f592`) | `--color always --check-idempotence --mode check --ghc-opt -XGHC2024` over 11 files | exit 0, no `Would reformat` | exit 0, no `Would reformat` |

Two details worth carrying into Phase 7:

- `haskell-actions/run-fourmolu@v13` adds **`--check-idempotence`**, which the local plan-01-04 invocation did not use. The tree passes the stricter remote check too, so the local and CI fourmolu verdicts agree today.
- fourmolu covered exactly the 11 files the `pattern` glob resolves (7 under `src/`, 1 under `app/echo/`, 3 under `test/`). When Phase 7 makes it blocking, any module added outside those three roots would silently escape the check.

## Files Created/Modified

- `.planning/phases/01-protocol-freeze-and-toolchain-foundation/01-05-SUMMARY.md` (created) - this document, carrying the two run URLs and the advisory baseline
- `.planning/STATE.md` (modified) - position advanced to plan 5 of 5, progress 100%, plan-05 metric row, decisions appended
- `.planning/ROADMAP.md` (modified) - Phase 1 progress row `4/5 → 5/5`

## Decisions Made

- **Did not commit the `.planning/config.json` working-tree change.** The diff was not a flag change — `"_auto_chain_active": false` is already in `HEAD` — but purely the loss of the file's trailing newline by a tool write. Restoring the newline returned the file byte-identical to `HEAD`, giving the clean tree task 1 requires without a commit that records no decision. Task 1's precondition (`git status --porcelain` empty) was then satisfied honestly rather than by absorbing a whitespace regression into the history.
- **Watched each run to completion with `gh run watch --exit-status` rather than polling once and asserting.** A cold-cache Stack build takes 7-8 min here; a single early poll would have read `queued` and mistaken "not started" for a result.

## Deviations from Plan

None - plan executed exactly as written. All three tasks ran in order, every acceptance criterion passed as stated, and the checkpoint resolved along the path the plan itself predicted (`{"enabled":true,"allowed_actions":"all"}` on both repositories, hence a confirmation rather than a Settings visit).

None of the five anticipated failures in task 3 occurred: the `.cabal` was current, no scenario passed unexpectedly, `check-red-visible.sh` retained its executable bit through the push, `--pedantic` found no warning a local incremental build had hidden, and neither advisory linter showed a red X.

## Issues Encountered

None. `TOOL-02` was already checked `[x]` in `REQUIREMENTS.md` and marked `Complete` in the traceability table by plan 01-03, which authored the workflow file. That was one plan premature — a workflow definition is not a workflow run — and this plan supplies the evidence that retroactively justifies it. No edit to `REQUIREMENTS.md` was needed; the state is now true rather than merely asserted.

## User Setup Required

None - no external service configuration required. GitHub Actions was already enabled on both repositories.

## Next Phase Readiness

- **Phase 1 is complete pending orchestrator verification.** TOOL-02 is proven end to end, and every other Phase 1 requirement was delivered by plans 01-01 through 01-04.
- Phase 2 inherits a warm Actions cache on both remotes keyed by `hashFiles('stack.yaml.lock', 'package.yaml')`, so runs stay in the 7-8 min band until the resolver or dependency set moves. Phase 2 also owns adding the Windows/macOS matrix alongside the NDJSON transport, where newline mode and process termination first differ by platform — the `restore-keys: ${{ runner.os }}-stack-` prefix already anticipates a per-OS cache.
- Phase 7 inherits a clean advisory baseline on both linters, measured on the runner, and needs only to delete the two `continue-on-error: true` lines in the same change that removes the last corpus `EXPECTED.md`.
- Residual concern, unchanged from plan 01-03: every action in this workflow is pinned by tag, not by SHA. Both repositories currently report `sha_pinning_required: false`; if an organization policy ever enables SHA pinning on `d2p-finance`, the workflow stops running with no code change on this side.

---
*Phase: 01-protocol-freeze-and-toolchain-foundation*
*Completed: 2026-08-25*

## Self-Check: PASSED

All three claimed files exist on disk. Both run URLs appear verbatim in this summary. Commit `242ebfa` is present in the repository history and is the head of `main`, `origin/main`, and `upstream/main`. Both `gh run list --workflow ci --limit 1` queries report `conclusion: success` on that SHA.
