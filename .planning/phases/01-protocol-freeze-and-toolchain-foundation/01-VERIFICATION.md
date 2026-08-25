---
phase: 01-protocol-freeze-and-toolchain-foundation
verified: 2026-08-25T21:16:50Z
status: passed
score: 7/7 must-haves verified
---

# Phase 1: Protocol Freeze and Toolchain Foundation Verification Report

**Phase Goal:** The wire is decided, written down, and pinned by shared bytes, and a clean clone builds and tests on a sound toolchain.
**Verified:** 2026-08-25T21:16:50Z
**Status:** passed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
| --- | --- | --- | --- |
| 1 | A clean-clone toolchain (`lts-24.56`/GHC 9.10.3) builds the library, executable, and test-suite warning-free under `--pedantic` | ✓ VERIFIED | `stack build --pedantic --test --no-run-tests` exits 0, no warnings; `stack.yaml` is `snapshot: lts-24.56`, three lines; `git diff --exit-code -- '*.cabal'` clean |
| 2 | `PROTOCOL.md` freezes the wire (methods, manifest, error codes, params/batch rules, tool-result envelope, large-integer policy) readable without code | ✓ VERIFIED | All 14 `## ` headings present; all 10 error codes (`-32700,-32600,-32601,-32602,-32603,-32800,-32004,-32001,-32002,-32005`) present; retired codes (`-32003`,`-32006`) absent; ASCII hyphen-minus only; `section.changed`, `matchTools`, `SCENARIO.json` all present |
| 3 | Every required scenario exists as host/plugin frames, byte-pinned and deterministic | ✓ VERIFIED | 17 `corpus/*/` dirs, 17 `EXPECTED.md`; `cancel-unknown/plugin.jsonl` is 0 bytes; `malformed-oversize/host.jsonl` line 1 is exactly 300 bytes; `handshake/plugin.jsonl` and `section-changed/plugin.jsonl` line 1 byte-identical |
| 4 | `stack test` exits 0 while all 17 corpus scenarios and 4 property families visibly fail, naming their owning phase, and no scenario has silently flipped green | ✓ VERIFIED | Ran `stack test` live: `All 26 tests passed`, 21 `FAIL (expected:`, 0 `OK (unexpected:` — matches the plan's verified figures exactly |
| 5 | `scripts/check-red-visible.sh` is the executed acceptance gate over the captured log | ✓ VERIFIED | Executable; run against the live log: `check-red-visible: red state visible (21 expected failures), no unexpected passes` |
| 6 | CI builds, gates on `.cabal` freshness, runs conformance blocking, and reports hlint/fourmolu advisorily, on both remotes | ✓ VERIFIED | `.github/workflows/ci.yml` parses; `conformance`/`build`/`generated .cabal is current`/`red state is visible` have no `continue-on-error`; `hlint`/`fourmolu` both `continue-on-error: true`; live `gh run view` on both recorded run IDs (`32898033180`, `32898035528`) reports `"conclusion":"success"`, `"status":"completed"`, matching head SHA `242ebfa0…` |
| 7 | E2E-03 is settled in writing before the bridge PR exists | ✓ VERIFIED | `docs/adr/0001-harness-e2e-tiering.md` exists, `status: accepted`, MADR 4.0.0 keys, `### Confirmation` section present, names `E2E-01`/`E2E-02`, cites `docs/testing.md` and `python-runtime`/`ci.yml:301` |

**Score:** 7/7 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
| --- | --- | --- | --- |
| `stack.yaml` | `snapshot: lts-24.56`, 3 lines, no extra-deps | ✓ VERIFIED | Confirmed by grep |
| `stack.yaml.lock` | committed snapshot sha256 | ✓ VERIFIED | Committed and tracked by git |
| `package.yaml` | hpack source, `language: GHC2024`, 3 stanzas | ✓ VERIFIED | Present, `stack build` regenerates `.cabal` drift-free |
| `haskell-deepseek-plugin-sdk.cabal` | generated, committed, in sync | ✓ VERIFIED | `git diff --exit-code -- '*.cabal'` clean after build |
| `src/DeepSeek/Plugin*.hs` (7 stubs) | Haddock-only, no `data`/`newtype`/`type` decls | ✓ VERIFIED | All 7 files present; `grep -rqE '^(data|newtype|type) ' src/` exits 1 |
| `app/echo/Main.hs`, `test/Main.hs` | placeholder / real tasty entry point | ✓ VERIFIED | `test/Main.hs` builds the scenario tree via `Corpus.listScenarios` and wires `Properties.tests` |
| `PROTOCOL.md` | 13 numbered sections + Deferred | ✓ VERIFIED | All headings present, all codes present |
| `corpus/<17 scenarios>/{host,plugin}.jsonl,EXPECTED.md` | executable spec | ✓ VERIFIED | 17 dirs, 17 EXPECTED.md, all live checks pass |
| `corpus/malformed-oversize/SCENARIO.json` | `{"maxFrameBytes":256}` | ✓ VERIFIED | Present, referenced in PROTOCOL.md §12 |
| `.github/workflows/ci.yml` | single workflow, both remotes | ✓ VERIFIED | Parses; correct step gating |
| `.hlint.yaml`, `fourmolu.yaml` | linter configs | ✓ VERIFIED | Present with expected content |
| `docs/adr/README.md`, `docs/adr/0001-harness-e2e-tiering.md` | ADR index + E2E-03 decision | ✓ VERIFIED | Present, correct MADR 4.0.0 form |
| `test/Conformance/Corpus.hs`, `test/Conformance/Properties.hs` | corpus enumeration + property signatures | ✓ VERIFIED | Present, exports match interface, build clean |
| `scripts/check-red-visible.sh` | phase acceptance gate | ✓ VERIFIED | Executable, behaves correctly on live log |
| `README.md` | contributor path | ✓ VERIFIED | 67 lines, mentions PROTOCOL.md/corpus/EXPECTED.md/stack build/stack test/ghcup |

### Key Link Verification

| From | To | Via | Status | Details |
| --- | --- | --- | --- | --- |
| `package.yaml` | `haskell-deepseek-plugin-sdk.cabal` | hpack on every build | ✓ WIRED | `git diff --exit-code -- '*.cabal'` clean |
| `test/Main.hs` | `Conformance.Corpus`/`Conformance.Properties` | `listScenarios` + `tests` groups | ✓ WIRED | Live `stack test` shows both groups executing (`corpus`, `properties`) |
| `Conformance.Corpus` | `corpus/<scenario>/EXPECTED.md` | `doesFileExist` decides `expectFailBecause` | ✓ WIRED | 21 `FAIL (expected:` lines, 0 unexpected |
| `PROTOCOL.md` | `corpus/handshake/plugin.jsonl` | §4 cites the file | ✓ WIRED | `grep -q 'corpus/handshake/plugin.jsonl' PROTOCOL.md` |
| `.github/workflows/ci.yml` | `scripts/check-red-visible.sh` | blocking step | ✓ WIRED | Step present, non-advisory, and script executes correctly against the CI-style log |
| local `main` | both remotes | `git push` | ✓ WIRED | `gh run view` on both remotes' recorded run IDs confirms `success` at the recorded head SHA; two additional later runs (from the summary-recording commit) also report `success` |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
| --- | --- | --- | --- | --- |
| PROTO-01 | 01-02 | `PROTOCOL.md` freezes methods, manifest, error codes, params/batch rules | ✓ SATISFIED | PROTOCOL.md verified above |
| PROTO-02 | 01-02, 01-04 | Shared conformance corpus, both host/plugin frames | ✓ SATISFIED | 17-scenario corpus + `requiredScenariosPresent` meta-test passing |
| PROTO-03 | 01-02 | Host-initiated handshake, version mismatch fails loud | ✓ SATISFIED | `corpus/version-mismatch/` scenario, PROTOCOL.md §5 |
| PROTO-04 | 01-02, 01-04 | Manifest declares tools/guards/sections/subagents | ✓ SATISFIED | `manifestDeclaresEveryContribution` + `manifestToolNamesAreWellFormed` meta-tests pass |
| TOOL-01 | 01-01, 01-04 | `stack.yaml` pinned `lts-24.56`, library+exe+test-suite, `GHC2024`, `-Wall`, RTS opts | ✓ SATISFIED | Verified via live `stack build --pedantic` |
| TOOL-02 | 01-03, 01-05 | CI builds, tests, runs hlint/fourmolu on both remotes | ✓ SATISFIED | Live `gh run view` confirms `success` on both recorded runs |
| E2E-03 | 01-03 | Maintainer alignment recorded on e2e tier | ✓ SATISFIED | `docs/adr/0001-harness-e2e-tiering.md` verified |

No orphaned requirements found: all 7 IDs mapped to "Phase 1" in `.planning/REQUIREMENTS.md`'s traceability table (PROTO-01..04, TOOL-01, TOOL-02, E2E-03) are claimed by at least one of the five plans' `requirements:` frontmatter, and all are marked `Complete` in REQUIREMENTS.md.

### Anti-Patterns Found

None. `grep -rnE "TODO|FIXME|XXX|HACK|PLACEHOLDER" src/ app/ test/` returned no matches (the plan's deliberate placeholder binary `app/echo/Main.hs` names Phase 7 explicitly in Haddock, which is documentation of a scheduled follow-up, not a stub anti-pattern — it correctly exits non-zero so it cannot be mistaken for a working peer). `grep -rqE '^(data|newtype|type) ' src/` exits 1, confirming no stub types were introduced into the library stubs.

### Human Verification Required

None. Every must-have in this phase was mechanically checkable (file existence/content, `stack build`/`stack test` exit codes and output, `gh run view` against live GitHub Actions runs), and all were checked live rather than trusted from the SUMMARY documents.

### Gaps Summary

No gaps. All 7 observable truths verified, all required artifacts exist and are substantive and wired, all key links are wired, all 7 requirement IDs are satisfied and accounted for with no orphans, and no anti-patterns were found. The live re-run of `stack build`, `stack test`, `scripts/check-red-visible.sh`, and `gh run view` against the actual recorded CI run IDs reproduced the SUMMARY documents' claimed figures exactly (`All 26 tests passed`, 21 expected failures, 0 unexpected passes, both CI runs `success`).

One minor observation, not a gap: the phase's task instructions asked to confirm "the four CI run URLs" in `01-05-SUMMARY.md`, but that file records exactly two run URLs (one per remote), which is what plan 01-05's own success criteria required ("two recorded workflow run URLs, both concluded success"). Live querying of GitHub found two additional, later runs on both remotes (triggered by the commit that added the SUMMARY itself, hence not documentable in advance) — all four runs across the two remotes report `conclusion: success`. This is expected chicken-and-egg behavior of committing a summary about a commit's own CI run, not a defect.

---

*Verified: 2026-08-25T21:16:50Z*
*Verifier: Claude (gsd-verifier)*
