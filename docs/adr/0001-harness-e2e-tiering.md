---
status: accepted
date: 2026-08-25
decision-makers: repository owner (both haskell-deepseek-plugin-sdk and deepseek-harness)
consulted: —
informed: —
---

# End-to-end validation tier accepted by deepseek-harness CI

## Context and Problem Statement

deepseek-harness CI has no Haskell anywhere: a grep across all 18 workflow files
finds no GHC, Stack, or ghcup step. The workflows set up Node and Python only.

Meanwhile `deepseek-harness/docs/testing.md` requires, verbatim:

> Every non-trivial model-, protocol-, or human-visible change adds or updates a
> keyless scenario in the same PR through a runnable example's owning snapshot
> suite. Package tests, e2e assertions, mock/test-only compositions, and PR
> rationale do not replace the assembled transcript

and separately, "Prefer the real implementation over a mock: Mock only the
expensive or non-deterministic boundary (LLM adapter, network, clock); keep
everything downstream real."

The bridge PR (Phase 10) must therefore ship a keyless snapshot of a model
calling a remote plugin tool — which appears to require a Haskell binary inside a
repository whose CI cannot build one. This ADR settles which tier of end-to-end
validation that CI accepts, before the bridge PR exists, so the question is not
reopened during review.

## Decision Drivers

- The bridge PR must pass the harness's own gates unchanged.
- Snapshot replay must be deterministic on macOS and Linux.
- A cross-repo binary dependency in CI is a standing maintenance cost.
- The Haskell side must still be proven against a real process somewhere.

## Considered Options

- (a) Add a GHC/Stack job to deepseek-harness CI.
- (b) Commit a prebuilt `dsh-plugin-echo` binary to deepseek-harness.
- (c) A ~50-line Node fixture plugin replaying `corpus/plugin.jsonl` as the
  sanctioned harness-CI path, with the real-binary tiers living in this
  repository.

## Decision Outcome

Chosen option: **(c)**, the Node fixture plugin. The harness's keyless snapshot
drives the bridge against a fixture that replays the shared corpus. This
repository owns E2E-01 (keyless, the built binary through the fake host) and
E2E-02 (keyed, `dsh --profile headless` against the real binary).

### Consequences

- Good: the harness gains no toolchain and no cross-repo build dependency, and
  its snapshot stays fast and deterministic.
- Bad: the harness's snapshot never exercises the real Haskell process, so a
  Haskell-only regression is caught in this repository rather than in the
  harness's CI.
- Neutral: the corpus becomes a versioned cross-repo artifact that must be
  vendored with a checksum.

### Confirmation

This is the argued exception to the harness's "prefer the real implementation"
policy, and it rests on the corpus being a *shared artifact* rather than a mock:

- The Node fixture replays the same `corpus/plugin.jsonl` bytes the Haskell
  `conformance` suite replays, so "the fixture and the real plugin agree" is a
  checked fact rather than an assumption.
- The bridge PR vendors the corpus into deepseek-harness with a checksum test,
  so drift fails loud (Phase 8).
- `--dump-manifest` output is diffed against the harness's own
  `assertSupportedJsonSchema`, following the `code-runtime-python`
  `protocol-mirror.e2e.ts` pattern, so the Haskell schema is proven against the
  real validator rather than against a transcription of it.
- This repository owns both real-binary tiers: E2E-01 keyless and E2E-02 keyed.

## Pros and Cons of the Options

### (a) A GHC/Stack job in deepseek-harness CI

- Good: the harness's own snapshot exercises the real Haskell binary, with no
  exception to the testing policy needed.
- Good: the precedent exists. `python-runtime` is a distinct required PR job at
  `deepseek-harness/.github/workflows/ci.yml:301` (reusing
  `build-exe-for-python-sdk.yml`) that exists solely to run the Python SDK
  snapshot, and it is listed in the aggregate gate's `needs` at `ci.yml:481`.
  Option (a) is therefore not unprecedented — it is rejected on cost, not on
  principle.
- Bad: a GHC toolchain, several minutes of CI time on the platform matrix, and a
  standing cross-repo build dependency, all carried by maintainers who do not
  otherwise write Haskell.

### (b) A prebuilt `dsh-plugin-echo` binary committed to deepseek-harness

- Good: no toolchain in the harness, and the real process runs.
- Bad: a platform matrix of binaries (Linux/macOS/Windows, x64/arm64), binary
  size in git history, and no provenance story for what produced each artifact.

### (c) A Node fixture plugin replaying the shared corpus

- Good: no toolchain, deterministic replay, and the fixture's fidelity is a
  checked fact because it and the Haskell suite consume the same bytes.
- Bad: the harness's snapshot does not run the real Haskell process, so this
  repository's CI is the only place a Haskell-only regression is caught.

## More Information

- `deepseek-harness/docs/testing.md` — the keyless-snapshot requirement and the
  "prefer the real implementation over a mock" rule this ADR takes an exception
  to.
- `deepseek-harness/.agents/notes/implemented/testing/2026-06-19-real-api-e2e-ci.md`
  — how the harness runs keyed real-API e2e.
- `deepseek-harness/.github/workflows/ci.yml:301` — the `python-runtime`
  precedent for a language-specific required job.

Revisit trigger: if deepseek-harness ever gains a GHC job for another reason,
option (a) supersedes this decision, and this ADR is superseded by a new one
rather than edited.
