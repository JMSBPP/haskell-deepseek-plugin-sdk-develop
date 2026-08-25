# Project Research Summary

**Project:** haskell-deepseek-plugin-sdk
**Domain:** Out-of-process agent-plugin SDK (Haskell) — typed tools, guards, prompt sections, and subagent providers bridged into a Cordis plugin harness (DeepSeek Harness) over newline-delimited JSON-RPC 2.0 on stdio
**Researched:** 2026-08-25
**Confidence:** HIGH for harness-side contracts and Stackage/Hackage facts (read from source and verified live); MEDIUM-HIGH for the not-yet-implemented wire protocol design; MEDIUM for a few external-ecosystem claims

## Executive Summary

This is a two-process, one-wire, three-plane system in the same family as MCP, LSP, and the harness's own SDK protocol — but it is **outbound multi-capability**: one foreign process contributes four different Cordis registration kinds (tools, guards, sections, subagents), where every existing harness out-of-process surface is either inbound-only or single-capability. The decisive constraint discovered by research is that **the harness is not a generic JSON-RPC peer that will accept whatever the wire proposes**: it enforces a closed JSON Schema vocabulary at tool registration, three of its prompt/render callbacks are typed synchronous and cannot round-trip over a wire, and its `PreToolDecision` type has no input-rewrite case. Four of PROJECT.md's Active requirements do not survive contact with the actual harness source and must change before implementation starts (see Corrections below) — this is the single most important output of this research round.

The recommended approach is: freeze a `PROTOCOL.md` + committed conformance-frame corpus before writing any Haskell or TypeScript (Phase 0), repin the Stack resolver from the unsound `lts-22.43` to `lts-24.56`, own a ~150-line JSON-RPC envelope module rather than take a Hackage dependency, own a restricted `DshSchema` ADT targeting exactly the harness's enforced subset rather than routing through `autodocodec-schema`, and resolve the "harness CI has no GHC" tension with deepseek-harness maintainers on paper before any Haskell PR is attempted. Guard `Rewrite` and dynamic `section/render` are structurally impossible against the current harness types (not merely inconvenient) and must be dropped from v1; `initialize` must be host-initiated, not plugin-initiated.

The main risks are process-boundary mismatches that are cheap to fix now and expensive to fix after code exists: the pure-synchronous `render`/`presentCall`/`presentResult` contract (redesigning it later means changing the wire response shape, the manifest format, and every fixture), the threading model in `runPlugin` (retrofitting concurrency changes every handler signature), and the cross-repo CI/coverage/doc-sync gauntlet in deepseek-harness, which is a process risk as large as any technical one. All are addressable by ordering decisions correctly in Phase 0, which every research file converges on independently.

## Key Findings

### Recommended Stack

Repin to Stackage `lts-24.56` (GHC 9.10.3): `lts-22.43` is not even the lts-22 series terminal (`lts-22.44` is), lacks `aeson` 2.2's optional-field support, and — verified empirically by building both resolvers locally — its `autodocodec-schema` 0.1.0.4 renders integer tool arguments as `"type":"number"` (a model-visible correctness bug) where 0.2.0.1 on lts-24.56 correctly emits `"type":"integer"`. GHC 9.6.6 is not installed on the dev machine and Stack would install a third toolchain for no benefit. Own the JSON-RPC envelope (`~150 LOC` over `aeson`+`bytestring`+`stm`) rather than depend on `json-rpc` (emits no newline delimiter, pulls a dormant `stm-conduit` plus `QuickCheck` into the runtime closure, imposes a `ReaderT`/`MonadLoggerIO` stack) or `jsonrpc` (right shape, but MPL-2.0, unreleased to Stackage, single-vendor with negligible adoption). Use `autodocodec` for `ToJSON`/`FromJSON` convenience if desired, but never for schema *derivation* — see Corrections.

**Core technologies:**
- GHC 9.10.3 via `lts-24.56` — current open LTS series, already installed locally, unlocks `GHC2024`
- `aeson` 2.2.5.0 — all JSON; 2.2's `omitField`/`.?=` make optional JSON-RPC members first-class
- `stm` + `async` — cancellation flags, correlation registry, one-async-per-request dispatch (`Exec.cancelled :: STM Bool`)
- Owned `DeepSeek.Plugin.Wire`/`Rpc.Frame` — the JSON-RPC envelope, not a Hackage dependency
- Owned `DshSchema` ADT + `HasSchema` — targets the harness's enforced JSON Schema subset exactly; `autodocodec-schema` is rejected for this specific purpose (see Corrections)
- `hspec` + `hspec-golden` + `QuickCheck` — wire-frame goldens and codec round-trip properties
- `ctx.subprocess` (harness side) — spawn, not `node:child_process`; gives tree-scoped SIGTERM→grace→SIGKILL and scrubbed env for free

### Expected Features

Four prior-art families (MCP, Claude Code/Codex hooks, LSP, the harness's own in-process seams) converge on a clear table-stakes/differentiator/anti-feature split. The harness's own registered types are the binding constraint — an SDK feature the wire can express but the host cannot register is a lying contract.

**Must have (table stakes):**
- NDJSON JSON-RPC 2.0 envelope, stdout reserved for frames (logs to stderr)
- `initialize` handshake declaring `protocolVersion` + contributions, failing loud with the supported-version list on mismatch
- Mandatory tool output schema + pure `render` (stricter than MCP, which makes `outputSchema` optional)
- Harness JSON Schema subset conformance, checked inside the SDK before registration
- Two-tier error taxonomy: protocol error (JSON-RPC `error`) vs. tool execution error (`isError` result the model can read and recover from)
- `$/cancel` with correct race semantics (no response for a cancelled id, ignore unknown/late ids)
- `Guard` returning `Allow | Deny Text | Ask Text` on the async `tools/pre-execute` waterfall (never the synchronous `ctx.tools.guard()`)
- `--dump-manifest` for keyless CI without GHC — near-free, highest value-to-cost feature in the whole list
- Golden wire-frame tests + QuickCheck codec round-trips + an in-process fake host

**Should have (competitive):**
- Deterministic manifest ordering (KV-cache prefix stability)
- `STM`-based cancellation exposed to authors (`Exec.cancelled`, `Exec.awaitCancel`) — composes better than AbortSignal/Context idioms in peer SDKs
- In-process fake host / test harness (`InMemoryTransport`-equivalent) — makes the whole SDK testable without `dsh` or an API key
- Per-tool `timeoutMs`, only constructible alongside a cancellation-aware handler

**Defer (v2+):**
- Guard `Rewrite` — the harness's `PreToolDecision` has no rewrite case by design; blocked on a harness-side design note, not on this SDK
- Dynamic `section/render` — `PromptSection.text` is synchronous; would also break KV-cache prefix stability
- Progress notifications, plugin→host `agent/inject`, HTTP/WS transports, generic Cordis reflection, live self-modification — all explicitly out of scope or blocked on a host-side consumer that does not exist yet

### Architecture Approach

Three planes per process: an author plane (`Plugin { tools, guards, sections, subagents }`, no IO at definition), an SDK plane (schema → manifest → dispatch → content, with a `Peer` owning all STM state above a `Transport` record-of-functions), and the wire itself (pure frame codec, stdio NDJSON implementation). The TypeScript bridge mirrors `packages/mcp/mcp-client` for its generation-supervisor lifecycle (two-phase swap: build the whole next generation before touching the registry, then register tools+guards+sections+subagents as one rollback unit) and `packages/hooks/hooks-claude-code` for the guard-to-waterfall translation.

**Major components:**
1. `Rpc/{Frame,Transport,Peer}` (Haskell) — pure codec, pluggable transport, sole STM owner; the async-per-request router must exist before cancellation can be built (not retrofittable)
2. `Schema` + `Schema/Validate` (Haskell) — owned `DshSchema` ADT restricted to the harness's enforced subset, with a validator mirroring the harness's own `validateJsonSchemaValue`
3. `Types`/`Dispatch`/`Run` (Haskell) — `Plugin` as a record of existentials, `runPlugin` owning fd hygiene, buffering, EOF/SIGPIPE shutdown
4. `remote-plugin-protocol` + `remote-plugin` (TypeScript, deepseek-harness) — zero-Cordis wire types/transport/manifest-validation package, then the Cordis plugin proper (connection supervisor, tools.ts, guards.ts, sections.ts, subagents.ts)
5. `PROTOCOL.md` + a committed `conformance/` frame corpus, vendored into both repos — the single highest-leverage structural decision, since it makes the two implementations independently testable and lets P1–P5 (Haskell) and P6–P8 (bridge) proceed as fully parallel work streams that meet only at the e2e phase

### Critical Pitfalls

1. **stdout is the wire, and GHC will quietly break it via block buffering under a pipe** — fix structurally with `hDuplicateTo stderr stdout` in `runPlugin` (four lines) so any stray `putStrLn`, including from a dependency, cannot corrupt frames; the harness's own transport silently drops unparseable lines with no timeout, so this fails as a permanent hang, not an exception.
2. **`render`/`presentCall`/`presentResult` are pure, synchronous, and replay-safe on the harness side — they cannot cross a process boundary.** This must be resolved as a named protocol decision in Phase 0 (recommended: render eagerly, ship content with the `tool/execute` result; omit `presentCall`/`presentResult` in v1 and document under Known Limitations), not discovered mid-implementation, because getting it wrong means redesigning the wire response shape after later phases are already built.
3. **No request timeout + a waterfall that never calls `next()` on the `Allow` path = a permanently wedged agent turn.** Every remote call needs a deadline and a defined fallback *decision* (fail-closed for guards, fail-open for sections); `next()` must be reached from a `finally`.
4. **Unbounded frame accumulation and JSON number precision loss are both live risks with a model-influenced peer**, not a hypothetical: `Scientific`/`Integer` in Haskell vs. IEEE-754 doubles in JS silently round large ids/timestamps, and the harness's own `code-runtime-python` sibling built dedicated machinery for exactly this; decide the wire's number policy (recommended: integers outside `±2^53` cross as strings) in Phase 0.
5. **The deepseek-harness contribution gauntlet — specifically, the keyless-snapshot requirement needs a real runnable composition, but harness CI has no GHC anywhere.** This is a process risk, not a code risk, and if discovered at PR time it blocks the whole e2e phase pending a maintainer decision that may take weeks. Resolve with an explicit alignment conversation before Phase 1 starts.

## Corrections to PROJECT.md

Research surfaced five places where PROJECT.md's Active requirements or Constraints do not survive contact with the actual deepseek-harness source, Stackage/Hackage facts, or the harness's CI configuration. These are not stylistic preferences — each is backed by a read of the relevant source or a live empirical check — and should be applied before requirements/roadmap work proceeds.

| # | Current PROJECT.md statement | Finding | Recommended replacement | Confidence |
|---|---|---|---|---|
| 1 | `Guard` sum is `Allow \| Deny Text \| Rewrite Value` | The harness's `PreToolDecision` type (`packages/core/tools/src/index.ts`) has exactly `allow \| deny \| ask` and its own JSDoc states input rewriting is *excluded because arguments are already logged and presented*; `dsh-hook-protocol` confirms an analogous `updatedInput` is parsed but never honored. Shipping `Rewrite` on the wire means every Haskell guard author writes a case that silently does nothing. | Drop `Rewrite` from v1. Add `Ask Text`, which the seam *does* support and PROJECT.md currently omits. Guards that need to change behavior use `Deny` with an actionable, model-readable reason (MCP's documented recovery path). Revisit `Rewrite` only after the harness's own `.agents/notes/proposed/feature/2026-06-30-pre-tool-input-rewrite.md` lands. | HIGH |
| 2 | `section/render` is listed as a harness→plugin request method the plugin must handle | `PromptSection.text` (`packages/core/system-prompt/src/index.ts`) is typed `string \| ((context) => string)` — synchronous. No `await` is possible inside it, so a JSON-RPC round trip cannot be performed there at all, independent of cost. Even routed through the async `system-prompt/assemble` waterfall instead, a dynamic section puts an IPC round trip on the critical path of every model step and destroys KV-cache prefix stability. | Drop `section/render` from v1 entirely. `Section` contributes **static** text declared once in the handshake manifest, registered via `ctx.systemPrompt.section({ name, order, text })` with zero per-assembly IPC. A `section/changed { name, text }` plugin→host push notification (not a request) lets the bridge dispose-and-re-register on genuine change. Defer any truly dynamic section design to v1.1, routed through the async `system-prompt/assemble` waterfall, with its per-step latency cost documented. | HIGH |
| 3 | `render :: a -> v -> [ContentBlock]` is listed alongside an implication that render "crosses the process boundary" for host-side projection | `ToolOutputDefinition.render` on the harness side is required to be **pure, synchronous, and replay-safe** — a UI may call it during live streaming *and* during session-log replay, when the Haskell plugin process is not running and may not even be installed. The bridge structurally cannot call a remote `render` at projection time. | Keep the Haskell `render :: a -> v -> [ContentBlock]` signature, but it runs **in the plugin process at `tool/execute` time**, and its output (`content: [ContentBlock]`) rides back in the same response alongside the canonical `value`. The bridge's `ToolDefinition.output.render` becomes a pure, local, synchronous lookup into that already-received envelope — never a remote call. `presentCall`/`presentResult` (separate pure/sync UI-intent methods) should be omitted from v1 and documented under Known Limitations, or expressed later as a declarative `presentation` field in the manifest, never as a live round trip. | HIGH |
| 4 | Constraint: "Tech stack ... resolver pinned (`lts-22.43`)" | `lts-22.43` is not even the terminal patch of the lts-22 series (`lts-22.44` is — `stackage.org/lts-22` redirects there). It ships `aeson` 2.1.2.1 (no `omitField`/`.?=`), `autodocodec-schema` 0.1.0.4, and no GHC2024. Built empirically on this machine 2026-08-25: `autodocodec-schema` on `lts-22.43` renders `Int` as `{"type":"number"}` — a model-visible schema correctness bug — while the same expression on `lts-24.56` correctly renders `{"type":"integer"}`. GHC 9.6.x is also not installed locally (9.10.3 and 9.8.4 are), so building on the current pin forces an unnecessary third-toolchain install. | Repin to `lts-24.56` (GHC 9.10.3), the current open LTS series. Fallback: `lts-23.28` (GHC 9.8.4) only if a survey of target plugin authors shows GHC 9.10 adoption is a real barrier — never `lts-22.43`; if GHC 9.6 is required for another reason, the floor is `lts-22.44`. Record the review date and re-derive the pin in the roadmap's Phase 0. | HIGH |
| 5 | Constraint: "Use a Hackage JSON-RPC package if maintained, else own aeson module" (i.e., evaluate `jsonrpc`/`json-rpc` first) | `json-rpc` (maintained, 35 stars) emits no newline delimiter in its encoder (`encodeConduit`, verified in source), pulls a dormant `stm-conduit` (last upload 2018) plus `QuickCheck` into every plugin author's runtime closure, and imposes a `ReaderT Session` + `MonadLoggerIO`/`MonadUnliftIO` stack incompatible with PROJECT.md's own `runPlugin :: Plugin -> IO ()` / `execute :: a -> Exec -> IO v` surface. `jsonrpc` (right shape, ~500 LOC) is MPL-2.0 (a compliance obligation for a BSD-3 library third parties statically link), not in any Stackage snapshot, and has negligible independent adoption (2 stars, 30 downloads, single vendor). Neither clears the harness's own "prefer maintained dependencies... when they genuinely delete owned code and tests" bar, because after taking either you still own the framing wrapper, the cancel-token registry, and the hostile-input rebuild. | Own `DeepSeek.Plugin.Wire`/`Rpc.Frame` (~150–250 LOC over `aeson`+`bytestring`+`stm`), using `jsonrpc-0.2.0.0`'s type layout as a reference only, not a dependency. Widen the stated escape hatch from "only if none is maintained" to "if none is suitable" and record the rejection with its reasons in the Key Decisions table so it is not relitigated. Revisit only if `jsonrpc` reaches 1.0, enters a Stackage LTS, gains reverse dependencies outside its single vendor, and MPL-2.0 propagation is judged acceptable. | HIGH |
| 6 | Requirement: keyless snapshot recording a model calling the Haskell tool, implied to run in deepseek-harness CI as a single artifact | `deepseek-harness` CI (`.github/workflows/*.yml`) sets up Node and Python only — no GHC, no Stack, verified by exhaustive grep. The harness's own testing policy requires the keyless snapshot go through "a runnable example's owning snapshot suite," which for this project means spawning a real peer binary — something harness CI structurally cannot do today without a maintainer decision to add a GHC job (a real but not-yet-requested cost). | Split the single e2e requirement into two tiers: (a) harness-repo CI runs the keyless snapshot against a small TypeScript fixture plugin that replays the same committed `conformance/` frame corpus, proving the bridge with no GHC; (b) the Haskell repo runs a real `dsh` against the real `examples/echo` binary in its own CI, proving the binary, with GHC available there. File an alignment issue with deepseek-harness maintainers in Phase 0 — before Phase 1 starts — covering the snapshot-peer strategy and whether a GHC CI job is ever wanted; treat their answer as a blocking prerequisite, not a late-phase task. | MEDIUM |

Additionally, `initialize` should be corrected from plugin→harness to **host-initiated** (host sends `initialize` with `protocolVersion`/`hostInfo`/`cwd`; the manifest is the result), matching MCP, LSP, ACP, and the harness's own SDK protocol, and giving the supervisor a clean activation timeout. `--dump-manifest` is unaffected — it still prints exactly the same `result` payload the host would have received. Confidence: MEDIUM.

Also flag for the requirements step: "evaluate `jsonrpc`/`json-rpc` first" in the Active requirements list (item 19) should be replaced by correction #5 above rather than left as an open evaluation, since the evaluation is now complete with a definitive answer.

## Implications for Roadmap

Based on combined research, the natural phase spine is forced by two independent dependency chains that meet at end-to-end validation — plus a Phase 0 that every research file converges on independently as a hard prerequisite.

### Phase 0: Protocol spec, corpus, and toolchain decisions
**Rationale:** PITFALLS.md, ARCHITECTURE.md, and STACK.md all independently place the same set of decisions before any code: the wire's number policy, the render/section resolution (Corrections #2, #3), the resolver pin (Correction #4), the JSON-RPC dependency call (Correction #5), and — highest-risk of all — an explicit alignment conversation with deepseek-harness maintainers about the GHC-less CI tension (Correction #6). None of these are retrofittable; getting any of them wrong after Phase 1–5 exist means redesigning the wire response shape or rewriting the threading model.
**Delivers:** `PROTOCOL.md`, a committed `conformance/` frame corpus (empty scaffold, filled incrementally), `stack.yaml` pinned to `lts-24.56`, the Key Decisions table in PROJECT.md updated with Corrections #1–#6, and a filed alignment issue/discussion with deepseek-harness maintainers.
**Addresses:** none of FEATURES.md's MVP list directly — this is the leverage point that makes every later phase's features buildable without rework.
**Avoids:** Pitfalls 3, 6, 7, 14, 15 (pure-render-across-the-wire, number precision, id collisions, unsound resolver pin, no-GHC-in-CI) — all rated HIGH or MEDIUM-HIGH recovery cost if deferred.

### Phase 1: Wire transport and framing (Haskell)
**Rationale:** Everything in the SDK depends on `Rpc/{Frame,Transport,Peer}`; the STM correlation registry and the async-per-request router cannot be added after a synchronous handler loop exists without a rewrite (Anti-Pattern 2). This is also where the two highest-frequency stdio bugs (block buffering, locale-dependent encoding) must be closed structurally, not by convention.
**Delivers:** Pure frame codec with QuickCheck round-trip tests, a `Transport` record-of-functions with an in-memory implementation (enabling the fake-host test harness early) and a stdio NDJSON implementation, `runPlugin`'s fd-hygiene guard (`hDuplicateTo stderr stdout`), EOF/SIGPIPE-safe shutdown.
**Uses:** `aeson`, `bytestring`, `stm`, `async`, `-threaded -rtsopts "-with-rtsopts=-N"` from the first commit.
**Implements:** Pattern 2 (Transport/Peer split), Pattern 3 (async-per-request router), Pattern 9 (fd hygiene).

### Phase 2: Schema derivation
**Rationale:** Fully parallel with Phase 1 (no shared module, per ARCHITECTURE.md's build-order graph), but must land before the manifest can be projected. The corrected approach (own `DshSchema`, not `autodocodec-schema`) is a structural decision that a Generic-derivation retrofit cannot cheaply undo.
**Delivers:** `DshSchema` ADT with smart constructors that make an unsupported schema (recursive types, `Map`, refinement keywords) unrepresentable; `HasSchema` class with a restricted `Generic` default; the hostile-input validator mirroring the harness's own `validateJsonSchemaValue`.
**Addresses:** FEATURES.md's "Harness JSON Schema subset conformance, checked in the SDK" (P1 priority) and "`HasSchema` with a Generic default, targeting the harness subset" (the core DX bet).
**Avoids:** Pitfall 11 (schema drift) and Anti-Pattern 3 (shipping `autodocodec-schema` output as `output.schema`).

### Phase 3: Plugin types, manifest, dispatch, and the tool seam
**Rationale:** `Tool`'s existential needs the `HasSchema` dictionary in scope (depends on Phase 2); the manifest cannot be projected without it; dispatch needs the Phase 1 router. Tool execution plus cancellation is the smallest complete vertical slice that proves the whole SDK design, per ARCHITECTURE's build-order graph (P3→P4→P5).
**Delivers:** `Plugin`/`Tool`/`ContentBlock` types, `runPlugin`/`--dump-manifest`, `tool/execute` end-to-end including the two-tier error taxonomy, `$/cancel` with full race semantics, `examples/echo`, and the in-process fake host driving a conformance test suite against the Phase 0 corpus.
**Addresses:** the bulk of FEATURES.md's P1 MVP list.
**Avoids:** Pitfall 5 (no-timeout wedge — for the tool seam specifically), Pitfall 8 (cancellation races), Pitfall 4 (unbounded frames).

### Phase 4: TypeScript bridge — protocol package and spawn/tools
**Rationale:** Fully parallel with Phases 1–3 (only depends on the Phase 0 corpus); its fake-plugin fixture is a small Node script replaying `conformance/*/plugin.jsonl`, so this phase needs no GHC. Tools are the smallest end-to-end bridged contribution and prove the generation-supervisor lifecycle once for reuse by guards/sections/subagents.
**Delivers:** `remote-plugin-protocol` (wire types, NDJSON transport, hostile manifest validation, no Cordis import) and `remote-plugin`'s connection supervisor + `tools.ts`, spawning through `ctx.subprocess`.
**Uses:** the `mcp-client` supervisor pattern (generations, two-phase swap, bounded restart budget) as a template to follow closely, not reinvent.
**Implements:** Pattern 7 (generation supervisor) and Pattern 8 (`ctx.subprocess`, not `node:child_process`).

### Phase 5: Guard, section, subagent seams (bridge + Haskell in lockstep)
**Rationale:** Each adds one registration kind to the Phase 4 rollback unit; guards first (highest value, hardest semantics — the `next()`-delegation and fail-closed-on-peer-death rules), sections second (now trivial given Correction #2 removed the dynamic case), subagents last (largest surface, advertises no capabilities in v1 to match the shipped `subagent-dsh-sdk` precedent).
**Delivers:** `tools/pre-execute` guard translation with `Allow ⇒ next()` never `{kind:'allow'}`; static-manifest sections; a subagent provider honestly advertising no capabilities.
**Addresses:** the remaining FEATURES.md P1/P2 items (Guard, Static Section, Subagent provider).
**Avoids:** Anti-Pattern 1 (returning `{kind:'allow'}` and silently disabling downstream listeners), Anti-Pattern 5 (guard fails open on peer death), Pitfall 13 (remote prompt sections breaking KV-cache/replay — moot after Correction #2, but the section seam must still be built correctly).

### Phase 6: End-to-end validation and the harness contribution gauntlet
**Rationale:** Cross-repo by construction (PROJECT.md already flags this); depends on both Phase 3 (Haskell provably done) and Phase 5 (bridge complete). This is also where the Phase 0 alignment decision (Correction #6) gets executed, and where deepseek-harness's ~25 doc-sync verifiers, per-file 100% coverage gate, and Agent Note requirement apply.
**Delivers:** The keyless snapshot(s) per the Phase 0 tiering decision, the bridge package's gated README sections, `invariant.ts`, coverage at the harness's required threshold.
**Addresses:** PROJECT.md's stated Core Value.
**Avoids:** Pitfall 15 (contribution gauntlet discovered too late) and Pitfall 12 (HMR orphans/duplicate registrations) via the HMR-safety test.

### Phase Ordering Rationale

- P0 is the whole roadmap's leverage point: a frozen wire spec plus a committed frame corpus makes the Haskell stream (P1→P3) and the TypeScript stream (P4→P5) fully independent, meeting only at P6. Writing the spec after starting either implementation serializes nearly everything (ARCHITECTURE.md, "The critical parallelism").
- The async-per-request router (P1) must exist before cancellation (also P1) can be built — retrofitting it means rewriting the read loop (Anti-Pattern 2, Pitfall 5).
- Schema derivation (P2) is fully parallel with wire transport (P1) — no shared module — but both must land before the manifest/tool seam (P3), which needs both dictionaries in scope.
- The bridge (P4–P5) needs only the P0 corpus, not a working Haskell binary, so it can start immediately and finish independently — this is the main schedule risk mitigation the research surfaces.
- Guards land before sections/subagents within P5 because they carry the hardest semantics (fail-closed default, `next()` delegation) and the highest security cost if wrong; sections are now the easy case after Correction #2 made them static-only.

### Research Flags

Phases likely needing deeper research (`/gsd:research-phase`) during planning:
- **Phase 0:** the deepseek-harness maintainer alignment conversation (Correction #6) is a negotiation, not a technical spec — its outcome could reshape the P6 tiering plan.
- **Phase 2:** the exact cross-language schema-agreement mechanism (comparing Haskell-derived schemas against the harness's `assertSupportedJsonSchema` mechanically) has an acknowledged "field-set-only, not field-type" gap in the closest prior art (`code-runtime-python`'s mirror test) that needs a design decision.
- **Phase 5 (subagent sub-seam specifically):** ARCHITECTURE.md flags `SubagentProvider.start`'s full surface as not fully audited, and the `presentation` manifest field's exact vocabulary needs a dedicated read of `packages/core/tools/src/presentation.ts` before implementation.

Phases with standard, well-documented patterns (skip research-phase):
- **Phase 1:** stdio framing, fd hygiene, and the transport-record pattern are directly modeled on verified precedent (`mcp-client`, `hooks-claude-code`, the harness's own SDK protocol) with concrete code sketches already in ARCHITECTURE.md.
- **Phase 4:** the generation-supervisor lifecycle has a shipped template (`packages/mcp/mcp-client/src/connection.ts`) to follow closely rather than design from scratch.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Versions verified live against Stackage/Hackage on 2026-08-25; the resolver and schema-regression claims were empirically built and tested locally, not inferred from training data |
| Features | HIGH for harness-side contracts (read from source of truth); MEDIUM for LSP dynamic-registration details and one Codex-hooks claim (single secondary source, not load-bearing since Codex parity is not a goal) |
| Architecture | HIGH for harness-side constraints (read from `deepseek-harness` source at `b150a551b8`); MEDIUM-HIGH for Haskell library selection; MEDIUM for the wire-protocol specifics, since no such bridge exists yet to verify against — expect the conformance corpus to shift during Phase 1/4 |
| Pitfalls | HIGH for harness-side claims (read from source); MEDIUM-HIGH for GHC/Stack/RTS claims (official docs, GHC RTS source, one SIGPIPE claim resting on a 2010 mailing-list thread); MEDIUM for the two "no prior art" claims (no generic remote-plugin protocol exists yet; no GHC job exists in harness CI) — both verified by exhaustive search, but absence is harder to prove than presence |

**Overall confidence:** HIGH. The four research files converge independently on the same six corrections (cross-validated by ARCHITECTURE.md's own "Corrections This Research Suggests to PROJECT.md" table, STACK.md's empirical resolver/schema check, and PITFALLS.md's CI grep), which is a strong signal these are real findings rather than an artifact of one researcher's framing.

### Gaps to Address

- **Deepseek-harness CI's actual GHC availability** rests on an exhaustive grep of `.github/workflows/`; a self-hosted runner image could in principle carry an undeclared toolchain. Confirm with a maintainer in Phase 0 rather than assuming the grep is exhaustive in practice.
- **Whose JSON Schema dialect the bridge ultimately forwards to DeepSeek's function-calling API** (whether `$defs`/`$ref` survive, though the harness's own subset already excludes them) is unverified against a real request trace — settle with a real trace during the bridge phase, not by assumption.
- **The exact GHC SIGPIPE disposition** should be re-verified against the actually-pinned GHC version with a two-line program rather than trusted from a 2010 mailing-list thread.
- **Windows behavior** of the whole stack (newline mode, process termination, GHC console handling) is untested in this research round; the harness runs a Windows CI lane, so plan for it explicitly in Phase 1/6 rather than discovering it late.
- **`SubagentProvider.start`'s full return surface** was not fully audited; needs its own source read before Phase 5's subagent sub-seam.

## Sources

### Primary (HIGH confidence)
- `~/ai-agents/deepseek-harness` source at commit `b150a551b8` — `packages/core/tools/src/{index,json-schema}.ts`, `packages/core/system-prompt/src/index.ts`, `packages/llm/llm/src/types.ts`, `packages/sdk/protocol/src/transport.ts`, `packages/mcp/mcp-client/src/*`, `packages/hooks/hooks-claude-code/src/index.ts`, `packages/subprocess/subprocess/src/index.ts`, `packages/subagent/subagent*/README.md`, `docs/{architecture,cordis-primer,defensive-patterns,testing}.md`, `packages/AGENTS.md`, `CLAUDE.md`, `.github/workflows/*.yml`
- Stackage snapshot pages and `/cabal.config` for `lts-22.43`, `lts-23.28`, `lts-24.56` — fetched and empirically built 2026-08-25
- Hackage tarballs read directly: `json-rpc-1.0.4`/`1.1.3`, `jsonrpc-0.2.0.0`, `autodocodec-schema-0.1.0.4`/`0.2.0.1`, `mcp-0.3.2.0`, `lsp-types-2.1.1.0`
- Model Context Protocol specification, `2026-07-28` Release Candidate (blog + full spec pages) — fetched live
- Claude Code Hooks Reference (official docs)

### Secondary (MEDIUM confidence)
- LSP Specification 3.17 (dynamic registration details, search summary rather than full spec fetch)
- Codex CLI Hooks Reference (secondary source; not load-bearing for this project)
- GHC RTS SIGPIPE behavior (GHC issue #1619 + a 2010 mailing-list thread, corroborated by `rts/posix/Signals.c` but not restated in the current user's guide)
- MPL-2.0 §3.2 propagation reading for the `jsonrpc` package (plain reading of license text, not legal advice)

### Tertiary (LOW confidence)
- None flagged as load-bearing; the `jsonrpc` package's long-term maintenance trajectory is rated LOW-MEDIUM (single release, single vendor, 2 stars) but does not affect the recommendation since it was rejected regardless.

---
*Research completed: 2026-08-25*
*Ready for roadmap: yes*
