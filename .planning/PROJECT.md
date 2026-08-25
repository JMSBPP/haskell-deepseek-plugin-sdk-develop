# haskell-deepseek-plugin-sdk

## What This Is

A Haskell (Stack) SDK for writing DeepSeek Harness plugins without running any TypeScript. A plugin author defines tools, tool guards, prompt sections, and subagent providers as typed Haskell values; the SDK speaks newline-delimited JSON-RPC 2.0 over stdio to a small bridge plugin mounted inside the harness's Cordis context, which registers those contributions as ordinary `ctx.effect()` registrations. Upstream lives at `d2p-finance/haskell-deepseek-plugin-sdk`; development happens on the `JMSBPP/haskell-deepseek-plugin-sdk-develop` fork.

## Core Value

A model running in a headless `dsh` profile can call a tool implemented in Haskell, and a Haskell guard can veto a tool call — with the whole exchange reproducible in a keyless snapshot.

## Requirements

### Validated

(None yet — ship to validate)

### Active

- [ ] Owned JSON-RPC 2.0 envelope (~250 LOC on aeson + stm): request/response/notification, newline-delimited stdio framing, `params` always a JSON object, no batch support, bounded reader (`maxFrameBytes` config). Hackage `json-rpc` (unframed output, heavy closure) and `jsonrpc` (MPL-2.0, one vendor) were evaluated and rejected
- [ ] Bidirectional dispatch: host-initiated `initialize` handshake returns the manifest; plugin handles `tool/execute`, `guard/decide`, `subagent/run`, `shutdown`, `$/cancel`; plugin may push `section.changed` and later `agent/inject`
- [ ] `Plugin` record with `tools`, `guards`, `sections`, `subagents`; `runPlugin :: Plugin -> IO ()` owns the event loop, stdout buffering, EOF/SIGPIPE shutdown
- [ ] `Tool` with args/output types whose JSON Schema is derived via `autodocodec` into an owned `DshSchema` ADT restricted to the harness's supported subset (no `$ref`/`$defs`/`anyOf`/bounds; `$comment`→`description`); output schema mandatory; `execute :: a -> Exec -> IO v`; pure total `render :: a -> v -> [ContentBlock]` runs plugin-side at execute time and ships its blocks inside the `tool/execute` result so the harness can replay without the process
- [ ] `Guard` bound to the `tools/pre-execute` waterfall returning `Allow | Deny Text | Ask (Maybe Text)` (Allow = `next()`); rewrite is not honored by the harness's `PreToolDecision` and is excluded
- [ ] `Section`: static prompt-section text declared in the manifest, refreshed by a `section.changed` push notification (`PromptSection.text` is synchronous in the harness, so no per-step round-trip)
- [ ] `Subagent` provider: one delegation request in, `{stopReason, output}` out
- [ ] `ContentBlock` mirroring `packages/llm/llm/src/types.ts` (`text | reasoning | image | tool-call | tool-result`) with an `Unknown Value` case for merge-extensibility
- [ ] Cancellation: `$/cancel {id}` notification flips `Exec.cancelled :: STM Bool`
- [ ] Every inbound frame validated and rebuilt before use (hostile-input stance matching the harness's own fd-3 protocol)
- [ ] Frozen `PROTOCOL.md` plus a shared conformance frame corpus (`host.jsonl`/`plugin.jsonl`) that both the Haskell tests and the TS bridge tests replay
- [ ] `runPlugin` hardening: `hDuplicateTo stderr stdout` so stray writes cannot corrupt framing, binary/UTF-8 handles, `-threaded` RTS, async-per-request router so `$/cancel` is readable while handlers run
- [ ] `--dump-manifest` flag prints the handshake JSON so the bridge can snapshot it without GHC in CI
- [ ] `protocolVersion` in the handshake; mismatches fail loud, no compatibility shims (pre-1.0 stance matching deepseek-harness)
- [ ] Golden tests for wire frames (`hspec-golden`) and property tests for codecs (`QuickCheck`)
- [ ] `examples/echo`: one tool + one guard executable
- [ ] TypeScript bridge plugin `@deepseek-ai/dsh-remote-plugin` in deepseek-harness (separate PR there): spawns the plugin binary, performs handshake, registers tools/guards/sections/subagents as Cordis effects, forwards cancellation, HMR restart on config change
- [ ] End-to-end, split by CI capability: (a) in deepseek-harness, a keyless snapshot through a runnable example whose bridge row points at a ~50-line Node fixture plugin replaying the shared frame corpus (harness CI has no GHC); (b) in this repo, a real-binary e2e that runs the echo plugin against `dsh --profile headless` when `DEEPSEEK_API_KEY` is present and against the fake host otherwise

### Out of Scope

- Guard argument rewriting — harness `PreToolDecision` is `allow|deny|ask`; rewriting is excluded upstream because arguments are already logged
- Dynamic per-step prompt sections — synchronous harness API and KV-cache prefix stability
- Generic Cordis reflection (arbitrary `service/call`, `event/subscribe` with dispatch modes) — v2; v1 binds named dsh seams only
- Typert-generated Haskell bindings — depends on generic reflection
- HTTP / WebSocket transports — stdio only in v1; transport is behind one interface so these can be added
- Streaming seams (`ctx.llm`, `ctx.shell`, `ctx.fs`, LSP, terminal) — chatty or stream-shaped; stay in-process
- Client/UI contributions — web client is TypeScript by design
- Live self-modification (agent authoring Haskell plugins at runtime) — GHC compile latency; not a v1 goal

## Context

- Target: DeepSeek Harness (`~/ai-agents/deepseek-harness`), a Cordis plugin harness. Everything is a plugin; a plugin is `(inject, apply)` over a keyed context; registrations are reversible effects; events dispatch as `emit | waterfall | parallel | serial`; waterfall listeners must call `next()`.
- Cordis has no wire. Existing out-of-process surfaces are inbound-only (SDK JSON-RPC `packages/sdk/protocol`, ACP) or contribution-specific (MCP client for tools, hook bridges for interception). No generic remote-plugin protocol exists; the bridge is new work, modelled on `packages/hooks/hooks-claude-code` (intercept half) and `packages/mcp/mcp-client` (provide half: `connection.ts`, `transport.ts`, `tools.ts`).
- Harness conventions the bridge must satisfy: snapshot test via a runnable example, Agent Note in the PR, 100% per-file coverage, `Config` fields for every tunable, hostile validation at process boundaries, README with gated sections.
- Tool contract source of truth: `packages/core/tools/src/index.ts` (`ToolDefinition`, `ToolOutputDefinition` with pure `render`); content blocks: `packages/llm/llm/src/types.ts`.
- Out-of-tree install path already exists: profile `package.json` dependencies + `cordis.patch.yml` (`packages/boot/app-boot/README.md`).
- Toolchain present: ghcup, Stack 3.11.1, GHC, cabal. Project scaffolded from the `simple` template on `lts-22.43`.

## Constraints

- **Tech stack**: Haskell via Stack, resolver pinned to `lts-24.56` (GHC 9.10.3) — `lts-22.43` emitted `integer` args as `number` and lacks aeson 2.2; library + executable + test-suite, `GHC2024`, `-threaded`
- **Transport**: newline-delimited JSON-RPC 2.0 over stdio, stdout reserved for frames, logs to stderr — matches harness SDK server and MCP stdio framing
- **Dependencies**: maintained Hackage packages preferred, but a dependency must fit the wire exactly; the JSON-RPC envelope and `DshSchema` are owned because no package matched
- **Compatibility**: none promised pre-1.0; protocol version mismatches fail loud
- **Cross-repo**: the bridge lands in deepseek-harness under its gates; this repo cannot merge the e2e requirement alone
- **Security**: inbound frames are hostile input; model-controlled tool args are validated against the derived schema before decode

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Bind dsh seams (Tool/Guard/Section/Subagent) in v1, not generic Cordis reflection | Fastest path to a model-callable Haskell tool; keeps the wire typed | — Pending |
| stdio transport only in v1, behind a transport interface | Matches existing harness stdio protocols; HTTP/WS additive later | — Pending |
| Own the JSON-RPC envelope; use `autodocodec` for codecs but an owned `DshSchema` ADT | Research: `json-rpc` emits unframed output, `jsonrpc` is MPL-2.0/one-vendor; `autodocodec-schema` emits constructs the harness rejects | ✓ Decided (research) |
| Guard = `Allow | Deny | Ask`; sections static; `render` plugin-side | Harness types are synchronous / closed; verified in `packages/core/tools` and `system-prompt` source | ✓ Decided (research) |
| Snapshot via Node fixture plugin in harness CI; real-binary e2e in this repo | Harness CI has no GHC; snapshot rule forbids mock compositions | — Pending maintainer alignment |
| Repin to `lts-24.56` | Series terminal, aeson 2.2, correct integer schemas | — Pending (Phase 0) |
| TS bridge is a phase of this roadmap, delivered as a PR to deepseek-harness | e2e core value is unreachable without it | — Pending |
| Upstream `d2p-finance`, develop on `JMSBPP` fork | Requested ownership split | ✓ Done |

---
*Last updated: 2026-08-25 after research corrections*
