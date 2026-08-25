# Architecture Research

**Domain:** Out-of-process plugin SDK (Haskell library + example binary) bridged into a Cordis plugin harness (DeepSeek Harness) over newline-delimited JSON-RPC 2.0 on stdio
**Researched:** 2026-08-25
**Confidence:** HIGH for harness-side constraints (read from `deepseek-harness` source at `b150a551b8`), MEDIUM-HIGH for Haskell library selection (Hackage/Stackage verified), MEDIUM for wire-protocol specifics (designed here from two verified precedents, not yet implemented anywhere)

---

## Standard Architecture

This is a **two-process, one-wire, three-plane** system. The shape is not novel: it is the same shape as MCP (`packages/mcp/mcp-client`), the harness's own SDK protocol (`packages/sdk/protocol` + `packages/sdk/server`), ACP, and LSP. What is novel is the *direction of contribution*: existing harness out-of-process surfaces are either **inbound-only** (something drives the harness) or **single-capability** (MCP contributes tools only). This bridge is **outbound multi-capability**: a foreign process contributes four different Cordis registration kinds.

### System Overview

```
┌──────────────────────────────────────────────────────────────────────────┐
│                    HASKELL PLUGIN PROCESS (the child)                     │
├──────────────────────────────────────────────────────────────────────────┤
│  Author plane      examples/echo/Main.hs                                  │
│                    Plugin { tools, guards, sections, subagents }          │
│                          │ (record of typed values, no IO at definition)  │
├──────────────────────────┼───────────────────────────────────────────────┤
│  SDK plane               ▼                                                │
│  ┌──────────┐  ┌──────────────┐  ┌───────────┐  ┌────────────────────┐    │
│  │ Schema   │  │ Manifest     │  │ Dispatch  │  │ Content            │    │
│  │ HasSchema│─▶│ projection   │  │ table +   │  │ ContentBlock mirror│    │
│  │ +validate│  │ (Plugin→JSON)│  │ async/req │  │ + Unknown Value    │    │
│  └──────────┘  └──────┬───────┘  └─────┬─────┘  └────────────────────┘    │
│                       │                │                                  │
│  ┌────────────────────┴────────────────┴────────────────────────────┐     │
│  │ Peer: STM correlation registry, cancel-token map, outbound reqs  │     │
│  └────────────────────────────┬─────────────────────────────────────┘     │
│  ┌────────────────────────────┴─────────────────────────────────────┐     │
│  │ Frame codec (pure) ── Transport interface ── Stdio NDJSON impl   │     │
│  └────────────────────────────┬─────────────────────────────────────┘     │
└───────────────────────────────┼──────────────────────────────────────────┘
                     fd 0 / fd 1 │ newline-delimited JSON-RPC 2.0   fd 2 → logs
                                 │ (stdout carries ONLY frames)
┌───────────────────────────────┼──────────────────────────────────────────┐
│  DSH HOST PROCESS (node)      ▼                                           │
│  ┌────────────────────────────────────────────────────────────────────┐   │
│  │ dsh-remote-plugin-protocol  (zero-Cordis: wire types, NDJSON       │   │
│  │  transport, manifest validator, error codes)                       │   │
│  └────────────────────────────┬───────────────────────────────────────┘   │
│  ┌────────────────────────────┴───────────────────────────────────────┐   │
│  │ dsh-remote-plugin  (the Cordis plugin)                             │   │
│  │  ┌───────────┐ ┌──────────┐ ┌────────┐ ┌─────────┐ ┌───────────┐   │   │
│  │  │connection │ │ tools.ts │ │guards  │ │sections │ │subagents  │   │   │
│  │  │supervisor │ │          │ │  .ts   │ │  .ts    │ │   .ts     │   │   │
│  │  └─────┬─────┘ └────┬─────┘ └───┬────┘ └────┬────┘ └─────┬─────┘   │   │
│  └────────┼────────────┼───────────┼───────────┼────────────┼─────────┘   │
├───────────┼────────────┼───────────┼───────────┼────────────┼─────────────┤
│  Cordis   ▼            ▼           ▼           ▼            ▼             │
│  ctx.subprocess   ctx.tools   tools/pre-  ctx.systemPrompt ctx.subagents  │
│  .spawn()         .register() execute     .section()    .registerProvider │
│                                (waterfall)                                │
│           every one of these is a ctx.effect() disposer                   │
├──────────────────────────────────────────────────────────────────────────┤
│  agent-loop → prompt assembly → llm/stream → tool pipeline → session log  │
└──────────────────────────────────────────────────────────────────────────┘
```

### Component Responsibilities

#### Haskell side

| Component | Responsibility | Implementation |
|---|---|---|
| `DeepSeek.Plugin` | Umbrella re-export; the only module an author imports | `module X (module Y, ...) where` |
| `…Plugin.Types` | `Plugin`/`Tool`/`Guard`/`Section`/`Subagent`/`Exec`/`Decision` records | Plain records; `Tool` is an existential (see Pattern 4) |
| `…Plugin.Content` | `ContentBlock` mirror of `packages/llm/llm/src/types.ts` | Closed sum + `BlockUnknown Value` escape |
| `…Plugin.Schema` | `DshSchema` ADT restricted to the harness's enforced subset; `HasSchema` class with `Generic` default | Own ADT + `GHC.Generics`; **not** `autodocodec-schema` |
| `…Plugin.Schema.Validate` | Mirror of the harness's `validateJsonSchemaValue` for inbound model args | Pure `DshSchema -> Value -> [Text]` |
| `…Plugin.Wire` | Method-name constants, params/result records, error codes, manifest type | Aeson records; single source of the protocol vocabulary |
| `…Plugin.Rpc.Frame` | JSON-RPC 2.0 envelope encode/decode | Pure `Value ↔ Frame`; QuickCheck roundtrip |
| `…Plugin.Rpc.Transport` | `Transport` interface (`readFrame`, `writeFrame`, `close`) + stdio NDJSON impl | Record-of-functions, so HTTP/WS is additive |
| `…Plugin.Rpc.Peer` | STM correlation of outbound request ids to `TMVar` slots; inbound routing; cancel-token map; single-writer frame lock | `TVar (Map RequestId …)` + `MVar` write lock |
| `…Plugin.Dispatch` | Method → handler table; one `async` per inbound request; result/error framing | `Control.Concurrent.Async` |
| `…Plugin.Run` | `runPlugin`, `--dump-manifest`, buffering/fd hygiene, EOF & `EPIPE` shutdown | The only `IO ()` an author calls |

#### TypeScript side

| Component | Responsibility | Precedent to copy |
|---|---|---|
| `protocol/` (own package) | Wire types, error codes, NDJSON line transport, hostile manifest validation. No Cordis import. | `packages/hooks/hook-protocol` split from `hooks-claude-code`; `packages/sdk/protocol/src/transport.ts` is the framing code |
| `index.ts` | `name` / `inject` / `Config` / `apply`; namespace plugin, no default export; namespace reservation effect; `await` startup readiness | `packages/mcp/mcp-client/src/index.ts` verbatim in structure |
| `connection.ts` | Generation supervisor: spawn, handshake, backoff/restart budget, quiescent dispose, sync serialization | `packages/mcp/mcp-client/src/connection.ts` verbatim in structure |
| `transport.ts` | Bind `JsonRpcLineTransport` to `SubprocessHandle.stdin`/`.stdout`; pipe `.stderr` to `ctx.logger` | `packages/mcp/mcp-client/src/transport.ts` (shape), `packages/subprocess/subprocess` (spawn seam) |
| `manifest.ts` | Validate + rebuild every manifest field; reject on the DeepSeek function-name contract, schema subset, duplicate names | `mcp-client/tools.ts` fetch phase + `assertSupportedJsonSchema` |
| `tools.ts` | Manifest tool → `ToolDefinition` (`execute` = remote call, `render` = local pure projection) | `mcp-client/tools.ts` `createDefinition`/`createExecutor` |
| `guards.ts` | `ctx.on('tools/pre-execute', …)` → `guard/decide` request; `Allow` ⇒ `next()` | `hooks-claude-code/src/index.ts` PreToolUse handler, line-for-line |
| `sections.ts` | Manifest sections → `ctx.systemPrompt.section()`; cache-and-push refresh | `core/system-prompt` `section()` |
| `subagents.ts` | Manifest subagents → `ctx.subagents.registerProvider()` | `packages/subagent/subagent-acp` (out-of-process provider) |

---

## Recommended Project Structure

### Haskell repo (`haskell-deepseek-plugin-sdk`)

```
stack.yaml                      # resolver: lts-22.43 (GHC 9.6.6) — pinned
package.yaml
PROTOCOL.md                     # the wire spec; source of truth for BOTH repos
conformance/                    # shared frame corpus, vendored into deepseek-harness
  001-initialize/{host.jsonl,plugin.jsonl}
  002-tool-execute-ok/…
  003-tool-execute-error/…
  004-guard-deny/…
  005-cancel-inflight/…
  006-eof-shutdown/…
  007-protocol-version-mismatch/…
src/DeepSeek/
  Plugin.hs                     # umbrella re-export — the author-facing module
  Plugin/
    Types.hs                    # Plugin, Tool, Guard, Section, Subagent, Exec, Decision
    Content.hs                  # ContentBlock mirror + BlockUnknown
    Schema.hs                   # DshSchema ADT, HasSchema, Generic default, toValue
    Schema/Validate.hs          # validateAgainst :: DshSchema -> Value -> [Text]
    Wire.hs                     # method names, params/results, ErrorCode, Manifest
    Rpc/Frame.hs                # pure JSON-RPC envelope codec
    Rpc/Transport.hs            # Transport record + stdio NDJSON impl
    Rpc/Peer.hs                 # STM correlation + cancel registry + writer lock
    Dispatch.hs                 # handler table, per-request async
    Run.hs                      # runPlugin, --dump-manifest, fd hygiene, shutdown
examples/echo/Main.hs           # one tool + one guard; the e2e subject
test/
  Spec.hs
  …/FrameSpec.hs                # QuickCheck roundtrip
  …/SchemaSpec.hs               # hspec-golden: derived schema JSON
  …/ValidateSpec.hs             # hostile-args property tests
  …/ConformanceSpec.hs          # FAKE HOST replaying conformance/ — the key gate
golden/                         # hspec-golden output
```

### TypeScript bridge (inside `deepseek-harness`, separate PR)

```
packages/remote/                          # new group: pure container, no package.json
  remote-plugin-protocol/
    src/{index,transport,types,manifest,invariant}.ts
    test/conformance.spec.ts              # replays the SAME conformance/ corpus
    README.md
  remote-plugin/
    src/{index,connection,transport,tools,guards,sections,subagents,invariant}.ts
    README.md
examples/remote-plugin-agent/             # runnable leaf for the keyless snapshot
  cordis.yml
  snapshots/…
```

### Structure Rationale

- **`PROTOCOL.md` + `conformance/` live in the Haskell repo and are vendored into the harness.** One home for one fact (a repo convention in `deepseek-harness/CLAUDE.md`). Both implementations are tested against the same bytes, so neither repo can drift silently. This is the single most load-bearing structural decision in the whole project — see Build Order.
- **`Rpc/` is three layers, not one.** `Frame` is pure and property-testable with no IO. `Transport` is a record of functions so the out-of-scope HTTP/WS transports are additive (a `Constraint`-carrying typeclass would leak into every signature). `Peer` owns all STM and is the only module that knows request ids exist.
- **Protocol package split on the TS side mirrors `hooks/hook-protocol`.** The wire vocabulary has no Cordis dependency, so it is testable without booting a context and reusable by a future non-plugin consumer. `hooks-claude-code` + `hook-protocol` is the shipped precedent for exactly this split.
- **`packages/remote/` as a new group** is allowed by `docs/cookbook/adding-a-package.md` ("A new group is allowed, but it is a pure container"). Putting it under `mcp/` would misname the role; `extensions/` already exists and means something else.

---

## Architectural Patterns

### Pattern 1: Own the JSON-RPC codec; do not take `json-rpc` from Hackage

**What:** Implement `Rpc/Frame.hs` + `Rpc/Transport.hs` (~250 LOC) over `aeson` + `bytestring` + `stm`, rather than depending on `jprupp/json-rpc`.

**Evidence (HIGH confidence — read from upstream source):** `json-rpc`'s encoder is

```haskell
-- Network/JSONRPC/Interface.hs:88-89
encodeConduit :: (ToJSON j, MonadLogger m) => ConduitT j ByteString m ()
encodeConduit = CL.mapM $ \m -> return . L8.toStrict $ encode m
```

It emits **no frame delimiter**. The harness's own reader (`packages/sdk/protocol/src/transport.ts`) splits strictly on `\n` and drops anything unparsed; a stream of concatenated JSON objects would buffer forever and deliver zero frames. The delimiter must be added by interposing a conduit before the sink — workable, but it means the dependency does not own the framing contract that matters.

**Additional costs, all verified:**

| Cost | Detail |
|---|---|
| Version drift | `lts-22.43` pins `json-rpc-1.0.4`; current Hackage is `1.1.3` (2026-08-18). An `extra-deps` override defeats "resolver pinned for reproducible builds". |
| Monad stack | `runJSONRPCT` demands `MonadLoggerIO m, MonadUnliftIO m`. `runPlugin :: Plugin -> IO ()` would have to wrap `runStderrLoggingT`, and every author-facing handler type inherits the constraint or needs lifting. |
| Dep weight | pulls `conduit`, `conduit-extra`, `monad-logger`, `unliftio`, `attoparsec`, `mtl`, `time` into an SDK whose value proposition is "add one dependency to write a plugin". |
| Typeclass fit | `FromRequest q` keys on a closed sum type — a *good* fit for the six fixed inbound methods, but `ToRequest`/`FromResponse` on the outbound side buy little for the one outbound method (`initialize` result, later `agent/inject`). |

**Trade-off, stated honestly:** the repo policy (`deepseek-harness/CLAUDE.md`) is "prefer maintained dependencies over hand-rolling **when they genuinely delete owned code and tests**." `json-rpc` *is* maintained. It does not clear the conditional here: after taking it you still own the framing wrapper, the cancel-token registry, the concurrent-dispatch policy, and the hostile-input rebuild — which is most of the code. Take it only if the transport-interface abstraction (Pattern 2) later needs its TCP transports for free.

**Recommendation:** own it. Record the rejection and its reason in `PROJECT.md`'s decision table so it is not relitigated.

### Pattern 2: Transport as a record of functions, Peer as the only STM owner

**What:**

```haskell
data Transport = Transport
  { transportRead  :: IO (Maybe ByteString)   -- one frame, Nothing = EOF
  , transportWrite :: ByteString -> IO ()     -- one frame; MUST be atomic
  , transportClose :: IO ()
  }

stdioTransport :: IO Transport   -- NDJSON over fd 0 / fd 1
```

`Peer` sits above it and owns every `TVar`:

```haskell
data Peer = Peer
  { peerTransport :: Transport
  , peerWriteLock :: MVar ()                              -- single-writer invariant
  , peerPending   :: TVar (Map RequestId (TMVar (Either RpcError Value)))
  , peerInflight  :: TVar (Map RequestId CancelToken)
  , peerNextId    :: TVar Word64
  , peerState     :: TVar PeerState                       -- Running | Draining | Closed
  }

newtype CancelToken = CancelToken (TVar Bool)
```

**When to use:** always. A typeclass (`class Monad m => MonadTransport m`) would propagate a constraint into every author-facing handler signature and make `Exec` polymorphic for no gain — `runPlugin` is `IO` and always will be.

**Trade-offs:** a record of functions is not mockable at the type level, so tests inject a pair of in-memory `TQueue`-backed transports. That is a feature: the same fixture drives the fake-host conformance suite.

**Non-obvious invariant — the write lock is not optional.** Concurrent request workers each write a response frame. Without an `MVar` around `transportWrite`, two `hPutStr` calls interleave and produce a corrupt line. Concurrency mistakes here are invisible until load.

### Pattern 3: One `async` per inbound request; cancellation is cooperative and never abandons

**What:** the read loop is a *router*, never a *handler*. It reads a frame, classifies it, and returns to reading immediately.

```haskell
serve :: Peer -> HandlerTable -> IO ()
serve peer table = loop where
  loop = transportRead (peerTransport peer) >>= \case
    Nothing   -> drainAndExit peer                       -- EOF
    Just line -> case decodeFrame line of
      Left  _                     -> loop                -- malformed: ignore (host-side policy)
      Right (FrameNotif "$/cancel" p) -> cancelInflight peer p    >> loop
      Right (FrameNotif m p)          -> dispatchNotif table m p  >> loop
      Right (FrameReq rid m p)        -> spawnHandler peer table rid m p >> loop
      Right (FrameResp rid r)         -> resolvePending peer rid r >> loop
```

**Why this ordering is load-bearing:** `$/cancel` arrives *while* a tool handler is running. If the loop blocked on the handler, the cancel notification could not be read, and cancellation would be structurally impossible. **The async dispatcher must exist before cancellation can be built** — it cannot be retrofitted. This is the single hardest ordering constraint inside the Haskell phase.

**Cancellation semantics — mirror the harness, do not invent:**

`packages/core/tools/src/index.ts` documents its own contract: the registry *"does not abandon this promise, but it cannot hard-kill same-process code."* Mirror it exactly:

1. `$/cancel {id}` flips the request's `CancelToken` `TVar Bool`.
2. `Exec.cancelled :: STM Bool` reads it. A cooperative handler polls it or blocks on `atomically (readTVar t >>= check)`.
3. The SDK **does not** `Async.cancel` the worker. The response frame goes out when the handler settles, whatever it decides.
4. Host side: `JsonRpcLineTransport.request(method, params, signal)` already deletes its pending entry on abort, so a late response is discarded harmlessly. The harness has already materialized an `ABORTED` result for the model.

`Async.cancel` escalation after a grace period is a v1.1 config field, not a default: throwing an async exception into arbitrary author code that holds a file handle or a database connection is a correctness hazard the SDK cannot reason about.

**Anti-pattern this replaces:** `race (waitCancel token) (runHandler …)`. It returns promptly, which feels better, but orphans the handler thread with no owner and no disposal — a leak the author cannot see.

### Pattern 4: `Plugin` as a record of existentials with a phantom-free interface

**What:**

```haskell
data Tool where
  Tool :: (HasSchema a, FromJSON a, HasSchema v, ToJSON v) =>
    { toolName        :: Text
    , toolDescription :: Text
    , toolExecute     :: a -> Exec -> IO v
    , toolRender      :: a -> v -> [ContentBlock]     -- pure, total, runs HERE
    , toolTimeoutMs   :: Maybe Int
    , toolConcurrencySafe :: Bool
    , toolPresentation :: PresentationIntent          -- declarative; see Pattern 6
    } -> Tool

data Plugin = Plugin
  { pluginName      :: Text
  , pluginVersion   :: Text
  , pluginTools     :: [Tool]
  , pluginGuards    :: [Guard]
  , pluginSections  :: [Section]
  , pluginSubagents :: [Subagent]
  }
```

**When to use:** whenever the author-facing API must be a heterogeneous list of differently-typed handlers. The existential erases `a` and `v` at the list boundary while `HasSchema`/`FromJSON`/`ToJSON` dictionaries ride along, so the manifest projection and the dispatcher can still derive schemas and decode args.

**Trade-offs:** requires `GADTs`/`ExistentialQuantification` + `RankNTypes`; error messages at the definition site are worse than for a monomorphic record. The alternative — forcing every tool to `Value -> IO Value` — throws away the whole point of the SDK (typed args, derived schemas).

**The manifest is a pure projection.** `manifestOf :: Plugin -> Manifest` does no IO. That is what makes `--dump-manifest` a one-liner, and what makes the manifest golden-testable without a host.

### Pattern 5: Derive schemas into the harness's *enforced subset* — `autodocodec-schema` will not do

**What:** an owned ADT that is structurally incapable of producing an unsupported keyword.

```haskell
data DshSchema
  = SAny                                    -- {}  (annotation-only)
  | SNull | SBool | SString | SNumber | SInteger
  | SObject { sProps :: [(Text, DshSchema)], sRequired :: [Text], sClosed :: Bool }
  | SArray  { sItems :: Maybe DshSchema }
  | SEnum   { sType :: ScalarType, sValues :: [Scalar] }
  | SConst  { sType :: ScalarType, sValue :: Scalar }
  | SOneOf  [DshSchema]                     -- >= 2 branches, enforced by smart constructor
  | SAnnotated Annotations DshSchema        -- description/title/default/examples only

class HasSchema a where
  schemaOf :: Proxy a -> DshSchema
  default schemaOf :: (Generic a, GHasSchema (Rep a)) => Proxy a -> DshSchema
```

**Why (HIGH confidence — this is a hard gate, read from source):** `ToolRuntime.register()` in `packages/core/tools/src/index.ts` calls `assertSupportedJsonSchema(output.schema)` and **throws** on anything outside the subset declared in `packages/core/tools/src/json-schema.ts`:

> accepts any JSON root, an annotation-only schema for unconstrained JSON, one scalar `type`, object `properties`/`required`/**boolean** `additionalProperties`, array `items`, type-correct scalar `enum`/`const`, and exact-one `oneOf`. Unsupported or misplaced keywords reject rather than being accepted without enforcement.

`autodocodec-schema-0.1.0.4` (the version in `lts-22.43`) exports a `JSONSchema` whose constructors include `MapSchema`, `AnyOfSchema`, `RefSchema`, `WithDefSchema`, `CommentSchema`, and `NumberSchema` with bounds. Those serialize to `additionalProperties: <schema>`, `anyOf`, `$ref`, `$defs`, and `minimum`/`maximum` — **every one of which the harness rejects.** A `Map Text v` field or any recursive/named type in an autodocodec codec produces a schema the harness refuses to register. The failure is at plugin activation, loud, and unfixable without replacing the generator.

**Recommendation:** own `DshSchema`. Port `assertSupportedJsonSchema`'s rules as a smart-constructor invariant so an unsupported schema is *unrepresentable*, and additionally golden-test the emitted JSON. `autodocodec` remains a reasonable choice for `ToJSON`/`FromJSON` if the author wants it, but the SDK must not route schema generation through `autodocodec-schema`.

**Corollary:** the SDK also owns an inbound validator mirroring `validateJsonSchemaValue`. Model-produced arguments are hostile input (`PROJECT.md` constraint); validating against the *same* subset semantics the harness advertises to the model is what makes "invalid args" a `-32005` with a useful message instead of an aeson parse failure.

### Pattern 6: Three harness callbacks are **synchronous** — plan around them, do not fight them

This is the finding most likely to reshape the roadmap. Three contribution points the project wants are typed as synchronous functions. A remote process cannot serve a synchronous call.

| Harness callback | Signature (verbatim) | Consequence |
|---|---|---|
| `ToolGuard` | `(execution: Readonly<ToolExecution>) => string \| undefined` | **`ctx.tools.guard()` is unusable for a remote guard.** Use the `tools/pre-execute` waterfall (async) instead. `PROJECT.md` already names the right seam; this confirms the alternative is closed, not merely less convenient. |
| `PromptSection.text` | `string \| ((context: AssembleContext) => string)` | A section provider **cannot** round-trip at assembly time. |
| `ToolOutputDefinition.render` | `render(args, value): ContentBlock[]` — pure, sync | The bridge cannot call the Haskell `render` at projection time. |
| `presentCall` / `presentResult` | pure functions of `args`, called during live streaming **and** log replay | The bridge cannot round-trip for UI intent either. |

**Resolutions:**

**(a) Guards → `tools/pre-execute`.** Direct translation of `hooks-claude-code`:

```ts
ctx.on('tools/pre-execute', async (exec, next): Promise<PreToolDecision> => {
  const decision = await peer.request('guard/decide', {
    callId: exec.callId, tool: exec.name, arguments: exec.arguments,
  }, exec.signal)
  if (decision.kind === 'deny')    return { kind: 'deny', reason: decision.reason }
  if (decision.kind === 'ask')     return { kind: 'ask', reason: decision.reason }
  return next()            // Allow === delegate. Never `return { kind: 'allow' }`.
})
```

`Allow` **must** compile to `next()`, not to `{ kind: 'allow' }`. Returning a value short-circuits the waterfall and silently disables every guard registered after this one — including the harness's own approval policy. `docs/cordis-primer.md`: *"Call `next()` to delegate the possibly wrapped result to the next service; return without `next()` to short-circuit."*

Note the asymmetry this creates: `Rewrite Value` from `PROJECT.md`'s `Guard` sum **has no counterpart in `PreToolDecision`**, whose comment states input rewriting is *"excluded because arguments are already logged and presented."* `Rewrite` cannot be implemented on this seam. Drop it from v1 or reroute it through `tools/execute` (an around-dispatch waterfall) with the logging consequence documented.

**(b) Sections → static text in the manifest, refreshed by push.** v1: the manifest carries the section text; the bridge registers it with `ctx.systemPrompt.section({ name, order, text })` and never round-trips. A plugin→host `section/changed { name, text }` notification lets the bridge dispose and re-register (which emits `system-prompt/change` for free). This removes a subprocess round trip from the per-step prompt-assembly hot path entirely.

If genuinely dynamic sections are needed later, the escape hatch is the `system-prompt/assemble` **async waterfall** (`@mode waterfall`, carries `AssembleContext.signal`) — push a rendered section into `assembly.sections` after an awaited `section/render`. Defer to v1.1 and document the per-step latency cost.

**(c) Render → return content with the value.** Copy the MCP bridge exactly. The canonical value is an envelope; `render` is a local pure projection out of it.

```ts
output: {
  schema: { type: 'object',
            properties: { value: <plugin's declared output schema>,
                          content: { type: 'array', items: {} } },
            required: ['value', 'content'], additionalProperties: false },
  render: (_args, v) => (v as RemoteResult).content,   // pure, sync, local
}
```

The Haskell `render :: a -> v -> [ContentBlock]` runs **in the plugin process at execute time** and its output rides back in the same response. Purity and totality are preserved where they matter (a pure projection of the stored value); `mcp-client`'s `McpResult` is the shipped precedent.

**(d) UI intent must be declarative.** `PresentationIntent` in the manifest — `{ mode: 'generic' | 'terminal' | 'diff', title?: <template>, locations?: [<JSON pointer into args>] }` — which the bridge compiles into local pure `presentCall`/`presentResult` closures. `deepseek-harness/CLAUDE.md` requires this be *"decided up front"*, so a declarative manifest field is the correct expression, not a limitation.

### Pattern 7: Generation supervisor, not a connection

**What:** `connection.ts` from `mcp-client` is the template and should be followed closely rather than reinvented. Its structure encodes four hard-won invariants:

1. **Generations, not reconnects.** Each spawn attempt is a `generation`; `isCurrent(generation)` guards every callback so a stale child's close/error cannot touch live state.
2. **Serialized registration swaps.** A `syncChain: Promise<void>` serializes all registration swaps so two never interleave their dispose-previous/register-next pair.
3. **Two-phase swap.** Phase 1 fetches and *builds* the whole next generation without touching the registry; any failure leaves the previous generation registered untouched. Phase 2 disposes then registers, rolling back on conflict so the model sees all-or-nothing.
4. **Bounded restart budget with a stability window.** A child that stays up past `maxDelayMs` resets the budget; a crash-looper exhausts it and unregisters. Exhaustion is terminal until HMR.

For this bridge, phase 1 = `initialize` + manifest validation; phase 2 = registering tools **and** guards **and** sections **and** subagents. All four must be in one rollback unit — a plugin whose tools registered but whose guards did not is a security regression, not a degraded mode.

**HMR** needs no special code. Cordis's loader disposes the old plugin fiber and applies a new one when the config row changes; `ctx.effect(() => () => connection.dispose(), 'remote-plugin.connection')` is the whole story. Restart-on-*binary*-change is different and needs a watcher — make it a `watch: boolean` `Config` field or omit it (a hardcoded watcher would violate the no-hardcoded-tunables rule).

### Pattern 8: Spawn through `ctx.subprocess`, not `node:child_process`

**What:**

```ts
const exe = await ctx.subprocess.resolveExecutable(config.command, env, signal)
const handle = ctx.subprocess.spawn({
  argv: [exe, ...config.args], cwd: config.cwd,
  env: { ...scrubbedParentEnv(), ...config.env },
  stdio: { stdin: 'pipe', stdout: 'pipe', stderr: 'pipe' },
  // grace, signal per the seam's spec
})
// handle.stdin: Writable | undefined, handle.stdout / handle.stderr: Readable | undefined
```

**Why this beats the MCP precedent:** `mcp-client/transport.ts` delegates spawning to the MCP SDK and can only share the env-scrub definition. `SubprocessHandle` documents `stdin: 'pipe'` as *"exposes `SubprocessHandle.stdin` for the caller's ongoing protocol writes"* — this seam was designed for exactly this use. Going through it buys, for free: sandbox confinement (`ctx.sandbox` consumers wrap argv before spawning), remote execution worlds (`packages/e2b`), process-tree cleanup, and `resolveExecutable`'s loud rejection of ambiguous relative paths. `docs/architecture.md`: *"Filesystem and subprocess providers share one execution world, so pointing them at a remote sandbox moves Bash, PTY, and LSP with them."* A Haskell plugin binary should move with them too.

`stderr` must be piped and forwarded to `ctx.logger` — the child's diagnostics are otherwise invisible, and the SDK reserves stdout for frames.

### Pattern 9: fd hygiene in `runPlugin` (Haskell-side defensive pattern)

The most common way a stdio protocol plugin fails in production is an author's stray `print`. Prevent it structurally in `runPlugin`:

```haskell
runPlugin :: Plugin -> IO ()
runPlugin plugin = do
  frames <- hDuplicate stdout          -- private handle for protocol frames
  hDuplicateTo stderr stdout           -- any author putStrLn now goes to stderr
  hSetBuffering frames (BlockBuffering Nothing)   -- explicit hFlush per frame
  hSetBinaryMode frames True
  hSetEncoding  frames utf8
  hSetNewlineMode frames noNewlineTranslation    -- Windows: no \n -> \r\n
  hSetBuffering stdin  (BlockBuffering Nothing)
  hSetEncoding  stdin  utf8
  hSetNewlineMode stdin universalNewlineMode
  …
```

**Shutdown, three paths, all must exit 0:**

| Trigger | Handling |
|---|---|
| stdin EOF | Stop accepting new requests, move `peerState` to `Draining`, let in-flight settle under a bounded wait, flush, exit 0. |
| `shutdown` request | Reply `{}` first, flush, then the same drain. Ordering matters: the reply must reach the host before the pipe closes. |
| `EPIPE` on write | GHC's RTS ignores `SIGPIPE`, so a write to a dead pipe raises `isResourceVanishedError`. Catch it, abandon the frame, exit 0 — the host is already gone, and a nonzero exit makes the supervisor log a spurious crash. |

---

## Data Flow

### Flow 1 — Startup and handshake

```
Cordis loader mounts dsh-remote-plugin(config)
  │
  ├─ apply(ctx, config)  [async — Cordis awaits activation]
  │    resolveRestartPolicy(config)    ← fail loud on bad config, before any effect
  │    ctx.effect(reserve pluginName namespace)
  │    startConnection(ctx, config, policy)
  │        └─ generation 1:
  │             ctx.subprocess.resolveExecutable(command)
  │             ctx.subprocess.spawn({stdin:'pipe', stdout:'pipe', stderr:'pipe'})
  │             new JsonRpcLineTransport(handle.stdout, handle.stdin).start()
  │             handle.stderr.pipe → ctx.logger.info
  │             │
  │  HOST ─────┼──▶  {"jsonrpc":"2.0","id":"req_…","method":"initialize",
  │            │       "params":{"protocolVersion":1,"hostInfo":{…},"cwd":"…"}}
  │            │
  │            │      ┌── PLUGIN: runPlugin already serving; manifestOf plugin
  │  HOST ◀────┼──────┘  {"jsonrpc":"2.0","id":"req_…","result":{ <manifest> }}
  │            │
  │            ├─ validateManifest(raw)  ← hostile rebuild; version mismatch = fail loud
  │            └─ PHASE 2 (one rollback unit):
  │                 for t in manifest.tools     → ctx.tools.register(toDefinition(t))
  │                 for g in manifest.guards    → ctx.on('tools/pre-execute', …)
  │                 for s in manifest.sections  → ctx.systemPrompt.section(s)
  │                 for a in manifest.subagents → ctx.subagents.registerProvider(a)
  │
  └─ await connection.ready → activation completes; tools visible to next assembly
```

`initialize` is **host-initiated**. This contradicts `PROJECT.md`'s current wording ("plugin→harness requests (`initialize` handshake…)") and the change is deliberate: host-first matches MCP, LSP, ACP, and the harness's own SDK protocol (where the client sends `initialize` to the server); it lets the host pass `protocolVersion`, `hostInfo`, and `cwd` that the plugin may need; and it gives the supervisor a clean timeout ("no manifest in N ms → fail activation"). `--dump-manifest` still prints exactly the `result` payload, so the GHC-free manifest snapshot is unaffected.

### Flow 2 — One tool call, end to end

```
model emits tool-call ──▶ agent-loop ──▶ ctx.tools.execute(input)

 1. ToolRuntime materializes + deep-freezes args, mints token, resolves rootCallId
 2. waterfall 'tools/pre-execute' ─────┐
 3.   … other listeners (approval policy, hooks bridges) …
 4.   remote-plugin guard listener  ───┼─▶ [see Flow 3]; Allow ⇒ next()
 5. monotonic ctx.tools.guard() chain  │  (local, sync — remote plugins never here)
 6. waterfall 'tools/execute'          │  (timeout policy wraps exec.signal)
 7.   ToolDefinition.execute(args, exec) ── the bridge closure:
        peer.request('tool/execute',
          { callId, tool: <manifest name>, arguments: args },
          exec.signal)                        ← signal wired into the transport
                    │
   ┌────────────────┼────────────────────────────────────────────────┐
   │ PLUGIN         ▼                                                │
   │  router reads frame, returns to reading IMMEDIATELY             │
   │  async worker:                                                  │
   │    register CancelToken under request id                        │
   │    validateAgainst (schemaOf @a) argsValue   → [] or -32005     │
   │    fromJSON args                             → a                │
   │    v <- toolExecute a exec                   ← Exec.cancelled    │
   │    blocks = toolRender a v                   ← pure, total, HERE │
   │    reply { "value": toJSON v, "content": blocks }                │
   │    unregister CancelToken                                       │
   └────────────────┬────────────────────────────────────────────────┘
                    ▼
 8.   bridge receives result; returns it as the canonical value
 9. ToolRuntime validates value against output.schema (the envelope schema)
10. definition.output.render(args, value) → value.content    ← pure, sync, local
11. waterfall 'tools/post-execute' → PostToolDecision
12. finalizeContent → lossless materialization → deep freeze
13. emit 'tools/result'; append durable tool/result session event
14. agent-loop appends the result; next step or turn/end
```

**Error mapping at step 7.** A `-32004 TOOL_FAILED` error frame makes the bridge closure `throw`, which the `ToolRuntime` catch path turns into an `isError` result the model can read and learn from — precisely `mcp-client`'s `isError: true → throw` behavior. A `-32601`/`-32603` is a protocol bug: also surfaced as `isError`, but additionally logged at `error` level so it is distinguishable from an honest tool failure.

### Flow 3 — One guard decision

```
 ┌ 'tools/pre-execute' waterfall reaches the remote-plugin listener
 │
 │  guards from the manifest are filtered locally by their declared
 │  `match.tools` glob — a guard that does not match never crosses the wire
 │  (no round trip on every tool call in the process)
 │
 ├─ no matching guard ────────────────────────────▶ return next()          [0 frames]
 │
 └─ matching guard:
      HOST ──▶ {"jsonrpc":"2.0","id":"req_7","method":"guard/decide",
                 "params":{"guard":"no-rm-rf","callId":"call_1",
                           "tool":"bash","arguments":{"command":"rm -rf /"}}}

      PLUGIN: async worker → guardDecide guard req  →  Deny "refusing rm -rf /"

      HOST ◀── {"jsonrpc":"2.0","id":"req_7",
                 "result":{"kind":"deny","reason":"refusing rm -rf /"}}
      │
      ├─ kind = "allow"  ─▶ return next()      ← DELEGATE. never { kind: 'allow' }
      ├─ kind = "deny"   ─▶ return { kind: 'deny', reason }        [short-circuit]
      └─ kind = "ask"    ─▶ return { kind: 'ask', reason }         [short-circuit]
                                │
                                └─ ToolRuntime: 'ask' runs only if an approval
                                   service returns allowed-once; otherwise denies.
                                   A deployment with no approval service turns
                                   every 'ask' into a denial — document this.
```

Short-circuiting on deny/ask is correct and intended: `docs/cordis-primer.md` — *"For single-decision events, short-circuiting is the design. A policy listener can return without `next()` when it owns the decision."* Allowing must delegate, because the listener is only annotating.

If the plugin process is down (backoff, budget exhausted), the guard listener must **fail closed**: return `{ kind: 'deny', reason: … }`, never `next()`. A security control that evaporates when its process crashes is worse than no control. This is the opposite of the tool-registration policy (where an unreachable plugin simply unregisters its tools) and the asymmetry is deliberate — record it in the Agent Note.

### Flow 4 — Cancellation

```
user hits ESC / turn aborts / tool-call-timeout policy fires
   │
   └─ exec.signal aborts
        │
        ├─ JsonRpcLineTransport.request(…, signal): deletes its pending entry,
        │  rejects with the abort reason. The harness materializes ABORTED.
        │
        └─ bridge ALSO sends: {"jsonrpc":"2.0","method":"$/cancel",
                                "params":{"id":"req_7"}}          [notification]
                 │
                 ▼
             PLUGIN router (still reading — the handler is on its own async)
                 atomically $ writeTVar (tokenOf req_7) True
                 │
                 └─ handler observes Exec.cancelled, returns early
                    → response frame written; HOST discards it (no pending entry)
                    → CancelToken unregistered
```

The bridge does not wait for anything after sending `$/cancel`. The notification is advisory; correctness on the harness side is already guaranteed by the aborted pending entry.

### Flow 5 — Teardown / HMR

```
config row changes, plugin unloads, or process exits
   │
   └─ Cordis unwinds effects in reverse registration order:
        subagent providers unregistered
        prompt sections unregistered           → emits system-prompt/change
        tools/pre-execute listeners removed
        tool registrations disposed            → emits tools/change
        connection.dispose():
          stop the restart timer
          send `shutdown` request (bounded wait)
          close stdin  → child sees EOF → drains → exits 0
          await process close within GRACE; escalate to the seam's kill on timeout
          await settling + syncChain (quiesce, do not merely request it)
          dispose any remaining registrations
        namespace reservation released
```

`connection.dispose()` must **quiesce, not merely request**: `mcp-client` awaits both the in-flight attempt (`settling`) and the registration queue (`syncChain`) before disposing, because an attempt in flight enqueues its sync before it settles. Skipping this leaks registrations across an HMR cycle.

---

## Wire Protocol

`protocolVersion` is an integer, starts at `1`, and is compared for **exact equality** on both sides. `PROJECT.md`'s pre-1.0 stance forbids compatibility shims; mismatch is a loud failure at activation with both versions in the message.

### Methods

| Direction | Method | Kind | Params | Result |
|---|---|---|---|---|
| host → plugin | `initialize` | request | `{ protocolVersion, hostInfo:{name,version}, cwd }` | the manifest |
| host → plugin | `tool/execute` | request | `{ callId, tool, arguments }` | `{ value, content }` |
| host → plugin | `guard/decide` | request | `{ guard, callId, tool, arguments }` | `{ kind:"allow"\|"deny"\|"ask", reason? }` |
| host → plugin | `subagent/run` | request | `{ runId, subagent, prompt, cwd }` | `{ stopReason, lastAssistantMessage? }` |
| host → plugin | `shutdown` | request | `{}` | `{}` |
| host → plugin | `$/cancel` | notification | `{ id }` | — |
| plugin → host | `section/changed` | notification | `{ name, text }` | — |
| plugin → host | `agent/inject` | request | *(v2)* | *(v2)* |

`section/render` is **deliberately absent** from v1 (Pattern 6b). `$/`-prefixed methods are protocol-level and follow LSP convention; every domain method uses the slash form, matching `session/prompt` in `packages/sdk/protocol`.

### Handshake manifest

```jsonc
{
  "protocolVersion": 1,
  "pluginInfo": { "name": "echo", "version": "0.1.0" },
  "tools": [{
    "name": "echo",                          // must satisfy /^[A-Za-z0-9_-]{1,64}$/
    "description": "Echo text back.",
    "parameters": { "type": "object", "properties": {"text": {"type":"string"}},
                    "required": ["text"], "additionalProperties": false },
    "output":     { "schema": { "type": "object", "properties": {"echoed":{"type":"string"}},
                                "required": ["echoed"], "additionalProperties": false } },
    "timeoutMs": 30000,                      // optional
    "concurrencySafe": true,                 // optional, default false
    "presentation": { "mode": "generic" }    // declarative UI intent
  }],
  "guards":    [{ "id": "no-rm-rf", "match": { "tools": ["bash", "shell_*"] } }],
  "sections":  [{ "name": "echo:guidance", "order": 150, "text": "…" }],
  "subagents": [{ "name": "haskell-reviewer",
                  "capabilities": {},
                  "inheritsParentContext": false }]
}
```

Every field is rebuilt, not cast, by `manifest.ts`. Reject (do not repair) on: version mismatch, a tool name outside the DeepSeek function-name contract (≤64 chars, `[A-Za-z0-9_-]`), a schema outside `assertSupportedJsonSchema`, duplicate names, a non-finite section `order`, or an unknown discriminant. `mcp-client` hashes lossy names because MCP servers are third-party; here the plugin author owns the name and can fix it, so **fail loud instead of normalizing**. Offer `Config.toolNamePrefix?: string` for collision management; do not prefix by default.

### Error codes

| Code | Name | Meaning | Bridge behavior |
|---|---|---|---|
| −32700 | `PARSE_ERROR` | malformed JSON | log; drop frame |
| −32600 | `INVALID_REQUEST` | not a JSON-RPC 2.0 frame | log; drop frame |
| −32601 | `METHOD_NOT_FOUND` | unknown method | log at `error`; surface `isError` |
| −32602 | `INVALID_PARAMS` | params fail the method's own record | log at `error`; surface `isError` |
| −32603 | `INTERNAL_ERROR` | unhandled exception in the SDK | log at `error`; surface `isError` |
| −32001 | `PROTOCOL_VERSION_MISMATCH` | handshake versions differ | **fail activation loud** |
| −32002 | `UNKNOWN_CONTRIBUTION` | tool/guard/section/subagent id not in the manifest | log at `error`; indicates a stale generation |
| −32003 | `CANCELLED` | handler observed `Exec.cancelled` | discarded (pending entry already gone) |
| −32004 | `TOOL_FAILED` | the author's handler failed — a **domain** failure | `throw` inside `execute` → `isError` result the model reads |
| −32005 | `INVALID_ARGUMENTS` | model args failed the derived schema | `throw` → `isError`; message names the violating path |
| −32006 | `SHUTTING_DOWN` | request arrived after drain began | log at `warn`; treat as connection loss |

The −32004 / −32603 split is the load-bearing one: a tool that legitimately failed and a protocol bug both become `isError` for the model, but only the second is an operator-actionable log line. Putting domain failure in the `error` object (rather than an `isError` flag inside `result`, MCP's approach) maps 1:1 onto the harness's throw-for-error convention and avoids MCP's known wart.

---

## Build Order

### Dependency graph

```
P0  PROTOCOL.md + conformance/ corpus        [no code — unblocks BOTH repos]
     │
     ├────────────────── Haskell repo ──────────────────┐   ┌── deepseek-harness ──┐
     │                                                  │   │                      │
  P1 Rpc/{Frame,Transport,Peer}          P2 Schema + Validate   P6 protocol package
     │  (in-memory transport pair)          (independent)        (fake plugin script,
     │                                        │                   same corpus)
     └───────────────┬────────────────────────┘                        │
                  P3 Types + Content + manifest projection       P7 remote-plugin:
                     │                                              spawn + handshake
                  P4 Dispatch + runPlugin + --dump-manifest            + tools
                     + EOF/EPIPE shutdown + $/cancel                    │
                     │                                            P8 guards, sections,
                  P5 examples/echo + fake-host conformance suite      subagents
                     │  ◀── HASKELL SIDE PROVABLY DONE, NO TS ──┘        │
                     └──────────────────────┬─────────────────────────────┘
                                         P9 e2e: example leaf + profile row
                                            + keyless snapshot
```

### What must exist before what

| Phase | Blocked by | Blocks | Why the order is forced |
|---|---|---|---|
| **P0** — spec + corpus | — | everything | Both implementations test against the same bytes. Without it, the repos drift and integration is a debugging session instead of a merge. |
| **P1** — Frame/Transport/Peer | P0 | P4 | The STM correlation registry cannot be added after the dispatcher exists without rewriting it. |
| **P2** — Schema + Validate | P0 | P3 | The manifest cannot be projected without `HasSchema`. Fully parallel with P1 — no shared module. |
| **P3** — Types + manifest | P2 | P4, P5 | `Tool`'s existential needs the `HasSchema` dictionary in scope. |
| **P4** — Dispatch + `runPlugin` | P1, P3 | P5 | **The async-per-request router must precede cancellation.** A synchronous handler loop cannot read `$/cancel` while a handler runs; retrofitting means rewriting the loop. |
| **P5** — echo + fake host | P4 | P9 | The gate that says "Haskell is correct". |
| **P6** — TS protocol package | **P0 only** | P7 | Fully parallel with P1–P5. Its fake plugin is a ~50-line Node script replaying `conformance/*/plugin.jsonl`. |
| **P7** — bridge: spawn + tools | P6 | P8 | Tools are the smallest end-to-end contribution; the supervisor lifecycle is proven once here and reused. |
| **P8** — guards, sections, subagents | P7 | P9 | Each adds one registration kind to the existing rollback unit. Guards first (highest value, hardest semantics), sections second (trivial), subagents last (largest surface). |
| **P9** — e2e snapshot | P5, P8 | — | Cross-repo. See the CI hazard below. |

### The critical parallelism

**P0 is the whole roadmap's leverage point.** A frozen wire spec plus a committed frame corpus makes P1–P5 and P6–P8 fully independent work streams that meet only at P9. Writing the spec after starting either implementation forfeits this and serializes ~everything.

### CI hazard at P9 — plan for it in the roadmap

`deepseek-harness` CI has no GHC and should not acquire one. Three viable resolutions, in preference order:

1. **Two e2e tiers.** Harness CI runs the snapshot against a **TypeScript fixture plugin** that replays the corpus (proves the bridge, no GHC). The Haskell repo runs a real `dsh` against the real `echo` binary in its own CI (proves the binary, has GHC). Neither repo needs the other's toolchain. This is also the only arrangement in which the harness PR can merge under its own gates, which `PROJECT.md` flags as a cross-repo constraint.
2. Add a GHC setup step to one snapshot job. Slow, and couples harness CI to a Stack resolver.
3. Commit a prebuilt `echo` binary. Not portable across the macOS/Linux fixture-replay requirement in `docs/testing.md`.

`--dump-manifest` covers a third, cheaper tier: a golden test of the manifest JSON that needs neither GHC nor a running host.

---

## Testing Architecture

Three fakes, one corpus. This is what makes "test the Haskell side before the bridge exists" real rather than aspirational.

| Fake | Lives in | Stands in for | Drives |
|---|---|---|---|
| **In-memory transport pair** | Haskell `test/` | the pipe | `Frame`/`Peer` unit + QuickCheck roundtrip; no process, no fds |
| **Fake host** | Haskell `test/…/ConformanceSpec.hs` | the whole bridge | feeds `conformance/*/host.jsonl` into `runPlugin`'s transport, asserts output equals `plugin.jsonl` modulo id normalization |
| **Fake plugin** | TS `remote-plugin-protocol/test/` | the Haskell binary | a Node script replaying `conformance/*/plugin.jsonl`; lets the bridge and its snapshot run with zero GHC |

**Normalization is mandatory in both directions.** Request ids are freshly minted per run. The harness's own snapshot kit already solves this — `normalizeStdout` maps *"JSON-RPC ids → first-seen sequence"*. Adopt the same rule in the corpus so both implementations compare against identical normalized bytes.

Haskell test layers, mapped to the phases:

| Layer | Tool | Covers |
|---|---|---|
| Property | `QuickCheck-2.14.3` | `Frame` encode/decode roundtrip; `DshSchema → Value → DshSchema` |
| Golden | `hspec-golden-0.2.2.0` | derived schemas per type; the full `--dump-manifest` output |
| Conformance | `hspec` + fake host | every corpus scenario, including cancel and EOF |
| Negative | `QuickCheck` | hostile args: every generated `Value` either validates or produces a violation list; never a crash |

---

## Anti-Patterns

### Anti-Pattern 1: Returning `{ kind: 'allow' }` from the guard listener

**What people do:** map the Haskell `Allow` to `PreToolDecision.allow` because the type exists.
**Why it's wrong:** `tools/pre-execute` is around-middleware. Returning any value short-circuits the waterfall, silently disabling every listener registered after this one — the approval policy, hook bridges, and the harness's own sandbox gate. Nothing fails; permissions just quietly stop applying.
**Do this instead:** `return next()`. `hooks-claude-code` does exactly this and comments the reason.

### Anti-Pattern 2: A synchronous handler loop

**What people do:** read a frame, run the handler, write the response, repeat.
**Why it's wrong:** `$/cancel` can never be read while a handler runs, so cancellation is structurally impossible; and two concurrent tool calls serialize behind each other, which the harness's parallel-tool-call scheduler will expose immediately.
**Do this instead:** the router spawns one `async` per request and returns to reading. Build it this way in P4 — it is not retrofittable.

### Anti-Pattern 3: Shipping `autodocodec-schema` output as the tool's `output.schema`

**What people do:** `jsonSchemaViaCodec @MyResult` and hand the `Value` to the manifest.
**Why it's wrong:** `MapSchema` → `additionalProperties: <schema>`, `AnyOfSchema` → `anyOf`, `WithDefSchema`/`RefSchema` → `$defs`/`$ref`, `NumberSchema` bounds → `minimum`/`maximum`. `ToolRuntime.register()` calls `assertSupportedJsonSchema` and **throws** on every one. The plugin fails to activate the moment a tool returns a `Map` or a sum type.
**Do this instead:** own `DshSchema` with smart constructors that make an unsupported schema unrepresentable.

### Anti-Pattern 4: Round-tripping to the plugin during prompt assembly

**What people do:** implement `section/render` and call it from the `PromptSection.text` provider.
**Why it's wrong:** `PromptSection.text` is `string | ((context) => string)` — **synchronous**. There is no `await` to put the round trip in. Reaching for `system-prompt/assemble` instead works but puts a subprocess round trip on *every step* of *every turn*.
**Do this instead:** static text in the manifest plus a `section/changed` push notification. Zero frames on the hot path.

### Anti-Pattern 5: A guard that fails open when the plugin is down

**What people do:** `catch → next()`, matching how unreachable tools simply unregister.
**Why it's wrong:** a security control that disappears when its process crashes is worse than no control, because the deployment believes it is protected.
**Do this instead:** fail closed — `{ kind: 'deny', reason: 'remote guard unavailable' }`. Accept the asymmetry with tool registration and document it in the PR's Agent Note.

### Anti-Pattern 6: Writing frames without a lock

**What people do:** each request worker calls `hPutStr frames …` directly.
**Why it's wrong:** concurrent workers interleave bytes mid-line and produce corrupt frames. The harness reader silently drops malformed lines, so the symptom is a hung request, not an error — under load only.
**Do this instead:** one `MVar`-guarded writer in `Peer`; nothing else touches the handle.

### Anti-Pattern 7: Partial registration on handshake failure

**What people do:** register tools as they are validated, then fail on a bad section.
**Why it's wrong:** the model sees a plugin whose tools work but whose guards never registered.
**Do this instead:** `mcp-client`'s two-phase swap — build all four contribution kinds first, register them as one rollback unit, roll back on any conflict.

---

## Scaling Considerations

"Scale" here is contributions and concurrency, not users.

| Scale | Adjustments |
|---|---|
| 1 plugin, 1–5 tools | Nothing. One spawn, one manifest, static sections. |
| 1 plugin, 20+ tools | Watch the prompt budget, not the wire: every tool schema is in every request. The manifest is fetched once, so wire cost is flat. Use `ToolRestriction` per agent scope. |
| Several plugin processes | One `dsh-remote-plugin` row per process in `cordis.yml`, mirroring `mcp-client`'s one-instance-per-server model. `pluginName` namespace reservation (a `WeakMap` keyed on `ctx.root`) makes duplicates fail loud at load. |
| High tool concurrency | The harness runs concurrency-safe sibling calls in parallel. The plugin must actually be concurrent (Pattern 3) and each `Tool` must declare `concurrencySafe` honestly — the harness treats anything but `true` as exclusive. |
| Large results | Frames are single lines. A multi-MB result is one enormous line; both readers accumulate it in memory. Add a `Config.maxFrameBytes` and reject beyond it. The harness has a spill policy (`packages/spill`) for oversized tool content — route through it rather than growing frames. |

### First bottlenecks, in the order they will actually bite

1. **A dynamic section round trip per step.** Avoided by design (Pattern 6b). If it is ever added, it is the first thing to profile.
2. **Serialized dispatch** if Pattern 3 is not followed.
3. **Frame size** on tool results that embed file contents.

---

## Integration Points

### Cordis extension points this bridge touches

| Seam | API | Dispatch | Notes |
|---|---|---|---|
| `ctx.tools` | `register(ToolDefinition): () => void` | — | `assertSupportedJsonSchema(output.schema)` at register; `run_code` is reserved; duplicates throw |
| `tools/pre-execute` | `ctx.on(…, (exec, next) => …)` | **waterfall** | must `next()` to allow; scope-filtered per agent |
| `ctx.tools.guard()` | `(exec) => string \| undefined` | — | **synchronous — unusable remotely** |
| `ctx.systemPrompt` | `section(PromptSection): () => void` | — | `text` provider is **synchronous** |
| `system-prompt/assemble` | `ctx.on(…, (assembly, context, next) => …)` | **waterfall** | the async escape hatch for dynamic sections (v1.1) |
| `ctx.subagents` | `registerProvider(SubagentProvider): () => void` | — | `start(request): Promise<SubagentRun>`; `capabilities` are validated by the service before `start` |
| `ctx.subprocess` | `resolveExecutable()`, `spawn(spec): SubprocessHandle` | — | `stdin:'pipe'` is documented for "ongoing protocol writes" |
| `ctx.logger` | `info/warn/error` | — | destination for the child's stderr |

### Internal boundaries

| Boundary | Communication | Considerations |
|---|---|---|
| author code ↔ SDK | `Plugin` record; `Exec` handle | Author never sees a frame, an id, or a `TVar`. `Exec.cancelled :: STM Bool` is the only concurrency primitive exposed. |
| SDK dispatch ↔ Peer | STM maps + `MVar` write lock | Peer is the sole `TVar` owner; Dispatch never touches ids. |
| Peer ↔ Transport | `ByteString` frames | Framing is the transport's concern; HTTP/WS drop in unchanged. |
| plugin process ↔ bridge | NDJSON JSON-RPC on fd 0/1 | **Hostile in both directions.** Both sides rebuild every field. |
| bridge ↔ Cordis | `ctx.effect()` disposers | Every registration reversible; HMR is disposal + re-apply. |
| protocol package ↔ bridge package | typed imports, no Cordis in protocol | Mirrors `hook-protocol` / `hooks-claude-code`. |

---

## Corrections This Research Suggests to `PROJECT.md`

| Current requirement | Finding | Suggested change | Confidence |
|---|---|---|---|
| `initialize` is a plugin→harness request | Every comparable protocol (MCP, LSP, ACP, `dsh-sdk-protocol`) is host-initiated; host-first carries `protocolVersion`/`cwd` and gives the supervisor a timeout | Host→plugin request; manifest is the result; `--dump-manifest` prints that result | MEDIUM |
| `section/render` in the inbound method set | `PromptSection.text` is synchronous | Drop from v1; static text in the manifest + `section/changed` push | HIGH |
| `Guard` returns `Allow \| Deny Text \| Rewrite Value` | `PreToolDecision` has no rewrite; the comment says it is excluded by design | Drop `Rewrite` from v1 (or reroute via `tools/execute` and document the logging gap). Add `Ask`, which the seam *does* support | HIGH |
| "JSON Schema derived from the Haskell types" | The harness enforces a narrow subset at `register()`; `autodocodec-schema` emits keywords it rejects | Own `DshSchema` targeting the enforced subset; smart constructors, not a post-hoc check | HIGH |
| "evaluate `jsonrpc`/`json-rpc` first" | `json-rpc` emits unframed output, needs `MonadLoggerIO`, and lts-22.43 pins an older version | Own the codec; record the rejection reason | MEDIUM-HIGH |
| `Tool` has `render :: a -> v -> [ContentBlock]` | Harness `render` is sync and local; the bridge cannot call the Haskell one | Keep the Haskell `render` — it runs plugin-side at execute time and its blocks ride back in the result envelope | HIGH |
| e2e "keyless snapshot" as one requirement | Harness CI has no GHC | Split into a TS-fixture-plugin snapshot (harness repo) + a real-binary e2e (SDK repo) | MEDIUM |
| Tool/Guard/Section/Subagent registration | Nothing states they register atomically | Add: all four register as one rollback unit | MEDIUM |

---

## Sources

**HIGH — read directly from `deepseek-harness` source at `b150a551b8`:**
- `packages/core/tools/src/index.ts` — `ToolDefinition`, `ToolOutputDefinition`, `PreToolDecision`, `PostToolDecision`, `ToolGuard` (sync), `register()` calling `assertSupportedJsonSchema`, the `tools/*` waterfall declarations and their `@mode` tags
- `packages/core/tools/src/json-schema.ts` — the enforced JSON Schema subset
- `packages/core/system-prompt/src/index.ts` — `PromptSection.text` (sync), `section()`, `system-prompt/assemble` (async waterfall)
- `packages/mcp/mcp-client/src/{index,connection,transport,tools}.ts` — supervisor generations, two-phase swap, `McpResult` envelope, local pure `render`, name normalization, `scrubbedParentEnv`
- `packages/hooks/hooks-claude-code/src/index.ts` — `tools/pre-execute` → `PreToolDecision` mapping with `next()` delegation
- `packages/sdk/protocol/src/{transport,types}.ts` — `JsonRpcLineTransport` (NDJSON framing, `-32601`/`-32603`, abort-on-signal pending removal), method-naming conventions
- `packages/subprocess/subprocess/src/{index,types}.ts` — `SubprocessRuntime.spawn`, `SubprocessHandle` stream dispositions, `scrubbedParentEnv`
- `packages/subagent/subagent/src/types.ts` — `SubagentProvider`
- `packages/llm/llm/src/types.ts` — `ContentBlockMap`, `ToolSchema`
- `packages/test-support/{acp-snapshot,llm-replay}/README.md` — keyless snapshot machinery, JSON-RPC id normalization
- `docs/architecture.md`, `docs/cordis-primer.md`, `docs/cookbook/adding-a-package.md`, `CLAUDE.md`

**HIGH — verified upstream:**
- `jprupp/json-rpc` `src/Network/JSONRPC/Interface.hs:88-89` — `encodeConduit` emits no delimiter — https://github.com/jprupp/json-rpc
- Stackage `lts-22.43` = GHC 9.6.6; pins `json-rpc-1.0.4`, `autodocodec-0.2.3.0`, `autodocodec-schema-0.1.0.4`, `aeson-2.1.2.1`, `stm-2.5.1.0`, `async-2.2.5`, `hspec-golden-0.2.2.0`, `QuickCheck-2.14.3`, `conduit-1.3.6`, `unliftio-0.2.25.0` — https://www.stackage.org/lts-22.43

**MEDIUM — official docs:**
- https://hackage.haskell.org/package/json-rpc — v1.1.3 (2026-08-18), `runJSONRPCT` requires `MonadLoggerIO` + `MonadUnliftIO`
- https://hackage.haskell.org/package/autodocodec-schema-0.1.0.4/docs/Autodocodec-Schema.html — `JSONSchema` constructors including `MapSchema`, `AnyOfSchema`, `RefSchema`, `WithDefSchema`
- https://hackage.haskell.org/package/autodocodec — v0.6.0.0 (2026-07-24)

**MEDIUM — designed here, not verified against an implementation:** the wire protocol (method names, manifest shape, error-code assignments), the conformance-corpus arrangement, the phase graph. These follow verified precedents but no such bridge exists yet; expect the corpus to shift during P1/P6.

**Gaps / open questions for later phases:**
- `SubagentProvider.start` returns a `SubagentRun` whose full surface was not audited; the subagent phase (P8) needs its own read of `packages/subagent/subagent/src/types.ts` and of `subagent-acp` as the out-of-process template.
- Whether `ctx.subprocess.spawn` keeps a long-lived duplex child healthy across the harness's grace/kill paths was inferred from the type docs, not exercised. Validate early in P7 — the fallback is `node:child_process` plus `scrubbedParentEnv()`, matching `mcp-client`.
- The `presentation` manifest field's exact vocabulary needs `packages/core/tools/src/presentation.ts` read in full before P7.

---
*Architecture research for: Haskell plugin SDK ↔ Cordis harness bridge over NDJSON JSON-RPC*
*Researched: 2026-08-25*
