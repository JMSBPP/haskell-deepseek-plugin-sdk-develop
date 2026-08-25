# Phase 1: Protocol Freeze and Toolchain Foundation - Context

**Gathered:** 2026-08-25
**Status:** Ready for planning

<domain>
## Phase Boundary

Freeze the wire (`PROTOCOL.md`), write the executable conformance corpus that every later phase turns green, repin and restructure the Stack package (`lts-24.56`, library + executable + test-suite), put CI on both remotes, and record the deepseek-harness e2e-tiering decision. No JSON-RPC implementation, no schema derivation, no bridge code — those are Phases 2–10. Requirements: PROTO-01..04, TOOL-01, TOOL-02, E2E-03.

</domain>

<decisions>
## Implementation Decisions

### TDD approach (user-emphasized: tests before anything)
- Corpus-first AND prose: the corpus scenarios are written first as the executable spec; `PROTOCOL.md` prose is written in the same phase and every example in it is a corpus frame (no prose-only examples).
- Corpus form: one directory per scenario, `corpus/<scenario>/host.jsonl` (frames the host sends) and `corpus/<scenario>/plugin.jsonl` (frames the plugin must emit). A tasty test group enumerates the directories at test time — one test per scenario.
- Red state is visible, never hidden: scenarios with no implementation yet are wrapped in `tasty-expected-failure`'s `expectFail`, and each such scenario has `corpus/<scenario>/EXPECTED.md` naming the phase that must flip it. A meta-test asserts every `expectFail` scenario is listed in that manifest; Phase 7 asserts the manifest is empty. No `pending`, no whole-job `continue-on-error` for conformance.
- Property families written up-front as failing/expected-fail signatures in Phase 1, filled in by the owning phase:
  1. Codec round-trips (`decode . encode`) for every envelope and manifest type — Phase 2/5.
  2. Hostile-frame totality: any ByteString line yields a frame or a `-32700` error, never an exception — Phase 2.
  3. Schema subset closure: every generated `DshSchema` passes a Haskell port of the harness's `assertSupportedJsonSchema` — Phase 4.
  4. Cancellation ordering as a Hedgehog state-machine (`Command`/`executeSequential`/`executeParallel`) over request/`$/cancel`/response interleavings: no leaked waiters, late cancels are no-ops — Phase 3.
- Precedent from the Python SDK (`deepseek-harness/python/sdk/tests/test_client.py`): test against a fake peer over real stdio, not mocks; committed expected outputs re-recorded with an explicit flag (`tasty-golden --accept` mirrors `--update-snapshots`); mirror its error taxonomy (`TransportClosedError` / `SdkProtocolError` / `JsonRpcError{code,message,data}`) as Haskell exception types.

### Test stack
- Runner: `tasty`. Libraries: `tasty-hunit`, `tasty-golden`, `tasty-hedgehog`, `tasty-expected-failure`. Properties in `hedgehog` (chosen over QuickCheck for built-in state-machine testing and integrated shrinking).
- Golden comparison is decode-then-compare (aeson key order is not declaration order); byte-exact goldens only where recorded from real output.

### Cancellation semantics (resolves the roadmap blocker)
- After `$/cancel {id}` reaches a running handler, the plugin ALWAYS replies with a JSON-RPC error `-32800` (`RequestCancelled`, LSP's code). The host's waiter resolves on that reply; the `tools/pre-execute` waterfall can therefore never wedge on a cancelled guard.
- A `$/cancel` for an unknown or already-completed id is ignored silently (no error frame).
- `-32003` from ARCHITECTURE.md is retired; the error table in `PROTOCOL.md` supersedes the research draft.

### Method naming and versioning
- Inherit the harness's existing wire style: requests use slashes (`initialize`, `tool/execute`, `guard/decide`, `subagent/run`, `shutdown`), notifications use dots (`section.changed`), and `$/cancel` keeps its LSP spelling.
- `protocolVersion` is an integer starting at `1`; any breaking change bumps it; no negotiation — mismatch fails loud on both sides (PROTO-03) and is a corpus scenario.
- Handshake is host-initiated (`initialize` request → manifest result), per research.
- Distinct id namespaces: host-issued request ids and plugin-issued request ids must never collide (concrete scheme is Claude's discretion; the corpus normalizer makes it invisible to comparisons).

### Corpus home and id normalization
- Corpus lives at this repo's root: `corpus/<scenario>/{host.jsonl,plugin.jsonl,EXPECTED.md?}`. The bridge PR vendors a copy into deepseek-harness with a checksum test so drift fails loud.
- Normalization rule both implementations apply before comparing: every JSON-RPC `id` is rewritten to an ordinal by first appearance per direction (`h1,h2,…` for host-issued, `p1,p2,…` for plugin-issued). Implementations may use any id scheme.
- Required scenarios (from PROTO-02 and roadmap criterion 2): handshake, tool call, tool failure, guard decision (allow / deny / ask), in-flight cancellation, malformed frames (junk line, oversize, non-object params, batch array), shutdown, `protocolVersion` mismatch.

### Maintainer alignment (E2E-03)
- Decide here, no upstream issue: the user maintains both repos. Write `docs/adr/0001-harness-e2e-tiering.md` choosing the Node fixture-plugin snapshot as the sanctioned deepseek-harness CI path, with a real-binary keyed e2e living in this repo; the bridge PR's Agent Note links the ADR.

### CI and package layout
- GitHub Actions on both remotes (`origin` fork and `upstream`): `haskell-actions/setup` with Stack cache; `stack build` + `stack test` blocking; `hlint` and `fourmolu` run with `continue-on-error` until Phase 7 flips them to required together with emptying the expectFail manifest.
- hpack `package.yaml` is the source; the generated `.cabal` is committed for cabal users. Stanzas: library `dsh-plugin`, executable(s) with `-threaded -rtsopts "-with-rtsopts=-N"`, test-suite `conformance`. Language `GHC2024`, `-Wall`.
- Repin `stack.yaml` to `lts-24.56` (GHC 9.10.3), replacing the scaffold's `lts-22.43`.

### Claude's Discretion
- Exact id scheme per namespace, error-code table beyond `-32700/-32600/-32601/-32602/-32603/-32800/-32004`, JSONL field ordering, module/directory layout under `src/`, and the wording of the large-integer policy (must forbid integers outside the JS safe range per SCHEMA-05).

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Project planning
- `.planning/PROJECT.md` — scope, corrections applied from research, constraints
- `.planning/REQUIREMENTS.md` — PROTO-01..04, TOOL-01/02, E2E-03 acceptance text
- `.planning/research/SUMMARY.md` — "Corrections to PROJECT.md"; phase rationale
- `.planning/research/ARCHITECTURE.md` — wire-protocol draft (methods, manifest, sequences); its `-32003` cancellation entry is superseded by this context
- `.planning/research/STACK.md` — resolver verification, ready-to-paste `stack.yaml`/package stanzas, aeson key-order golden caveat
- `.planning/research/PITFALLS.md` — stdout hygiene, CI-has-no-GHC, hostile input, lossless JSON

### Harness wire conventions (external repo: `/home/jmsbpp/ai-agents/deepseek-harness`)
- `packages/sdk/protocol/src/types.ts` — existing request (slash) / notification (dot) naming; NDJSON stdio framing
- `packages/sdk/protocol/src/transport.ts` — `params` object-only rule, batch arrays dropped, `JSON.stringify(msg)+'\n'`
- `packages/core/tools/src/index.ts` — `ToolDefinition`, `PreToolDecision = allow|deny|ask`, mandatory output schema
- `packages/core/tools/src/json-schema.ts` — the supported JSON-Schema subset the manifest must respect
- `packages/llm/llm/src/types.ts` — `ContentBlock` union the corpus results must mirror
- `packages/code-runtime/code-runtime-python/README.md` — hostile-frame and lossless-JSON stance to copy into `PROTOCOL.md`
- `python/sdk/tests/test_client.py` — fake-peer test pattern; `python/development.md` §snapshots — record/diff discipline
- `docs/testing.md` — snapshot/e2e policy the ADR must respect

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- This repo: only the `stack new simple` scaffold (`src/Main.hs`, raw `.cabal`, `lts-22.43`) — to be replaced, nothing to reuse.
- deepseek-harness Python SDK: fake-runtime test script and snapshot directories are the pattern to mirror, not code to import.

### Established Patterns
- Harness wire: NDJSON, object-only params, no batches, slash requests / dot notifications, hostile validation at process boundaries, pre-1.0 fail-loud versioning.

### Integration Points
- `corpus/` is consumed by both this repo's `conformance` test-suite (Phase 2+) and the deepseek-harness bridge tests (Phase 8+, vendored copy + checksum).
- `docs/adr/0001-harness-e2e-tiering.md` is linked from the bridge PR's Agent Note (Phase 10).

</code_context>

<specifics>
## Specific Ideas

- "This is heavy user discussion and we write tests before anything" — the corpus and property signatures land before any prose or implementation.
- Look to the Python SDK for how a non-TypeScript peer is tested and pinned; reuse its discipline and error vocabulary.
- Red must be visible: expected failures are named per scenario with the phase that owns flipping them.

</specifics>

<deferred>
## Deferred Ideas

- TS-side test discipline for the bridge (coverage, corpus vendoring test) — Phase 8.
- Mutation testing of the Haskell suite — backlog.
- Corpus timing/race expressiveness beyond ordering (a DSL) — revisit only if Phase 3's Hedgehog model proves insufficient.

</deferred>

---

*Phase: 01-protocol-freeze-and-toolchain-foundation*
*Context gathered: 2026-08-25*
