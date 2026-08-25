---
gsd_state_version: 1.0
milestone: v1.0
milestone_name: milestone
status: executing
stopped_at: Completed 01-05-PLAN.md
last_updated: "2026-08-25T21:08:38.000Z"
last_activity: "2026-08-25 — Plan 01-05 complete: ci green on both remotes for 242ebfa, TOOL-02 proven end to end"
progress:
  total_phases: 10
  completed_phases: 0
  total_plans: 5
  completed_plans: 5
  percent: 100
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-08-25)

**Core value:** A model running in a headless `dsh` profile can call a tool implemented in Haskell, and a Haskell guard can veto a tool call — with the whole exchange reproducible in a keyless snapshot.
**Current focus:** Phase 1 — Protocol Freeze and Toolchain Foundation

## Current Position

Phase: 1 of 10 (Protocol Freeze and Toolchain Foundation)
Plan: 5 of 5 in current phase
Status: All plans complete — awaiting phase verification
Last activity: 2026-08-25 — Plan 01-05 complete: ci green on both remotes for 242ebfa, TOOL-02 proven end to end

Progress: [██████████] 100%

## Performance Metrics

**Velocity:**
- Total plans completed: 5
- Average duration: —
- Total execution time: 0.0 hours

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| - | - | - | - |

**Recent Trend:**
- Last 5 plans: —
- Trend: —

*Updated after each plan completion*
| Phase 01 P01 | 3 | 2 tasks | 15 files |
| Phase 01 P03 | 3min | 3 tasks | 6 files |
| Phase 01-protocol-freeze-and-toolchain-foundation P02 | 5min | 3 tasks | 56 files |
| Phase 01-protocol-freeze-and-toolchain-foundation P04 | 4min | 3 tasks | 5 files |
| Phase 01-protocol-freeze-and-toolchain-foundation P05 | 15min | 3 tasks | 3 files |

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- [Research]: Own the JSON-RPC envelope; `json-rpc` (unframed output, heavy closure) and `jsonrpc` (MPL-2.0, single vendor) both rejected with reasons recorded.
- [Research]: Own `DshSchema` restricted to the harness's enforced subset; `autodocodec-schema` is not used for derivation.
- [Research]: Guard is `Allow | Deny | Ask` (no rewrite); sections are static; `render` runs plugin-side at execute time and ships its blocks in the result.
- [Research]: Repin `lts-22.43` → `lts-24.56` (GHC 9.10.3) — the old pin emits `integer` args as `number`.
- [Roadmap]: Phase 1 is the whole roadmap's leverage point; the frozen spec plus corpus makes the Haskell stream (2-7) and bridge stream (8-9) independent until Phase 10.
- [Phase 01]: Toolchain pinned to lts-24.56 (GHC 9.10.3); no extra-deps needed, the tasty + hedgehog set resolves inside the snapshot
- [Phase 01]: -Werror lives in CI (stack build --pedantic), never in package.yaml, so a new GHC minor cannot make a clean clone unbuildable
- [Phase 01]: hpack is the source of truth; the .cabal and stack.yaml.lock are committed generated artifacts, verified drift-free after every build
- [Phase 01]: src/ holds stub modules with Haddock and empty export lists, never stub types
- [Phase 1 / ADR 0001]: E2E-03 resolved — deepseek-harness CI runs a Node fixture plugin replaying corpus/plugin.jsonl; this repo owns the real-binary tiers (E2E-01 keyless, E2E-02 keyed). Recorded at docs/adr/0001-harness-e2e-tiering.md for the Phase 10 bridge PR to cite.
- [Phase 1 / CI]: Every pinned GitHub Action must declare node24 (GitHub drops Node 20 from runners 2026-09-16) — hence hlint from its release tarball instead of hlint-setup/hlint-run, and actions/cache@v5 rather than @v4.
- [Phase 1 / CI]: hlint and fourmolu are advisory until Phase 7 removes continue-on-error alongside the last corpus EXPECTED.md; the Windows/macOS matrix is deferred to Phase 2 with the transport. Both deferrals are commented in ci.yml.
- [Phase 01]: PROTOCOL.md freezes -32800 as the cancellation code; -32003 CANCELLED is retired and a cancelled in-flight request always gets a reply
- [Phase 01]: An unknown tool/guard/subagent name answers -32002 UNKNOWN_CONTRIBUTION, never -32601; -32601 stays for an unknown method
- [Phase 01]: The host evaluates guard match.tools, so Guard carries matchTools :: [ToolName] and the plugin's per-guard failPolicy is authoritative
- [Phase 01]: Subagent results use output (mirroring SubagentResult); lastAssistantMessage is retired from REQUIREMENTS.md and PROJECT.md
- [Phase 01]: Corpus ids normalize in two passes so a response inherits the requester's direction (h1, never p1)
- [Phase 01]: The known-red manifest is the filesystem — EXPECTED.md presence alone decides expectFailBecause, so there is no parallel list to drift and an unexpected pass fails the suite
- [Phase 01]: The conformance scenario tree is built in IO before defaultMain; withResource cannot change tree shape, so it is reserved for Phase 7's spawned binary
- [Phase 01]: The Hedgehog cancellation state machine targets hedgehog 1.5's barbies FunctorB/TraversableB Command, not the deprecated HTraversable, so Phase 3 replaces the model and not the plumbing
- [Phase 01]: scripts/check-red-visible.sh parses a captured tasty log instead of running stack test, so CI builds and runs the suite once and set -euo pipefail cannot swallow its exit code
- [Phase 01]: The corpus is never wired as a tasty-golden golden; --accept would rewrite the hand-authored spec. Goldens start at Phase 5's --dump-manifest output
- [Phase 01]: TOOL-02's signal is two runs, not one workflow file — ci concluded success on 242ebfa on both origin (fork) and upstream (parent); a green parent says nothing about the fork
- [Phase 01]: Actions permissions are readable with an ordinary token, so "are Actions on?" is automated even though turning them on is not; both repos reported {enabled:true, allowed_actions:all} and task 2 was a no-op confirmation
- [Phase 01]: hlint and fourmolu are already clean on the runner (No hints; --mode check --check-idempotence exits 0), so Phase 7's flip to blocking is a two-line continue-on-error deletion with no reformat debt

### Pending Todos

[From .planning/todos/pending/ — ideas captured during sessions]

None yet.

### Blockers/Concerns

- [Phase 1]: RESOLVED (plan 01-02) — `PROTOCOL.md` picks `-32800 REQUEST_CANCELLED`; `-32003` is retired and appears nowhere in `corpus/` or `PROTOCOL.md`.
- [Phase 1]: RESOLVED (plan 01-03) — deepseek-harness CI has no GHC, and the e2e tiering (E2E-03) is now settled in `docs/adr/0001-harness-e2e-tiering.md`: harness CI runs the Node corpus fixture; this repo owns E2E-01 and E2E-02. Residual risk: a Haskell-only regression is caught here, not in harness CI.
- [Phase 10]: Cross-repo by construction — this repo cannot merge the bridge/e2e work alone; it lands under deepseek-harness's own gates (per-file 100% coverage, doc-sync, Agent Note, keyless snapshot).
- [Phase 4]: The mechanism for mechanically agreeing Haskell-derived schemas with the harness's `assertSupportedJsonSchema` has a known field-set-only gap in the closest prior art; flagged for research during planning.
- [Phase 6/9]: `SubagentProvider.start`'s full return surface and the `presentation` field vocabulary were not fully audited; both need a source read before implementation.
- [Phase 2/10]: Windows behavior (newline mode, process termination, GHC console handling) is untested; the harness runs a Windows CI lane.
- [Phase 1/CI]: Every action in ci.yml is pinned by tag, not by SHA. Both repos currently report sha_pinning_required: false; if an org policy enables SHA pinning on d2p-finance, the workflow stops running with no code change on this side.

## Session Continuity

Last session: 2026-08-25T21:08:38.000Z
Stopped at: Completed 01-05-PLAN.md
Resume file: None
