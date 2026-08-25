# Roadmap: haskell-deepseek-plugin-sdk

## Overview

The journey runs from a frozen wire to a model calling Haskell. Phase 1 decides everything that is not retrofittable — the protocol spec, a committed conformance frame corpus, the resolver repin, and a maintainer decision about GHC-less harness CI — and that single artifact set splits the rest of the work into two independent streams. The Haskell stream builds bottom-up: envelope and transport, then the async router that makes cancellation possible, then schema derivation (parallel, no shared module), then the plugin API and `runPlugin`, then the guard/section/subagent seams, ending at an echo binary proven against the corpus with no TypeScript in the loop. The TypeScript stream starts the moment the corpus exists and never needs GHC: a protocol package and a spawn/handshake/tools bridge, then the remaining three registration kinds. The two streams meet once, at end-to-end validation, where the keyless snapshot and the harness contribution gates apply.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [ ] **Phase 1: Protocol Freeze and Toolchain Foundation** - Frozen `PROTOCOL.md`, shared frame corpus, `lts-24.56` repin, CI, and the harness-CI alignment decision
- [ ] **Phase 2: Wire Envelope and Transport** - Owned JSON-RPC 2.0 codec, bounded NDJSON stdio transport, in-memory pair, and frame goldens
- [ ] **Phase 3: Peer, Async Router, and Cancellation** - One `async` per request, STM correlation and cancel registries, `Exec`
- [ ] **Phase 4: Schema Derivation and Validation** - `DshSchema` restricted to the harness subset, one-declaration derivation, hostile-arg validator
- [ ] **Phase 5: Plugin API, Manifest, and runPlugin** - `Plugin`/`Tool`/`ContentBlock`, handshake, fd hygiene, `tool/execute`, `--dump-manifest`
- [ ] **Phase 6: Guard, Section, and Subagent Seams (Haskell)** - The three non-tool contributions and their failure policies
- [ ] **Phase 7: Echo Example and Conformance Gate** - `examples/echo` plus the fake host replaying the full corpus — the "Haskell is correct" gate
- [ ] **Phase 8: Bridge Package, Spawn, Handshake, and Tools** - `@deepseek-ai/dsh-remote-plugin` supervisor registering remote tools as Cordis effects
- [ ] **Phase 9: Bridge Guard, Section, and Subagent Registration** - `tools/pre-execute` translation, static sections, subagent providers
- [ ] **Phase 10: End-to-End Validation and Harness Gates** - Keyless snapshot, real-binary keyed e2e, coverage and doc-sync gates

**Parallelism:** Phases 2-7 (Haskell) and Phases 8-9 (TypeScript bridge) are independent after Phase 1 and can proceed concurrently. Phase 4 is independent of Phases 2-3. Phase 10 requires both streams.

## Phase Details

### Phase 1: Protocol Freeze and Toolchain Foundation
**Goal**: The wire is decided, written down, and pinned by shared bytes, and a clean clone builds and tests on a sound toolchain.
**Depends on**: Nothing (first phase)
**Requirements**: PROTO-01, PROTO-02, PROTO-03, PROTO-04, TOOL-01, TOOL-02, E2E-03
**Success Criteria** (what must be TRUE):
  1. A developer reading `PROTOCOL.md` alone can state every method name and direction, the handshake manifest fields, the full error-code table, the `params`-is-always-an-object and no-batch rules, and the large-integer policy — without reading any code.
  2. `corpus/*/host.jsonl` and `corpus/*/plugin.jsonl` exist and cover handshake, tool call, tool failure, unknown tool, subagent run, plugin-originated section change, guard decision, in-flight/late/unknown cancellation, malformed frames (junk line, bad shape, oversize), shutdown, and `protocolVersion` mismatch, with an id-normalization rule both implementations apply identically.
  3. `stack build` and `stack test` succeed from a clean clone on `lts-24.56` (GHC 9.10.3) with library, executable, and test-suite stanzas under `GHC2024`, `-Wall`, and `-threaded -rtsopts "-with-rtsopts=-N"`.
  4. A push or PR on either remote runs a GitHub Actions job that builds, runs the test suite, and reports `hlint`/`fourmolu` results.
  5. A written maintainer decision exists stating which e2e tier deepseek-harness CI will accept (a GHC job versus the Node fixture plugin), and it is referenceable from the eventual bridge PR.
**Plans**: 5 plans

Plans:
- [ ] 01-01-PLAN.md — Repin `lts-24.56` and replace the scaffold with an hpack library + executable + test-suite
- [ ] 01-02-PLAN.md — Write the 17-scenario conformance corpus and freeze `PROTOCOL.md`
- [x] 01-03-PLAN.md — ADR 0001 (e2e tiering), the CI workflow, and the linter configuration
- [ ] 01-04-PLAN.md — The tasty conformance skeleton with visible red state and the four property families
- [ ] 01-05-PLAN.md — Confirm Actions is enabled and record a green CI run on both remotes

Note: PROTO-03's runtime halves are implemented later (plugin side in Phase 5, host side in Phase 8); here it is frozen in the spec and pinned by the mismatch corpus scenario. Unresolved on entry: the cancellation error code is written `-32800` in REQUIREMENTS.md and `-32003` in ARCHITECTURE.md — `PROTOCOL.md` must pick one and the corpus must carry it.

### Phase 2: Wire Envelope and Transport
**Goal**: Frames cross a pipe safely, and every corpus frame means the same thing in Haskell as it does on the wire.
**Depends on**: Phase 1
**Requirements**: WIRE-01, WIRE-02, WIRE-03, WIRE-06, WIRE-07
**Success Criteria** (what must be TRUE):
  1. Every frame in the corpus decodes into envelope values and re-encodes to an equal value, pinned by a golden test that compares decoded values rather than bytes.
  2. A junk line, a frame larger than the configured `maxFrameBytes`, a non-numeric/string id, and a non-object `params` each produce the specified JSON-RPC error frame on the wire instead of crashing or hanging the process.
  3. A test drives both ends of the protocol inside one process through the in-memory transport pair, with no file descriptors and no subprocess.
  4. A Haskell fake host replays `corpus/host.jsonl` into a transport and captures what came back, ready for later phases to assert against.
  5. QuickCheck round-trips every envelope codec over generated values with no failures.
**Plans**: TBD

### Phase 3: Peer, Async Router, and Cancellation
**Goal**: A long-running handler can be cancelled while it runs, and replies always find their waiter.
**Depends on**: Phase 2
**Requirements**: WIRE-04, WIRE-05, API-05
**Success Criteria** (what must be TRUE):
  1. A slow handler does not block the reader: a `$/cancel` for an in-flight id is observed and acted on while that handler is still running.
  2. A cancelled handler sees `Exec.cancelled` flip to `True`, `checkCancelled` aborts it, and the request resolves with the spec's cancellation code rather than an abandoned pending entry.
  3. A `$/cancel` for an unknown or already-completed id is ignored with no error frame, no crash, and no log-level noise above `debug`.
  4. A plugin-issued request id and a host-issued request id with the same numeric value never correlate to each other, and concurrent outbound requests each receive their own reply.
**Plans**: TBD

### Phase 4: Schema Derivation and Validation
**Goal**: A plugin author writes one type declaration and gets a schema the harness will accept and a validator hostile input cannot break.
**Depends on**: Phase 1
**Requirements**: SCHEMA-01, SCHEMA-02, SCHEMA-03, SCHEMA-04, SCHEMA-05
**Success Criteria** (what must be TRUE):
  1. An author declares a type once and gets `ToJSON`, `FromJSON`, and a `DshSchema` from it; the emitted JSON contains no `$ref`, `$defs`, `anyOf`, or numeric bounds because those are unrepresentable in the ADT.
  2. Declaring a recursive or map-shaped argument type fails at manifest time with an error naming the offending type, rather than emitting a schema the harness will reject at registration.
  3. An integral field emits `"type":"integer"`, every object carries `additionalProperties: false`, and `$comment` appears as `description` — all pinned by a golden test.
  4. Any generated JSON value fed to the validator either validates or returns a violation list naming the failing path; a Haskell exception never escapes.
  5. An integer outside the JS safe range is rejected with a named violation instead of silently rounding.
**Plans**: TBD

### Phase 5: Plugin API, Manifest, and runPlugin
**Goal**: A Haskell process is a working plugin: it handshakes, executes tools, renders content, and dies cleanly.
**Depends on**: Phase 3, Phase 4
**Requirements**: PROTO-03, API-01, API-02, API-03, API-04, API-09
**Success Criteria** (what must be TRUE):
  1. `runPlugin` answers a host-initiated `initialize` with the manifest projected from the `Plugin` record, then serves requests until stdin EOF, a `shutdown` request, or SIGPIPE — each of which exits cleanly with no orphaned threads.
  2. A stray `putStrLn` from author code or a dependency lands on stderr and cannot corrupt a single frame on stdout.
  3. `tool/execute` returns `{value, content}` where `content` is the plugin-side `render` output whose blocks round-trip the harness's own block JSON exactly, including unknown block kinds; a handler exception becomes a domain failure code, not a dead process.
  4. `--dump-manifest` prints byte-for-byte the JSON a host would have received from `initialize` and exits 0, and `--protocol-version` prints the version — both without a host.
  5. A `protocolVersion` mismatch on `initialize` fails loud with both versions in the message and no contribution served.
**Plans**: TBD

### Phase 6: Guard, Section, and Subagent Seams (Haskell)
**Goal**: The three non-tool contributions work on the wire, with their failure behavior declared rather than assumed.
**Depends on**: Phase 5
**Requirements**: API-06, API-07, API-08
**Success Criteria** (what must be TRUE):
  1. A guard matching a tool name answers `guard/decide` with allow, deny, or ask, and a deny carries a model-readable reason.
  2. A guard that throws or exceeds its timeout resolves to the fail-open/fail-closed policy declared in the manifest, and that policy is visible in `--dump-manifest`.
  3. `notifySectionChanged` pushes a `section.changed` notification carrying the new text, and a section otherwise costs zero round trips because its text ships in the manifest.
  4. A subagent provider answers `subagent/run` with a stop reason and a last assistant message expressed as content blocks.
**Plans**: TBD

### Phase 7: Echo Example and Conformance Gate
**Goal**: The Haskell side is provably correct against the frozen corpus, with no TypeScript anywhere in the loop.
**Depends on**: Phase 6
**Requirements**: API-10, TOOL-03, E2E-01
**Success Criteria** (what must be TRUE):
  1. From a clean clone with nothing installed beyond ghcup and stack, `stack test` and `stack run echo -- --dump-manifest` both succeed.
  2. `stack test` drives the built `dsh-plugin-echo` binary through the fake host across every corpus scenario, and the captured output equals `plugin.jsonl` modulo id normalization.
  3. The echo tool maps `{text}` to `{echoed}`, the guard denies any call whose text contains `"forbidden"`, and the static section appears in the manifest.
  4. A contributor can prove the SDK correct without deepseek-harness checked out and without an API key.
**Plans**: TBD

### Phase 8: Bridge Package, Spawn, Handshake, and Tools
**Goal**: The harness can mount a remote plugin and a model can call its tools.
**Depends on**: Phase 1
**Requirements**: BRIDGE-01, BRIDGE-02, BRIDGE-03, BRIDGE-04, BRIDGE-08
**Success Criteria** (what must be TRUE):
  1. `@deepseek-ai/dsh-remote-plugin` loads in a Cordis context, spawns the peer through `ctx.subprocess` with stderr forwarded to harness logs, and disposing the plugin leaves no orphaned process or process tree.
  2. The manifest is rebuilt field by field as hostile input; a bad tool name, an unsupported schema, a duplicate name, or a `protocolVersion` mismatch fails activation loudly with nothing registered.
  3. A model calls a manifest tool and receives the peer's `value` plus its `content`, where the registered `render` is a pure local lookup into the already-received result and never a remote call.
  4. Aborting a tool call forwards `$/cancel` at the point of use and the agent turn completes instead of wedging.
  5. Every tunable is a validated `Config` field, and an HMR config change restarts the child without orphaning it or leaving duplicate registrations behind.
**Plans**: TBD

### Phase 9: Bridge Guard, Section, and Subagent Registration
**Goal**: The remaining three registration kinds join the same rollback unit, with guards behaving correctly on the waterfall.
**Depends on**: Phase 8
**Requirements**: BRIDGE-05, BRIDGE-06, BRIDGE-07
**Success Criteria** (what must be TRUE):
  1. A remote guard's allow calls `next()` so downstream listeners still run; deny and ask short-circuit the waterfall carrying the peer's reason.
  2. A dead, slow, or restarting peer resolves the guard through the manifest's fail policy from a `finally`, so the waterfall always completes.
  3. A manifest section appears in the assembled system prompt, and a `section.changed` push replaces it by dispose-and-re-register with no plugin restart.
  4. A remote subagent appears on `ctx.subagent` and a delegation to it returns the peer's stop reason and last assistant message.
**Plans**: TBD

### Phase 10: End-to-End Validation and Harness Gates
**Goal**: A model calls a Haskell tool and a Haskell guard vetoes a call, reproducibly, under both repos' CI.
**Depends on**: Phase 7, Phase 9
**Requirements**: BRIDGE-09, BRIDGE-10, E2E-02
**Success Criteria** (what must be TRUE):
  1. A keyless snapshot in deepseek-harness, driven by a runnable example whose bridge row points at the Node fixture plugin replaying the shared corpus, records a model calling the remote tool and a guard denying a call, and replays identically on macOS and Linux.
  2. Bridge tests replay `corpus/host.jsonl` plus hostile frames, and per-file 100% coverage passes on the new package.
  3. With `DEEPSEEK_API_KEY` set, `dsh --profile headless` with a patch row pointing at the real `dsh-plugin-echo` binary produces a session log containing a `tool/call` to `echo` and a denied call; without the key the test skips rather than fails.
  4. The bridge PR carries its Agent Note (including the Phase 1 alignment decision), gated README sections, and `invariant.ts`, and the harness's doc-sync and hygiene gates pass.
**Plans**: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10.
Dependency order permits concurrency: 4 alongside 2-3, and 8-9 alongside 2-7.

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Protocol Freeze and Toolchain Foundation | 4/5 | In Progress | - |
| 2. Wire Envelope and Transport | 0/TBD | Not started | - |
| 3. Peer, Async Router, and Cancellation | 0/TBD | Not started | - |
| 4. Schema Derivation and Validation | 0/TBD | Not started | - |
| 5. Plugin API, Manifest, and runPlugin | 0/TBD | Not started | - |
| 6. Guard, Section, and Subagent Seams (Haskell) | 0/TBD | Not started | - |
| 7. Echo Example and Conformance Gate | 0/TBD | Not started | - |
| 8. Bridge Package, Spawn, Handshake, and Tools | 0/TBD | Not started | - |
| 9. Bridge Guard, Section, and Subagent Registration | 0/TBD | Not started | - |
| 10. End-to-End Validation and Harness Gates | 0/TBD | Not started | - |

## Coverage

All 42 v1 requirements map to exactly one phase. No orphans, no duplicates. Traceability table lives in `.planning/REQUIREMENTS.md`.

---
*Roadmap created: 2026-08-25*
