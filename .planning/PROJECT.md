# haskell-deepseek-plugin-sdk

## What This Is

A Haskell (Stack) SDK for writing DeepSeek Harness plugins without running any TypeScript. A plugin author defines tools, tool guards, prompt sections, and subagent providers as typed Haskell values; the SDK speaks newline-delimited JSON-RPC 2.0 over stdio to a small bridge plugin mounted inside the harness's Cordis context, which registers those contributions as ordinary `ctx.effect()` registrations. Upstream lives at `d2p-finance/haskell-deepseek-plugin-sdk`; development happens on the `JMSBPP/haskell-deepseek-plugin-sdk-develop` fork.

## Core Value

A model running in a headless `dsh` profile can call a tool implemented in Haskell, and a Haskell guard can veto a tool call — with the whole exchange reproducible in a keyless snapshot.

## Requirements

### Validated

(None yet — ship to validate)

### Active

- [ ] JSON-RPC 2.0 request/response/notification envelope with newline-delimited stdio framing, built on a maintained Hackage package (evaluate `jsonrpc`/`json-rpc` first; fall back to an owned aeson module only if none is maintained)
- [ ] Bidirectional dispatch: plugin handles harness→plugin requests (`tool/execute`, `guard/decide`, `section/render`, `subagent/run`, `shutdown`, `$/cancel`) and issues plugin→harness requests (`initialize` handshake, later `agent/inject`)
- [ ] `Plugin` record with `tools`, `guards`, `sections`, `subagents`; `runPlugin :: Plugin -> IO ()` owns the event loop, stdout buffering, EOF/SIGPIPE shutdown
- [ ] `Tool` with args/output types whose JSON Schema is derived from the Haskell types (`HasSchema` class, Generic default), `execute :: a -> Exec -> IO v`, pure total `render :: a -> v -> [ContentBlock]`
- [ ] `Guard` for `tools/pre-execute` returning `Allow | Deny Text | Rewrite Value` (Allow = waterfall `next()`)
- [ ] `Section` prompt-section provider
- [ ] `Subagent` provider: one delegation request in, `{stopReason, lastAssistantMessage}` out
- [ ] `ContentBlock` mirroring `packages/llm/llm/src/types.ts` (`text | reasoning | image | tool-call | tool-result`) with an `Unknown Value` case for merge-extensibility
- [ ] Cancellation: `$/cancel {id}` notification flips `Exec.cancelled :: STM Bool`
- [ ] Every inbound frame validated and rebuilt before use (hostile-input stance matching the harness's own fd-3 protocol)
- [ ] `--dump-manifest` flag prints the handshake JSON so the bridge can snapshot it without GHC in CI
- [ ] `protocolVersion` in the handshake; mismatches fail loud, no compatibility shims (pre-1.0 stance matching deepseek-harness)
- [ ] Golden tests for wire frames (`hspec-golden`) and property tests for codecs (`QuickCheck`)
- [ ] `examples/echo`: one tool + one guard executable
- [ ] TypeScript bridge plugin `@deepseek-ai/dsh-remote-plugin` in deepseek-harness (separate PR there): spawns the plugin binary, performs handshake, registers tools/guards/sections/subagents as Cordis effects, forwards cancellation, HMR restart on config change
- [ ] End-to-end: headless `dsh` profile row pointing at the echo binary; keyless snapshot recording a model calling the Haskell tool and the guard vetoing a call

### Out of Scope

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

- **Tech stack**: Haskell via Stack, resolver pinned (`lts-22.43`) — reproducible builds; GHC 9.6 line
- **Transport**: newline-delimited JSON-RPC 2.0 over stdio, stdout reserved for frames, logs to stderr — matches harness SDK server and MCP stdio framing
- **Dependencies**: maintained Hackage packages preferred over hand-rolling (mirrors the harness policy); unmaintained JSON-RPC libs are rejected, not patched
- **Compatibility**: none promised pre-1.0; protocol version mismatches fail loud
- **Cross-repo**: the bridge lands in deepseek-harness under its gates; this repo cannot merge the e2e requirement alone
- **Security**: inbound frames are hostile input; model-controlled tool args are validated against the derived schema before decode

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Bind dsh seams (Tool/Guard/Section/Subagent) in v1, not generic Cordis reflection | Fastest path to a model-callable Haskell tool; keeps the wire typed | — Pending |
| stdio transport only in v1, behind a transport interface | Matches existing harness stdio protocols; HTTP/WS additive later | — Pending |
| Use a Hackage JSON-RPC package if maintained, else own aeson module | Dependencies-over-hand-rolling, but not at the cost of an abandoned dep | — Pending |
| TS bridge is a phase of this roadmap, delivered as a PR to deepseek-harness | e2e core value is unreachable without it | — Pending |
| Upstream `d2p-finance`, develop on `JMSBPP` fork | Requested ownership split | ✓ Done |

---
*Last updated: 2026-08-25 after initialization*
