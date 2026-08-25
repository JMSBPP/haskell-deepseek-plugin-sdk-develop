# Requirements: haskell-deepseek-plugin-sdk

**Defined:** 2026-08-25
**Core Value:** A model running in a headless `dsh` profile can call a tool implemented in Haskell, and a Haskell guard can veto a tool call — reproducibly, in CI.

## v1 Requirements

### Protocol (PROTO)

- [ ] **PROTO-01**: `PROTOCOL.md` freezes method names, handshake manifest, `protocolVersion`, error codes (incl. `-32004 TOOL_FAILED` vs `-32603`, `-32800 RequestCancelled`), and the rule that `params` is always a JSON object and batches are unsupported
- [ ] **PROTO-02**: A shared conformance corpus (`corpus/host.jsonl`, `corpus/plugin.jsonl`) covers handshake, tool call, guard decision, cancellation, malformed frames, and shutdown; both the Haskell tests and the TS bridge tests replay it
- [ ] **PROTO-03**: Handshake is host-initiated (`initialize` → manifest); a `protocolVersion` mismatch fails loud on both sides with no compatibility shim
- [ ] **PROTO-04**: Manifest declares tools (name, description, args schema, output schema, static presentation intent), guards (matched tool names, timeout policy), static sections, and subagent providers

### Toolchain (TOOL)

- [x] **TOOL-01**: `stack.yaml` pinned to `lts-24.56` (GHC 9.10.3); package restructured to library + executable + test-suite with `GHC2024`, `-Wall`, `-threaded -rtsopts "-with-rtsopts=-N"` on executables
- [ ] **TOOL-02**: CI (GitHub Actions) builds, runs the test suite, and runs `hlint`/`fourmolu` checks on every push to `main` and PRs on both remotes
- [ ] **TOOL-03**: Developer can run `stack test` and `stack run echo -- --dump-manifest` from a clean clone with no extra setup beyond ghcup/stack

### Wire (WIRE)

- [ ] **WIRE-01**: Owned JSON-RPC 2.0 envelope types (`Request`, `Response`, `Notification`, `ErrorObject`) with aeson codecs; `params :: Object` makes non-object params unrepresentable
- [ ] **WIRE-02**: Newline-delimited stdio transport behind a `Transport` interface; frames are `encode msg <> "\n"`; reader is bounded by a configurable `maxFrameBytes` and rejects oversize frames with a JSON-RPC error
- [ ] **WIRE-03**: Every inbound frame is validated and rebuilt (unknown fields dropped, non-numeric/string ids rejected) before reaching a handler; junk lines produce a `-32700` error frame, never a crash
- [ ] **WIRE-04**: Async-per-request router: each request runs in its own `async`; `$/cancel {id}` flips that request's `cancelled :: STM Bool`; late cancels after completion are ignored without error
- [ ] **WIRE-05**: Outbound plugin→host requests correlate replies through an STM id map; ids never collide with host-issued ids (distinct id namespaces)
- [ ] **WIRE-06**: In-memory transport pair for tests; a Haskell fake host that replays `corpus/host.jsonl`
- [ ] **WIRE-07**: Golden tests for every corpus frame (decode-then-compare, not byte-exact) and QuickCheck round-trip properties for all envelope codecs

### Schema (SCHEMA)

- [ ] **SCHEMA-01**: `DshSchema` ADT whose constructors are exactly the harness-supported subset (scalar `type`, `oneOf` ≥2, object `properties`/`required`/boolean `additionalProperties`, array `items`, scalar `enum`/`const`, `description`); `$ref`, `$defs`, `anyOf`, numeric bounds are unrepresentable
- [ ] **SCHEMA-02**: `HasCodec`-based derivation (`autodocodec`) produces `ToJSON`/`FromJSON`/`DshSchema` from one declaration; derivation of a recursive or map-shaped type fails at manifest time with a named error
- [ ] **SCHEMA-03**: Manifest post-processor rewrites `$comment`→`description`, adds `additionalProperties: false` to objects, emits `integer` for integral types, and is pinned by a golden test
- [ ] **SCHEMA-04**: Tool args are validated against the derived schema (`validateAccordingTo`) before decoding; a failure returns a JSON-RPC error, never a Haskell exception
- [ ] **SCHEMA-05**: Integers outside the JS safe range are rejected by schema/validation (lossless-JSON policy) rather than silently rounded

### Plugin API (API)

- [ ] **API-01**: `Plugin` record (`name`, `tools`, `guards`, `sections`, `subagents`) and `runPlugin :: Config -> Plugin -> IO ()` owning the event loop, handshake, dispatch, and shutdown on stdin EOF / `shutdown`
- [ ] **API-02**: `runPlugin` hardening: `hDuplicateTo stderr stdout` before any user code, binary + UTF-8 handles, line buffering on the frame handle, SIGPIPE handled as clean exit
- [ ] **API-03**: `Tool` existential with `HasCodec` args/output, mandatory output schema, `execute :: a -> Exec -> IO v`, pure `render :: a -> v -> [ContentBlock]`; the result envelope carries `value` plus rendered `content`
- [ ] **API-04**: `ContentBlock` mirrors the harness (`text | reasoning | image | tool-call | tool-result`) with an `Unknown Value` fall-through; codecs round-trip the harness's JSON exactly
- [ ] **API-05**: `Exec` exposes `callId`, `cancelled :: STM Bool`, and a `checkCancelled :: IO ()` helper; a cancelled tool returns a `-32800` error
- [ ] **API-06**: `Guard` with `matches :: ToolName -> Bool` and `decide :: ToolCall -> Exec -> IO GuardDecision`, `GuardDecision = Allow | Deny Text | Ask (Maybe Text)`; a guard exception or timeout maps to a configurable fail-open/fail-closed policy declared in the manifest
- [ ] **API-07**: `Section` = static text declared in the manifest; `notifySectionChanged :: PluginHandle -> SectionId -> Text -> IO ()` pushes `section/changed`
- [ ] **API-08**: `Subagent` provider: `run :: Delegation -> Exec -> IO SubagentResult` with `{stopReason, lastAssistantMessage :: [ContentBlock]}`, mirroring `packages/subagent` types
- [ ] **API-09**: `--dump-manifest` prints the exact handshake manifest JSON and exits 0; `--protocol-version` prints the version
- [ ] **API-10**: `examples/echo`: one `echo` tool (args `{text}` → output `{echoed}`), one guard denying calls whose text contains `"forbidden"`, one static section; builds as `dsh-plugin-echo`

### Bridge (BRIDGE) — delivered as a PR to deepseek-harness

- [ ] **BRIDGE-01**: New package `@deepseek-ai/dsh-remote-plugin` following `docs/cookbook/adding-a-package.md` (package.json invariants, tsconfig reference, README with gated sections, `invariant.ts`, Agent Note)
- [ ] **BRIDGE-02**: Spawns the plugin through `ctx.subprocess` (not `node:child_process`) with `stdin: 'pipe'`, stderr forwarded to harness logs, process-tree cleanup on dispose
- [ ] **BRIDGE-03**: Performs the host-initiated handshake, validates the manifest as hostile input, rejects on `protocolVersion` mismatch with a loud load error
- [ ] **BRIDGE-04**: Registers each manifest tool on `ctx.tools` via `ctx.effect()` with the declared output schema and a `render` that returns the `content` shipped in the `tool/execute` result; cancellation reads `exec.signal` at point of use and forwards `$/cancel`
- [ ] **BRIDGE-05**: Registers guards as `tools/pre-execute` waterfall listeners that call `next()` on `allow` and return `deny`/`ask` otherwise; a timeout applies the manifest's fail policy so the waterfall always completes
- [ ] **BRIDGE-06**: Registers static sections on `ctx.systemPrompt` and re-registers on `section/changed`
- [ ] **BRIDGE-07**: Registers subagent providers on `ctx.subagent` forwarding `subagent/run`
- [ ] **BRIDGE-08**: All tunables (`command`, `args`, `env`, `cwd`, `maxFrameBytes`, `requestTimeoutMs`, `guardFailPolicy`) are validated `Config` fields; HMR config change restarts the child without orphaning it
- [ ] **BRIDGE-09**: A ~50-line Node fixture plugin replays `corpus/plugin.jsonl`; a runnable example composition in `packages/examples` uses it and a keyless snapshot records the model calling the tool and the guard denying a call
- [ ] **BRIDGE-10**: Bridge tests replay `corpus/host.jsonl` and hostile frames; per-file 100% coverage passes

### End-to-end (E2E)

- [ ] **E2E-01**: In this repo, `stack test` includes an e2e that drives the built echo binary through the fake host replaying the full corpus
- [ ] **E2E-02**: In this repo, a keyed e2e (skipped without `DEEPSEEK_API_KEY`) runs `dsh --profile headless` with a patch row pointing at `dsh-plugin-echo` and asserts the session log shows a `tool/call` to `echo` and a denied call
- [ ] **E2E-03**: Maintainer alignment recorded: whether harness CI gets a GHC job or the Node fixture is the sanctioned path (decision captured in the bridge PR's Agent Note)

## v2 Requirements

### Transport
- **XPORT-01**: Streamable-HTTP transport behind the same `Transport` interface
- **XPORT-02**: WebSocket transport

### Generic Cordis
- **CORDIS-01**: Generic `service/call` and `event/subscribe` reflection with all four dispatch modes
- **CORDIS-02**: Typert-generated typed Haskell bindings over the generic layer

### Ergonomics
- **ERGO-01**: `agent/inject` from the plugin
- **ERGO-02**: Progress notifications during long tool runs
- **ERGO-03**: Custom durable session events (`SessionEventMap` extension with `ignorable: true`)
- **ERGO-04**: HPC coverage gate mirroring the harness's per-file threshold

## Out of Scope

| Feature | Reason |
|---------|--------|
| Guard argument rewriting | Harness `PreToolDecision` is `allow\|deny\|ask`; rewriting excluded upstream because args are already logged |
| Dynamic per-step prompt sections | `PromptSection.text` is synchronous; per-step IPC would also break KV-cache prefix stability |
| Remote `render`/`presentCall` at replay time | Harness replays session logs without the plugin process; render runs plugin-side at execute time instead |
| Streaming seams (`ctx.llm`, `ctx.shell`, `ctx.fs`, LSP, terminal) | Stream-shaped or chatty; stay in-process |
| Web client / UI contributions | TypeScript by design |
| Live self-modification in Haskell | GHC compile latency |
| MCP Sampling/Logging-style features | Deprecated in MCP 2026-07-28; no harness counterpart |

## Traceability

Which phases cover which requirements. Every v1 requirement maps to exactly one phase.

| Requirement | Phase | Status |
|-------------|-------|--------|
| PROTO-01 | Phase 1 — Protocol Freeze and Toolchain Foundation | Pending |
| PROTO-02 | Phase 1 — Protocol Freeze and Toolchain Foundation | Pending |
| PROTO-03 | Phase 1 — Protocol Freeze and Toolchain Foundation | Pending |
| PROTO-04 | Phase 1 — Protocol Freeze and Toolchain Foundation | Pending |
| TOOL-01 | Phase 1 — Protocol Freeze and Toolchain Foundation | Complete |
| TOOL-02 | Phase 1 — Protocol Freeze and Toolchain Foundation | Pending |
| TOOL-03 | Phase 7 — Echo Example and Conformance Gate | Pending |
| WIRE-01 | Phase 2 — Wire Envelope and Transport | Pending |
| WIRE-02 | Phase 2 — Wire Envelope and Transport | Pending |
| WIRE-03 | Phase 2 — Wire Envelope and Transport | Pending |
| WIRE-04 | Phase 3 — Peer, Async Router, and Cancellation | Pending |
| WIRE-05 | Phase 3 — Peer, Async Router, and Cancellation | Pending |
| WIRE-06 | Phase 2 — Wire Envelope and Transport | Pending |
| WIRE-07 | Phase 2 — Wire Envelope and Transport | Pending |
| SCHEMA-01 | Phase 4 — Schema Derivation and Validation | Pending |
| SCHEMA-02 | Phase 4 — Schema Derivation and Validation | Pending |
| SCHEMA-03 | Phase 4 — Schema Derivation and Validation | Pending |
| SCHEMA-04 | Phase 4 — Schema Derivation and Validation | Pending |
| SCHEMA-05 | Phase 4 — Schema Derivation and Validation | Pending |
| API-01 | Phase 5 — Plugin API, Manifest, and runPlugin | Pending |
| API-02 | Phase 5 — Plugin API, Manifest, and runPlugin | Pending |
| API-03 | Phase 5 — Plugin API, Manifest, and runPlugin | Pending |
| API-04 | Phase 5 — Plugin API, Manifest, and runPlugin | Pending |
| API-05 | Phase 3 — Peer, Async Router, and Cancellation | Pending |
| API-06 | Phase 6 — Guard, Section, and Subagent Seams (Haskell) | Pending |
| API-07 | Phase 6 — Guard, Section, and Subagent Seams (Haskell) | Pending |
| API-08 | Phase 6 — Guard, Section, and Subagent Seams (Haskell) | Pending |
| API-09 | Phase 5 — Plugin API, Manifest, and runPlugin | Pending |
| API-10 | Phase 7 — Echo Example and Conformance Gate | Pending |
| BRIDGE-01 | Phase 8 — Bridge Package, Spawn, Handshake, and Tools | Pending |
| BRIDGE-02 | Phase 8 — Bridge Package, Spawn, Handshake, and Tools | Pending |
| BRIDGE-03 | Phase 8 — Bridge Package, Spawn, Handshake, and Tools | Pending |
| BRIDGE-04 | Phase 8 — Bridge Package, Spawn, Handshake, and Tools | Pending |
| BRIDGE-05 | Phase 9 — Bridge Guard, Section, and Subagent Registration | Pending |
| BRIDGE-06 | Phase 9 — Bridge Guard, Section, and Subagent Registration | Pending |
| BRIDGE-07 | Phase 9 — Bridge Guard, Section, and Subagent Registration | Pending |
| BRIDGE-08 | Phase 8 — Bridge Package, Spawn, Handshake, and Tools | Pending |
| BRIDGE-09 | Phase 10 — End-to-End Validation and Harness Gates | Pending |
| BRIDGE-10 | Phase 10 — End-to-End Validation and Harness Gates | Pending |
| E2E-01 | Phase 7 — Echo Example and Conformance Gate | Pending |
| E2E-02 | Phase 10 — End-to-End Validation and Harness Gates | Pending |
| E2E-03 | Phase 1 — Protocol Freeze and Toolchain Foundation | Pending |

**Coverage:**
- v1 requirements: 42 total (the earlier count of 44 was a miscount; 42 checklist items are defined above)
- Mapped to phases: 42
- Unmapped: 0 ✓

**Phase totals:** P1: 7 · P2: 5 · P3: 3 · P4: 5 · P5: 5 · P6: 3 · P7: 3 · P8: 5 · P9: 3 · P10: 3

---
*Requirements defined: 2026-08-25*
*Last updated: 2026-08-25 after roadmap creation (traceability filled, coverage corrected to 42)*
