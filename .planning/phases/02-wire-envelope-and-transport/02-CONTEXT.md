# Phase 2: Wire Envelope and Transport - Context

**Gathered:** 2026-08-25
**Status:** Ready for planning

<domain>
## Phase Boundary

Owned JSON-RPC 2.0 envelope types with aeson codecs (`DeepSeek.Plugin.Wire`), a newline-delimited stdio transport behind a `Transport` interface with a bounded hostile reader, an in-memory transport pair, a Haskell fake host that replays `corpus/<scenario>/host.jsonl`, decode-then-compare goldens for every corpus frame, and hedgehog round-trip/totality properties. No router, no request correlation, no cancellation, no handlers, no manifest logic — those are Phases 3–5. Requirements: WIRE-01, WIRE-02, WIRE-03, WIRE-06, WIRE-07.

Reference use case: `JMSBPP/sarmiento-plugins` (a contained-agent plugin: model-authored `tool/execute` args in, dimensionally-typed Kaleckian shock out). Every decision below was weighed against "can one bad model-authored frame kill that session?" and against token cost.

</domain>

<decisions>
## Implementation Decisions

### Reader bounding & recovery
- After emitting an error frame (`-32700` junk line, `-32600` oversize / non-object params / non-scalar id / batch / unsafe integer), the reader **skips the offending line and keeps serving**. Rationale: cost per bad frame is one error tool-result plus one model retry turn; closing wastes the remaining turn and forces a respawn. No "close after N consecutive errors" knob — floods from the model are already rate-limited by its turn loop and are visible on stderr.
- Bytes beyond `maxFrameBytes` on one line are **discarded to the next newline without buffering**; memory is bounded at `maxFrameBytes` regardless of line length. The error frame is `-32600` with `id:null` (PROTOCOL §10).
- Default `maxFrameBytes` = **1 MiB** (1048576), a validated `Config` field; `corpus/<scenario>/SCENARIO.json` `maxFrameBytes` overrides it per scenario. Rationale: any model output frame is ≤ 256 KiB by construction; 1 MiB covers the largest legitimate host-originated frame (`subagent/run` prompts) while rejecting runaway payloads. Result-size discipline (keeping `content` small so the model does not pay for it) is Phase 5's `render` concern, not this bound.
- Every rejected frame writes **one structured line to stderr** plus the error frame on stdout. stdout carries frames only.

### Envelope type design
- **Separate record types plus a `Frame` sum**: `Request {id, method, params}`, `Notification {method, params}`, `Response` = `Ok {id, result :: Value} | Err {id :: Maybe Id, error :: ErrorObject}`; `data Frame = FRequest Request | FNotification Notification | FResponse Response` is what the reader yields. Handlers receive the exact type; the router (Phase 3) matches once.
- `newtype Id = Id (Either Integer Text)` — exactly the scalar set the harness accepts; no `null` on requests. Origin tags (`h*`/`p*`) live only in the corpus normalizer, never in the type.
- `params :: Object` (aeson `Object`) — non-object params unrepresentable, matching the harness rule. `ErrorObject = {code :: Int, message :: Text, data :: Maybe Value}`; `data` stays free-form so tool failures can carry a structured path/reason.
- **Strict parsers are the rebuild**: aeson parsers reject wrong types, non-object params, non-scalar ids, and integers outside ±(2^53−1) with a named error; unknown keys are simply not record fields, so re-encoding the record is the rebuilt frame. No separate allowlist pass. `jsonrpc` must equal `"2.0"` on decode and is emitted on encode.
- Decoding `1e400`-style finite-text-but-non-finite-in-JS numbers and unsafe integers anywhere in a frame yields `-32600` (PROTOCOL §9).

### TDD flip discipline
- Phase 2 removes `EXPECTED.md` from exactly `corpus/malformed-junk-line`, `corpus/malformed-shape`, `corpus/malformed-oversize` and flips the **codec round-trip** and **hostile-frame totality** property families from `expectFail` to real properties. The other 14 scenarios and the schema-closure / cancellation-ordering properties stay `expectFail` with their `EXPECTED.md`.
- The fake host runs all 17 scenarios through the transport; scenarios needing Phase 3+ behavior fail visibly as expected. `scripts/check-red-visible.sh` must keep reporting zero unexpected passes.
- Goldens compare decoded `Frame` values, never bytes (aeson key order is not declaration order). `tasty-golden --accept` must not be wired to `corpus/**`.

### Claude's Discretion
- **Transport interface shape**, under constraints: plain `IO` (`recv :: IO (Maybe Frame)` / `send :: Frame -> IO ()` / `close`), no conduit/streamly dependency, `stm`-friendly so Phase 3's async router sits on top; the in-memory pair exposes captured frames as a pure list (or `TVar [Frame]`) for assertions; EOF signalled as `Nothing`.
- Handle setup (`hSetBinaryMode`, UTF-8 decoding, LF-only framing with CR tolerated-and-stripped or rejected — pick one and pin it in a golden), the exact stderr log line format, `Show`/`Eq`/`Generic` derivations, hand-written vs Generic codecs, module layout inside `DeepSeek.Plugin.Wire` (splitting into `Wire.Types` / `Wire.Transport` is fine).
- Fake host mechanics: how `SCENARIO.json` (`maxFrameBytes`, `deadlineMs` 5000, `quiescenceMs` 250) is read; how it records plugin output for later phases.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Frozen protocol (this repo)
- `PROTOCOL.md` §2 Framing, §3 Envelope Rules, §7 Error Codes, §9 Lossless JSON and Number Policy, §10 Hostile Input, §11 Id Namespaces, §12 Conformance Corpus (pacing contract, `SCENARIO.json`, two-pass id normalization) — the wire this phase implements verbatim
- `corpus/malformed-junk-line/`, `corpus/malformed-shape/`, `corpus/malformed-oversize/` — the scenarios this phase flips; `corpus/handshake/` — canonical frame examples
- `test/Conformance/Corpus.hs`, `test/Conformance/Properties.hs`, `test/Main.hs` — the red suite to turn green; `scripts/check-red-visible.sh` — the invariant to keep
- `src/DeepSeek/Plugin/Wire.hs`, `src/DeepSeek/Plugin/Peer.hs`, `src/DeepSeek/Plugin/Types.hs` — empty stubs to fill (Wire) or leave (Peer is Phase 3)
- `package.yaml` — add only what Phase 2 needs (`aeson`, `bytestring`, `text`, `stm`, `scientific`, `unordered-containers`/`aeson`'s KeyMap; no conduit)

### Prior decisions
- `.planning/phases/01-protocol-freeze-and-toolchain-foundation/01-CONTEXT.md` — TDD approach, tasty+hedgehog, expectFail/EXPECTED.md mechanism, cancellation and naming decisions
- `.planning/REQUIREMENTS.md` WIRE-01/02/03/06/07 (note: WIRE-07 says "QuickCheck"; hedgehog is the locked property library per Phase 1 — amend the wording in the same commit that flips the properties)
- `.planning/research/PITFALLS.md` — stdout hygiene, blocking IO, lossless JSON; `.planning/research/STACK.md` — verified package versions on lts-24.56

### Harness wire conventions (external: `/home/jmsbpp/ai-agents/deepseek-harness`)
- `packages/sdk/protocol/src/transport.ts` — NDJSON framing, `params` object-only, batch arrays dropped, `JSON.stringify(msg)+'\n'`
- `packages/code-runtime/code-runtime-python/README.md` — hostile-frame rebuild stance and lossless-number policy this reader mirrors
- `python/sdk/tests/test_client.py` — fake-peer-over-real-stdio test pattern

### Reference consumer
- `/home/jmsbpp/mamertomics/sarmiento-plugins/README.md` — the first plugin that will import `DeepSeek.Plugin.Wire`; its "no observation, no shock" rule is why error frames must be structured and non-fatal

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `test/Conformance/Corpus.hs`: `listScenarios`, `EXPECTED.md`-driven `expectFailBecause`, the five meta-tests, the `requiredScenarios` list — the replay runner plugs into `replayScenario` there.
- `test/Conformance/Properties.hs`: the four property stubs incl. the hedgehog `Command` skeleton using `barbies` `FunctorB`/`TraversableB` (Phase 3 uses it; Phase 2 fills the first two).
- `scripts/check-red-visible.sh`: parses `conformance.log`; keep its expected-count assertion in sync (after Phase 2: 26 tests, 16 expected failures, 0 unexpected).

### Established Patterns
- hpack `package.yaml` is source; regenerate and commit `.cabal` with every dependency change; `stack build --pedantic` warning-free; hlint/fourmolu clean (advisory in CI until Phase 7).
- GHC2024, `-Wall`, `-threaded` on executables; `GHC2024` requires explicit `-XGHC2024` for hlint/fourmolu.

### Integration Points
- Phase 3 builds the router on `Transport` + `Frame`; Phase 5's `runPlugin` builds the stdio `Transport`; Phase 7's e2e drives the real binary through the fake host; the TS bridge (Phase 8) vendors `corpus/` and must reproduce the same error frames.

</code_context>

<specifics>
## Specific Ideas

- "One bad model-authored frame must not kill the contained agent" — the reader is resilient by design, not strict.
- Token arithmetic drove the bound: ~4 bytes/token; model output ≤ 256 KiB, so 1 MiB is a host-frame bound, not a model bound.
- Error frames are the model's feedback channel (`-32004` with structured `data` in later phases); keep `ErrorObject.data` free-form for that.

</specifics>

<deferred>
## Deferred Ideas

- "Close after N consecutive errors" flood cutoff — rejected for v1; revisit only with evidence of a non-model flood.
- Windows/macOS CI lanes and CRLF behavior — CI matrix deferred from Phase 1; CRLF policy is Claude's discretion here, matrix stays deferred.
- Result-size (`content`) truncation policy — Phase 5.

</deferred>

---

*Phase: 02-wire-envelope-and-transport*
*Context gathered: 2026-08-25*
