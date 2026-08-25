---
phase: 1
slug: protocol-freeze-and-toolchain-foundation
status: approved
nyquist_compliant: true
wave_0_complete: false
created: 2026-08-25
updated: 2026-08-25
---

# Phase 1 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

Phase 1 has an unusual acceptance shape: **the suite is green because everything
in it is failing on purpose.** `stack test` must exit 0 while printing
`FAIL (expected: …)` for every corpus scenario and every property family, and
must print `OK (unexpected: …)` for none of them. `scripts/check-red-visible.sh`
is that assertion as a command, so the phase gate is not a manual read of test
output.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | `tasty 1.5.4` + `tasty-hunit 0.10.2` + `tasty-golden 2.3.6` + `tasty-hedgehog 1.4.0.2` + `tasty-expected-failure 0.12.3` + `hedgehog 1.5` |
| **Config file** | `package.yaml` → `tests: conformance:` (❌ Wave 0 — created by plan 01) |
| **Quick run command** | `stack test --test-arguments="-p '/meta/'"` |
| **Full suite command** | `stack test 2>&1 \| tee conformance.log && scripts/check-red-visible.sh conformance.log` |
| **Compile gate** | `stack build --pedantic --test --no-run-tests` |
| **Estimated runtime** | < 1 second for the suite; the compile gate dominates |

`--test-arguments="--no-create"` is **not** usable in Phase 1: `--no-create` is
contributed by the `tasty-golden` ingredient, which is only registered once a
golden test exists in the tree. Verified: the suite rejects it with
`Invalid option '--no-create'`. Phase 5 adds the first golden and the flag with it.

---

## Sampling Rate

- **After every task commit:** `stack build --pedantic --test --no-run-tests` plus the grep gates named in that task's `acceptance_criteria`
- **After every plan wave:** `stack test 2>&1 | tee conformance.log && scripts/check-red-visible.sh conformance.log` and `git diff --exit-code -- '*.cabal'`
- **Before `/gsd:verify-work`:** the full suite green with red visible, all grep gates passing, and one successful CI run URL recorded per remote
- **Max feedback latency:** < 1 second for the suite; ~1 minute for an incremental `--pedantic` build

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 1-01-01 | 01 | 1 | TOOL-01 | grep | `grep -qx 'snapshot: lts-24.56' stack.yaml && grep -qx 'language: GHC2024' package.yaml` | ❌ W0 | ⬜ pending |
| 1-01-02 | 01 | 1 | TOOL-01 | build | `stack build --pedantic --test --no-run-tests && git diff --exit-code -- '*.cabal'` | ❌ W0 | ⬜ pending |
| 1-02-01 | 02 | 1 | PROTO-02, PROTO-03, PROTO-04 | file + JSON parse | 13 directories present, both frame files each, every non-exempt line one JSON value | ❌ W0 | ⬜ pending |
| 1-02-02 | 02 | 1 | PROTO-02 | grep | every `corpus/*/EXPECTED.md` line 1 matches `^# Flipped by: Phase [2-7] — .+` | ❌ W0 | ⬜ pending |
| 1-02-03 | 02 | 1 | PROTO-01, PROTO-03 | doc gate | all 14 `## ` headings present; all 11 error codes present; `-32003` and `section/changed` absent repo-wide | ❌ W0 | ⬜ pending |
| 1-03-01 | 03 | 1 | E2E-03 | grep | `grep -q '^status: accepted' && grep -q '^### Confirmation' && grep -q 'docs/testing.md' && grep -q 'python-runtime'` on ADR 0001 | ❌ W0 | ⬜ pending |
| 1-03-02 | 03 | 1 | TOOL-02 | YAML parse + grep | workflow parses; `conformance` and `red state is visible` have no `continue-on-error`; `hlint`/`fourmolu` do; no `hlint-setup`/`hlint-run` | ❌ W0 | ⬜ pending |
| 1-03-03 | 03 | 1 | TOOL-02 | grep | `grep -q '^indentation: 4' fourmolu.yaml` and the README command/red-state sections | ❌ W0 | ⬜ pending |
| 1-04-01 | 04 | 2 | PROTO-02, PROTO-04 | unit (meta) | `stack test --test-arguments="-p '/meta/'"` — four `OK` lines | ❌ W0 | ⬜ pending |
| 1-04-02 | 04 | 2 | PROTO-02 | unit (property) | `stack test --test-arguments="-p '/properties/'"` — four `FAIL (expected: …)` | ❌ W0 | ⬜ pending |
| 1-04-03 | 04 | 2 | TOOL-01 | script | `scripts/check-red-visible.sh conformance.log` exits 0 reporting 17 expected failures; exits 1 on a seeded `OK (unexpected:` log | ❌ W0 | ⬜ pending |
| 1-05-01 | 05 | 3 | TOOL-02 | git | `git rev-parse HEAD origin/main upstream/main` — three identical SHAs | ❌ W0 | ⬜ pending |
| 1-05-03 | 05 | 3 | TOOL-02 | CLI | `gh run list --repo <each> --workflow ci --limit 1 --json conclusion,headSha` — `success` on the pushed SHA | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Phase Invariant

The check that actually decides the phase, implemented by
`scripts/check-red-visible.sh`:

```
stack test exits 0
  AND its output contains at least one 'FAIL (expected:'
  AND its output contains no 'OK (unexpected:'
```

Expected steady state at the end of Phase 1: `All 21 tests passed` — 13 corpus
scenarios failing as expected, 4 property families failing as expected, 4
meta-tests passing.

---

## Wave 0 Requirements

The repository has no test infrastructure at all, so every item is a gap. Waves
1 and 2 create them; no separate Wave 0 plan is needed, because plan 01 creates
the test-suite stanza and plan 04 creates the tests themselves.

- [ ] `package.yaml` `tests: conformance:` stanza — plan 01
- [ ] `stack.yaml` repinned to `lts-24.56` + committed `stack.yaml.lock` — plan 01
- [ ] `haskell-deepseek-plugin-sdk.cabal` regenerated and committed — plan 01
- [ ] `corpus/<13 scenarios>/{host.jsonl,plugin.jsonl,EXPECTED.md}` — plan 02
- [ ] `test/Main.hs`, `test/Conformance/Corpus.hs`, `test/Conformance/Properties.hs` — plan 04
- [ ] `scripts/check-red-visible.sh` — plan 04
- [ ] Framework install: **none**. The whole tasty + hedgehog set resolves from `lts-24.56` with no `extra-deps` (verified by a local build).

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| GitHub Actions enabled on both repositories | TOOL-02 | A fork has Actions disabled until an owner enables them in Settings; no CLI path exists that does not need an owner-scope token and an interactive policy choice | Open each repository's `/settings/actions`, select "Allow all actions and reusable workflows", save, then re-trigger the run. Plan 05 task 2. |
| CI green on both remotes | TOOL-02 | Requires a push and a runner; no local command produces this signal | `gh run list --repo <each> --workflow ci --limit 1 --json conclusion,headSha,url`. Plan 05 task 3 automates the assertion once the push has happened. |

---

## Known Non-Signals

Things that look like validation in Phase 1 but are not:

- **`stack run dsh-plugin-echo`** exits non-zero by design until Phase 7. That is not a failure.
- **A red X on the `hlint` or `fourmolu` CI step** with a green job is expected: both carry `continue-on-error: true` until Phase 7 flips them alongside the last `EXPECTED.md` deletion. The Phase 1 baseline is that both are already clean, so that flip is a one-line change rather than a tree-wide reformat.
- **`ignoreTest` / `ignoreTestBecause`** would make every scenario report `IGNORED`: never running, never flipping, never failing. Explicitly rejected; `expectFailBecause` is used precisely because an unexpected pass fails the suite.
- **Wiring the corpus as `tasty-golden` goldens** would let `--accept` rewrite the hand-authored spec with aeson's key order. Goldens belong on generated artifacts, starting with Phase 5's `--dump-manifest` output.

---

## Validation Sign-Off

- [x] All tasks have an `<automated>` verify or a documented manual-only reason
- [x] Sampling continuity: no 3 consecutive tasks without an automated verify
- [x] Wave 0 gaps are each owned by a named plan
- [x] No watch-mode flags
- [x] Feedback latency < 1s for the suite
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** approved 2026-08-25
