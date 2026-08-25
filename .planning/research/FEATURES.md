# Feature Research

**Domain:** Out-of-process agent-plugin SDK (Haskell) — typed tools, guards, prompt sections, and subagent providers over newline-delimited JSON-RPC 2.0 on stdio, bridged into a Cordis plugin harness
**Researched:** 2026-08-25
**Confidence:** HIGH for harness-side contracts (read from source of truth), HIGH for MCP (current spec fetched), MEDIUM-HIGH for Claude Code / Codex hooks (official docs, one Codex detail from secondary sources), MEDIUM for LSP (search summary, not spec fetch)

---

## Executive Framing

Four prior-art families define what "out-of-process agent plugin SDK" means today:

| Family | Shape | What it contributes to this design |
|---|---|---|
| **MCP** (spec `2026-07-28` RC) | JSON-RPC, stdio + Streamable HTTP, server *provides* capabilities | Tool declaration + JSON Schema, structured results, the protocol-error/tool-error split, cancellation race rules, deterministic list ordering, discovery |
| **Claude Code / Codex hooks** | Process-per-event, stdin JSON + exit code + stdout JSON, hook *intercepts* | Decision vocabulary (`allow`/`deny`/`ask`/`escalate`), `additionalContext`, per-hook timeouts, fail-open-on-timeout, matcher scoping |
| **LSP** | JSON-RPC, stdio, long-lived peer, bidirectional | `initialize` handshake, static + dynamic capability registration, `$/cancelRequest`, `window/logMessage`, per-side capability flags |
| **DeepSeek Harness in-process seams** | Cordis `ctx.effect()` registrations, typed events, waterfall dispatch | The *actual* target contract — everything the wire exposes must be expressible as a registration on `ctx.tools`, `tools/pre-execute`, `ctx.systemPrompt`, or `ctx.subagents` |

The decisive constraint is the fourth. This SDK is not free to invent a surface: **anything the wire can express that the host cannot register is a lying contract.** Three PROJECT.md Active requirements fail that test today (guard `Rewrite`, dynamic `section/render`, and the implied breadth of `subagent/run`); they are called out as anti-features below with source citations.

MCP's 2026-07-28 RC is worth noting as a *counter*-example rather than a template: it **deleted** the `initialize` handshake and `Mcp-Session-Id`, moved version and capabilities into per-request `_meta`, and made `server/discover` optional — all to make HTTP requests land on any server instance. That motivation does not exist for a stdio child process whose lifetime *is* the session. It also **deprecated Roots, Sampling, and Logging** with 12-month grace periods, which is direct evidence against building the analogous features here.

---

## Feature Landscape

### Table Stakes (Users Expect These)

Missing any of these and the SDK is not credibly an out-of-process plugin SDK.

| Feature | Why Expected | Complexity | Notes |
|---|---|---|---|
| **Newline-delimited JSON-RPC 2.0 envelope + stdio framing** | Universal across MCP stdio, LSP, ACP, and the harness's own `dsh-sdk-protocol` | LOW | Harness precedent: `JsonRpcLineTransport` — one compact JSON frame per `\n`, `id`+`method` = request, `id` alone = response, `method` alone = notification, **malformed JSON lines are ignored** (not fatal). Match that ignore-rule; a fatal parse is a DoS on the plugin. |
| **stdout reserved for frames; all logs to stderr** | Any stray `putStrLn` corrupts the stream; every stdio protocol enforces this | LOW | Highest-frequency day-one bug in every stdio SDK. Mitigate structurally: `runPlugin` should redirect/replace the global stdout `Handle` with a `Handle` to stderr (or `/dev/null`) after capturing the real one for framing, so a user's `print` cannot break the wire. This is a *feature*, not a doc note. |
| **Handshake declaring `protocolVersion` + the plugin's contributions** | LSP `initialize`, MCP legacy `initialize`, ACP, and harness `dsh-sdk-protocol` all do it; the bridge cannot register anything without it | MEDIUM | For stdio process-lifetime, a one-shot handshake is correct — do **not** copy MCP 2026-07-28's stateless per-request `_meta`. |
| **Version mismatch fails loud *and names the supported set*** | Pre-1.0 stance forbids shims, but a bare failure is undiagnosable | LOW | MCP's `UnsupportedProtocolVersionError` (`-32022`) carries `data: { supported: [...], requested }`. Copy the *payload*, not the negotiation. Costs one error constructor; turns "handshake failed" into an actionable message. Harness `dsh-sdk-protocol` currently has *no* version validation at all (its own README lists this as a known limitation) — the Haskell SDK can be strictly better here. |
| **Tool declaration: `name`, `description`, JSON Schema `parameters`** | The harness `ToolSchema` is literally `{ name: string; description: string; parameters: Record<string, unknown> }` | LOW | Verified: `packages/llm/llm/src/types.ts:333`. Also honor the naming contract — public names normalize to 64 chars, `[A-Za-z0-9_-]` (see `dsh-mcp-client` naming rules). Reject invalid names at manifest build, not at bridge registration. |
| **Mandatory output declaration: canonical JSON schema + pure `render`** | `ToolDefinition.output` is **required** on the harness side, unlike MCP's optional `outputSchema` | MEDIUM | `ToolRuntime.register()` throws `TypeError` if `output` is absent, then calls `assertSupportedJsonSchema(output.schema)`. A Haskell `Tool` without an output type cannot register. This is stricter than every peer SDK — design `Tool` so omitting it is *unrepresentable*. |
| **Harness JSON Schema subset conformance, checked in the SDK** | The host enforces a narrow subset and *rejects* rather than ignoring unsupported keywords | MEDIUM | Verified subset (`packages/core/tools/src/json-schema.ts`): `type` ∈ {object, array, string, number, integer, boolean, null}; `oneOf` (≥2 branches, exactly-one); object `properties`/`required`/boolean `additionalProperties`; array `items`; scalar `enum`/`const`; annotations `description`/`title`/`default`/`examples`. **No `$ref`, `$defs`, `allOf`, `anyOf`, `not`, `minimum`, `maxLength`, `pattern`, `format`, or tuple `items`.** See dependency notes — this reshapes the whole `HasSchema` design. |
| **Tool execution request with a correlated id** | Baseline RPC | LOW | — |
| **Cancellation notification with correct race semantics** | MCP `notifications/cancelled`, LSP `$/cancelRequest`; the harness threads `exec.signal` through the *entire* pipeline and re-fuses it across around-wrappers | MEDIUM | The notification is the easy half. The rules are the feature: (1) a cancelled request **MUST NOT** be answered; (2) an unknown/already-settled id is **ignored, not an error**; (3) the sender **ignores a late response**. Harness side is cooperative-only — `ToolDefinition.execute` JSDoc: the registry "does not abandon this promise" and "cannot hard-kill same-process code." Same applies across the wire: the bridge waits. |
| **Cancellation exposed as an observable, composable flag** | Every SDK gives the tool body *some* handle (AbortSignal / `context.Context` / `CancellationToken`) | LOW | `Exec.cancelled :: STM Bool` (PROJECT.md) is the right Haskell shape and better than the imperative peers — see Differentiators. |
| **Two-tier error taxonomy: protocol error vs. tool execution error** | MCP is explicit that these are different mechanisms with different model consequences | LOW | Protocol errors (unknown tool, malformed frame) → JSON-RPC `error`. Tool execution errors (bad input, API failure, business rule) → a *successful* response carrying `isError: true` with model-readable text. MCP: clients **SHOULD** feed execution errors to the model for self-correction and **MAY** feed protocol errors, which "are less likely to result in successful recovery." Maps exactly onto harness `ToolExecutionFailure` vs. a thrown `HarnessError`. Getting this wrong silently degrades model recovery. |
| **Content-block result vocabulary with an `Unknown` passthrough** | `ContentBlock` is a **merge-extensible** map in the harness (`ContentBlockMap`) — plugins add entries | LOW | PROJECT.md already has this right. Switch on the tag, fall through unknowns; never `assertNever` a merge-extensible union. |
| **Guard decision: `Allow` / `Deny reason` (and `Ask reason`)** | Claude Code `permissionDecision: allow\|deny\|escalate`; harness `PreToolDecision` | MEDIUM | Harness: `{kind:'allow'} \| {kind:'deny', reason} \| {kind:'ask', reason?}`. Add `Ask` — the DSH Claude Code bridge already supports it, and it is one constructor. Note `Allow` is *delegate via `next()`*, not force-approve (waterfall semantics; the DSH bridge README confirms "`allow` does not pre-approve"). |
| **Guard runs on `tools/pre-execute`, not `ctx.tools.guard()`** | Only one of the two is async | LOW (but load-bearing) | `ToolGuard = (execution) => string \| undefined` — **synchronous**, so an out-of-process guard cannot use it. `'tools/pre-execute'(exec, next): Promise<PreToolDecision>` is the async waterfall and is the only viable target. Both verified at `packages/core/tools/src/index.ts:152` and `:711`. |
| **stderr diagnostics channel with levels** | LSP `window/logMessage`, MCP logging (now deprecated), every hook protocol's stderr | LOW | Deliberately *not* an RPC method — MCP deprecated its `logging` capability in 2026-07-28. Plain leveled stderr lines the bridge forwards to `ctx.logger` is the surviving pattern and costs nothing. |
| **Cooperative shutdown ladder** | The bridge will kill the process; the plugin must not need killing | MEDIUM | Harness precedent (`dsh-subagent-dsh-sdk`): bounded `shutdown` request → stdin EOF → SIGTERM → SIGKILL, with three configurable graces (`shutdownTimeoutMs` 1000, `disposeEofGraceMs` 6000, `disposeGraceMs` 3000). The plugin must (a) answer `shutdown`, (b) exit on stdin EOF, (c) survive SIGPIPE on a closed stdout, (d) reach quiescence — no in-flight tool left writing. |
| **Every inbound frame validated and rebuilt before use** | Explicit PROJECT.md constraint; harness convention "hostile validation at process boundaries" | MEDIUM | Two distinct boundaries with different stances: the *frame* boundary (bridge is trusted-ish → validate structurally, ignore malformed) and the *tool arguments* boundary (**model-controlled, genuinely hostile** → validate against the derived schema before decoding). Aeson `FromJSON` alone is not validation: it silently ignores extra keys, and `additionalProperties: false` must be enforced separately. |
| **One runnable example plugin** | Every SDK ships one; it is the de-facto integration test | LOW | PROJECT.md `examples/echo` (one tool + one guard) is the right minimum. It is also the binary the harness snapshot test points at. |
| **Golden wire-frame tests + codec property tests** | The wire *is* the product | MEDIUM | `hspec-golden` for frames, QuickCheck round-trips for codecs. Golden frames are what catch an accidental field rename that a type-level refactor would otherwise hide. |

### Differentiators (Competitive Advantage)

| Feature | Value Proposition | Complexity | Notes |
|---|---|---|---|
| **`--dump-manifest` for keyless CI** | No peer SDK has this. MCP's answer is the *interactive* Inspector; LSP has nothing. Static manifest dump makes the harness's keyless-snapshot gate reachable without GHC in CI. | LOW | Near-free once the handshake exists — same manifest value, printed instead of framed. Harness precedent: `--dump-default-config` in `packages/boot/app-boot/src/profile.ts:367`, described as "a recovery diagnostic." **Highest value-to-cost ratio in this list.** Double it as the SDK's own golden fixture and as the bridge's offline schema source. |
| **Deterministic manifest ordering** | Prompt-prefix stability = KV-cache hits. Every tool schema is in the model request prefix on *every* turn. | LOW | MCP 2026-07-28 makes this explicit: servers **SHOULD** return tools in deterministic order because it "improves LLM prompt cache hit rates when tools are included in model context." Sort by name; assert it in the manifest golden test. A `Data.Map`-backed `Plugin` gets this for free; a list does not. |
| **`HasSchema` with a Generic default, targeting the harness subset** | The core DX bet. Peers: TS SDK uses zod, Python uses Pydantic, Haskell `mcp-server` uses Template Haskell handler derivation. A Generic-derived schema that is *guaranteed registrable* is better than all of them. | HIGH | The value is in the *guarantee*, not the derivation. See dependency notes: the deriver must reject recursion (no `$ref`), must not emit refinement keywords (`minimum` etc. are rejected, not ignored), and must map sum types to `oneOf` with ≥2 branches. Ship the subset checker with it or the feature is a trap. |
| **In-process fake host / test harness** | Test the whole plugin — handshake, dispatch, cancellation, shutdown — with no `dsh`, no subprocess, no API key, in milliseconds | MEDIUM | Direct analog: MCP's `InMemoryTransport.createLinkedPair()`, which the TS SDK's own testing guide recommends over spawning. Requires transport-behind-an-interface (already a PROJECT.md decision, motivated there by future HTTP/WS — this is the *nearer* payoff). Shape: `withFakeHost :: Plugin -> (HostHandle -> IO a) -> IO a` where `HostHandle` can `handshake`, `callTool`, `cancel`, `shutdown` and assert on frames. |
| **`STM`-based cancellation** | Composes with `atomically`, `orElse`, `race`, `registerDelay`. AbortSignal/Context idioms in the peer SDKs do not compose; a Haskell author gets a genuinely better primitive. | LOW | `Exec.cancelled :: STM Bool` per PROJECT.md. Consider also exposing `Exec.awaitCancel :: STM ()` so a body can `race`. Both are one `TVar`. |
| **Per-tool `timeoutMs` declared in the manifest** | The host already has the enforcement machinery; declaring the budget is nearly free | LOW | `ToolDefinition.timeoutMs` exists and is enforced by `dsh-tool-call-timeout-policy` (a `tools/execute` wrapper). Its JSDoc: it is **never sent to the model**, and declaring it *asserts* the tool forwards its signal cooperatively. So the Haskell `Tool` should only be allowed to set it alongside a cancellation-aware body. |
| **Structured, leveled stderr (JSONL) rather than free text** | Lets the bridge map plugin diagnostics onto `ctx.logger` levels and into session diagnostics instead of dumping opaque text | LOW-MEDIUM | Fall back to treating a non-JSON stderr line as `warn` free text so `Debug.Trace` still surfaces. |
| **Subagent provider with explicit capability advertisement** | The seam *rejects* an unsupported request before child creation, so capabilities must be declared, not discovered | MEDIUM | Harness `SubagentProvider.capabilities`: `outputSchema`, `depthLimit`, `toolFilter`, `persona`. Precedent for an out-of-process provider: `subagent-dsh-sdk` advertises **all four false** and `inheritsParentContext: false`. So a v1 Haskell subagent honestly advertises nothing — which is fine and matches shipped behavior. |
| **Progress notifications** | MCP `notifications/progress` (`progressToken`, monotonic `progress`, optional `total`/`message`); enables timeout-clock reset for genuinely long tools | MEDIUM | **Blocked on the host, not on the SDK.** DSH has no progress consumer on `tools/execute`. Building the plugin→host half alone produces notifications nothing renders. Defer until a bridge consumer exists; keep the wire slot reserved. |
| **HMR restart on config change** | Harness convention — every registry contribution must prove disposal via an HMR-safety test | MEDIUM | This is *bridge-side* work (see anti-features). The SDK's obligation is only to make restart clean and idempotent: exit on EOF, no orphaned children, no partial frame on the way out. `dsh-mcp-client` is the template for the bridge half (backoff, per-outage attempt budget, generation rollback). |

### Anti-Features (Commonly Requested, Often Problematic)

| Feature | Why Requested | Why Problematic | Alternative |
|---|---|---|---|
| **Guard `Rewrite Value` (mutate tool args)** | Claude Code's `PreToolUse` really does support `updatedInput`; it is in PROJECT.md as an Active requirement | **The host cannot honor it.** `PreToolDecision` is `allow \| deny \| ask` and its JSDoc states the exclusion explicitly: *"Input rewriting is excluded because arguments are already logged and presented."* `dsh-hook-protocol` confirms: `updatedInput` is *"parsed but not honored — input rewrite is a deferred consistency-design problem"*, and the Claude Code bridge *"logs + warns."* Shipping `Rewrite` on the wire means the bridge must drop it, log a warning, and every Haskell author who uses it writes a guard that silently does nothing. | `Deny` with an actionable, model-readable reason. This is MCP's documented recovery path — execution errors "contain actionable feedback that language models can use to self-correct and retry with adjusted parameters." Revisit only after `.agents/notes/proposed/feature/2026-06-30-pre-tool-input-rewrite.md` lands. |
| **Dynamic `section/render` (per-assembly out-of-process prompt render)** | It looks symmetric with `tool/execute`, and is in PROJECT.md as an Active requirement | Two independent blockers. (1) **Type:** `PromptSection.text` is `string \| ((context: AssembleContext) => string)` — **synchronous** (`packages/core/system-prompt/src/index.ts:67`). No `await` is possible inside it, so a JSON-RPC round-trip cannot be performed there at all. (2) **Cost:** the prompt is assembled **once per agent step**, so a dynamic section puts an IPC round-trip on the critical path of *every* model request and makes the system-prompt prefix non-deterministic — the exact thing that invalidates the KV cache the harness README is careful about. Routing it through the async `system-prompt/assemble` waterfall works around (1) but makes (2) worse. | **Static section text declared in the handshake manifest.** Registered once via `ctx.systemPrompt.section({ name, order, text: <literal> })`, zero per-assembly IPC, perfectly prefix-stable. For genuinely dynamic contribution, use the route the harness already supports out-of-process: `additionalContexts` returned from the guard / post-execute decision, and `agent.inject()` at session start — precisely what `dsh-hooks-claude-code` does (`SessionStart` → `agent.inject()`, `UserPromptSubmit`/`PostToolUse` → sourced context on the downstream decision). |
| **MCP-style `resources` and `prompts` primitives** | "MCP has three primitives, so we need three" | The harness has **no consumer** for either. `dsh-mcp-client`'s own Known Limitations says it verbatim: *"Tools are the only bridged MCP capability — Resources and Prompts have no harness consumer and are deferred."* Building them produces a wire surface with nothing on the other end. | Tools + guards + static sections + subagents. Those are the seams that exist. |
| **Full JSON Schema 2020-12 emission from the deriver** | MCP 2026-07-28 expanded to full 2020-12 "enabling composition and conditionals"; generic Haskell schema libraries emit `$ref`/`$defs`/`allOf` by default | The harness **rejects** unsupported keywords rather than ignoring them (`JsonSchemaError`, code `UNSUPPORTED_SCHEMA`, listing every violation). A recursive Haskell type has no `$ref` escape and will either loop the deriver or emit an unregistrable schema. A helpful `minimum: 0` from a `Natural` newtype is a hard registration failure. | Target the enforced subset exactly, and ship a **subset conformance checker that fails at `--dump-manifest`/startup**, not at bridge registration. Fail in the plugin author's terminal, not in the harness's load path. |
| **Compatibility shims / dual-era protocol support** | MCP maintains a full legacy/modern compatibility matrix; it looks responsible | Pre-1.0 with no external consumers. The harness's own stance is explicit ("Backends reject old on-disk formats"; `SESSION_FORMAT_VERSION` at `0` with no compatibility promise). MCP's matrix is ~7 rows of era-probing heuristics — that is the cost of the alternative. | Single supported version, fail loud, **list the supported set in the error**. Add the second version only when a real second consumer exists. |
| **Plugin→host `agent/inject` in v1** | Symmetry ("if the host can call me, I should call it"); PROJECT.md already marks it "later" | The v1 wire has no session/agent id vocabulary, so the plugin cannot name an injection target. And the harness invariant **model-visible ⟺ logged** means any injected content requires a new `SessionEventMap` member — a cross-repo change with a `SESSION_FORMAT_VERSION` conversation attached. | Keep plugin→host to `initialize` only in v1. Contribute context through the *response* to a host-initiated request (`additionalContexts` on a guard decision), where the host owns the logging. |
| **Sampling / LLM callbacks from the plugin** | MCP has (had) sampling; "my tool wants to ask the model" | MCP **deprecated Sampling** in 2026-07-28 with a 12-month removal grace — the ecosystem is walking away from it. PROJECT.md already scopes out streaming seams (`ctx.llm`) as "chatty or stream-shaped." | Subagent delegation is the supported "ask a model" path, and it is a seam that actually exists. |
| **Reconnect / retry / supervision logic inside the plugin** | "The plugin should be resilient" | Wrong side of the boundary. Supervision belongs to the spawner. `dsh-mcp-client` owns exactly this: exponential backoff, per-outage attempt budget, budget reset after `maxDelayMs` uptime, generation rollback so tools never duplicate or leak. A plugin that also retries fights its supervisor. | Plugin dies loudly and fast; the bridge owns backoff, budget, and generation replacement. |
| **Streaming / incremental tool results** | Terminal-shaped tools want to stream | The harness tool result is a single canonical JSON value validated against `output.schema`, projected once by a **pure** `render`. There is no incremental slot. PROJECT.md already scopes streaming seams out. | Return the complete value. Use `timeoutMs` + cancellation for long work. Revisit only alongside a host progress consumer. |
| **Generic Cordis reflection (`service/call`, `event/subscribe`)** | It would make the SDK "complete" | Already out of scope in PROJECT.md; reinforced here because it is the single largest scope-creep attractor. Cordis dispatch modes (`emit`/`waterfall`/`parallel`/`serial`) each have distinct `next()` and quiescence obligations that do not survive a generic wire mapping — a remote waterfall listener that fails to call `next()` silently short-circuits the chain. | v1 binds four named seams with hand-written, individually-tested semantics. |
| **Live self-modification (agent authors Haskell plugins at runtime)** | The harness ships a `demo:cordis` where the agent modifies its own runtime | GHC compile latency makes it a fundamentally different product. Already out of scope in PROJECT.md. | — |

---

## Feature Dependencies

```
[JSON-RPC envelope + stdio framing]
    ├──requires──> [stdout guard: global stdout redirected to stderr]
    └──enables───> everything below

[Transport behind an interface]
    ├──enables──> [Fake host / in-process test harness]
    └──enables──> [HTTP/WS transports]  (v2, out of scope)

[HasSchema / Generic derivation]
    └──requires──> [Harness JSON Schema subset conformance checker]
                       └──requires──> [recursion/cycle detection]   (no $ref escape hatch)

[Manifest assembly]
    ├──requires──> [HasSchema]
    ├──requires──> [Deterministic ordering]
    ├──enables───> [Handshake]
    ├──enables───> [--dump-manifest]        (same value, different sink — near-free)
    └──enables───> [Golden manifest fixture]

[Tool execution]
    ├──requires──> [Manifest assembly]  (host must know the tool to call it)
    ├──requires──> [Mandatory output schema + pure render]
    └──requires──> [Two-tier error taxonomy]

[Cancellation]
    ├──requires──> [Request-id correlation]
    ├──requires──> [STM cancellation flag in Exec]
    └──enables───> [Per-tool timeoutMs]     (declaring a budget asserts cooperative cancel)

[Guard]
    └──requires──> [Manifest]  (only to name the tools it scopes to; otherwise independent)

[Static prompt Section]
    └──requires──> [Manifest]  only — NO runtime dependency (that is the point)

[Subagent provider]
    ├──requires──> [Capability advertisement in the handshake]
    ├──requires──> [Stop-reason vocabulary mapping]
    └──requires──> [Shutdown ladder cooperation]

[E2E keyless snapshot]
    ├──requires──> [TS bridge plugin]        (cross-repo, deepseek-harness)
    ├──requires──> [examples/echo binary]
    └──requires──> [--dump-manifest]         (snapshot the manifest without GHC in CI)

CONFLICTS:
[Guard Rewrite]          ──conflicts──> [harness PreToolDecision = allow|deny|ask]
[Dynamic section render] ──conflicts──> [sync PromptSection.text] AND [KV-cache prefix stability]
[Full JSON Schema 2020-12] ──conflicts──> [assertSupportedJsonSchema]
[Per-request version _meta] ──conflicts──> [one-shot handshake]  (pick handshake for stdio)
[Plugin-side reconnect]  ──conflicts──> [bridge-side supervisor]
```

### Dependency Notes

- **`HasSchema` requires the subset checker, not the other way round.** The harness subset has no `$ref`/`$defs`, so a Generic deriver has *no way to express a recursive type* — it must detect the cycle and fail with a named type, at manifest-build time. It also must not emit refinement keywords: `minimum`, `maxLength`, `pattern`, and `format` are all **rejected** (`JsonSchemaError`), not ignored, so a well-meaning `Natural`/`NonEmpty` instance breaks registration. Sum types map to `oneOf`, which requires **at least two branches** — a single-constructor sum must degrade to a plain object. Treat the checker as part of the deriver's definition of done.
- **`--dump-manifest` is a sink on the handshake path, not a separate feature.** Build the manifest value once; frame it for `initialize`, print it for `--dump-manifest`, and golden-test it. If these three ever diverge, the CI snapshot stops proving anything about the running plugin.
- **Deterministic ordering is a manifest-assembly property, not a post-hoc sort.** Choose an ordered container in the `Plugin` record so unordered iteration is unrepresentable; a `sort` call at the end is a rule someone will forget when a second assembly path appears.
- **Per-tool `timeoutMs` depends on cancellation being real.** The harness JSDoc is explicit that declaring `timeoutMs` *asserts* the tool "forwards `exec.signal` to a cooperative implementation that can reach quiescence." A Haskell `Tool` that sets a timeout but ignores `Exec.cancelled` produces a hung child that the timeout policy cannot actually stop. Consider making the timeout field only constructible from a cancellation-aware builder.
- **Static sections have no runtime dependency — that is their entire advantage.** They cost one manifest field and one `ctx.systemPrompt.section()` call in the bridge, and they never touch the request hot path.
- **The E2E requirement cannot be satisfied in this repo alone.** PROJECT.md already flags this; note the ordering consequence for the roadmap: the bridge phase must precede the snapshot phase, and the snapshot phase is a *deepseek-harness* PR subject to that repo's gates (100% per-file coverage, Agent Note, README with gated sections, real-composition test).
- **Timeout policy is a fail-open/fail-closed decision that must be made once, explicitly.** Claude Code's answer: hook timeout ⇒ "hook canceled, no decision rendered, **action proceeds**" (fail-open), and `dsh-hook-protocol` matches — an executor rejection becomes a `HookOutput` with `exitCode: undefined`, a *non-blocking* error. A security-motivated Haskell guard author will assume the opposite. Whichever is chosen, it belongs in the guard type's documentation and in a snapshot test, not in a config default nobody reads.

---

## MVP Definition

### Launch With (v1)

- [ ] **JSON-RPC 2.0 envelope + newline-delimited stdio framing, transport behind an interface** — everything depends on it; the interface is what buys the fake host
- [ ] **stdout hijack guard** — structurally prevents the single most common stdio-SDK bug
- [ ] **`initialize` handshake with `protocolVersion`, failing loud with the supported-version list** — the bridge cannot register anything without it
- [ ] **`Plugin` record + `runPlugin :: Plugin -> IO ()`** owning the loop, buffering, EOF/SIGPIPE shutdown, and `shutdown` request
- [ ] **`Tool` with `HasSchema`-derived args/output + the harness-subset conformance checker** — a schema that cannot register is worse than no derivation
- [ ] **`tool/execute` with the two-tier error taxonomy** — protocol error vs. `isError` result; the latter is what lets the model recover
- [ ] **`ContentBlock` with `Unknown Value` passthrough** — merge-extensibility is a harness invariant, not a nicety
- [ ] **`$/cancel` + `Exec.cancelled :: STM Bool`, with full race semantics** — no response for a cancelled id, ignore unknown ids, ignore late responses
- [ ] **`Guard` returning `Allow | Deny Text | Ask Text`, targeting `tools/pre-execute`** — note: **`Ask` in, `Rewrite` out**
- [ ] **Static `Section` declared in the manifest** — the affordable 90% of prompt contribution
- [ ] **Leveled stderr diagnostics** — the only logging channel that survives MCP's deprecation
- [ ] **Hostile validation at both boundaries** — structural at the frame, schema-checked at tool arguments
- [ ] **`--dump-manifest`** — unlocks the keyless CI story and is nearly free
- [ ] **`examples/echo`** (one tool + one guard) — the binary the snapshot points at
- [ ] **Golden wire frames + QuickCheck codec round-trips + golden manifest**
- [ ] **In-process fake host** — makes every item above testable without `dsh` or an API key

### Add After Validation (v1.x)

- [ ] **TS bridge plugin `@deepseek-ai/dsh-remote-plugin`** — cross-repo; gate is the deepseek-harness review, not this SDK's readiness
- [ ] **E2E keyless snapshot** (headless profile → Haskell tool called, Haskell guard vetoing) — the stated Core Value; strictly downstream of the bridge
- [ ] **`Subagent` provider** — trigger: the bridge's tool + guard paths are snapshot-green. Deliberately *after* v1: PROJECT.md's "one delegation request in, `{stopReason, lastAssistantMessage}` out" materially understates the seam, which additionally requires capability advertisement (`outputSchema`/`depthLimit`/`toolFilter`/`persona`), stop-reason mapping where *anything* unclean maps to `error`, a durable `subagent/descriptor` session event, cwd resolution from the parent session, and the dispose ladder.
- [ ] **Structured JSONL stderr** — trigger: free-text stderr becomes hard to correlate in the bridge
- [ ] **Per-tool `timeoutMs` in the manifest** — trigger: a real tool needs a non-default budget; must ship with the cooperative-cancel assertion enforced in the type
- [ ] **HMR restart-on-config-change (bridge half)** — trigger: iterating on a plugin binary becomes the dominant dev loop cost

### Future Consideration (v2+)

- [ ] **Progress notifications** — defer until a *host-side consumer* exists; today they would render nowhere
- [ ] **Plugin→host `agent/inject`** — needs session/agent id vocabulary on the wire and a new `SessionEventMap` member (model-visible ⟺ logged)
- [ ] **HTTP/WS transports** — the transport interface exists for this; nothing demands it yet
- [ ] **Guard `Rewrite`** — blocked on the harness's own pre-tool-input-rewrite design note, not on this SDK
- [ ] **Generic Cordis reflection / Typert-generated Haskell bindings** — explicitly out of scope; the largest scope-creep attractor
- [ ] **Dynamic prompt sections** — only if a host design emerges that does not put IPC on the per-step assembly path

---

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---|---|---|---|
| JSON-RPC envelope + framing + transport interface | HIGH | LOW | P1 |
| stdout hijack guard | MEDIUM | LOW | P1 |
| Handshake + `protocolVersion` + supported-version error | HIGH | LOW | P1 |
| `HasSchema` Generic derivation | HIGH | HIGH | P1 |
| Harness subset conformance checker | HIGH | MEDIUM | P1 |
| Tool declaration + execution | HIGH | MEDIUM | P1 |
| Mandatory output schema + pure render | HIGH | MEDIUM | P1 |
| Two-tier error taxonomy | HIGH | LOW | P1 |
| `ContentBlock` + `Unknown` passthrough | MEDIUM | LOW | P1 |
| Cancellation (notification + STM flag + race rules) | HIGH | MEDIUM | P1 |
| `Guard` (`Allow`/`Deny`/`Ask`) on `tools/pre-execute` | HIGH | MEDIUM | P1 |
| Hostile-input validation (both boundaries) | HIGH | MEDIUM | P1 |
| Shutdown ladder cooperation | HIGH | MEDIUM | P1 |
| stderr diagnostics | MEDIUM | LOW | P1 |
| `--dump-manifest` | HIGH | LOW | P1 |
| Deterministic manifest ordering | MEDIUM | LOW | P1 |
| `examples/echo` | HIGH | LOW | P1 |
| Golden frames + property tests | HIGH | MEDIUM | P1 |
| In-process fake host | HIGH | MEDIUM | P1 |
| Static prompt `Section` | MEDIUM | LOW | P1 |
| TS bridge plugin | HIGH | HIGH | P2 (cross-repo) |
| E2E keyless snapshot | HIGH | MEDIUM | P2 |
| `Subagent` provider | MEDIUM | HIGH | P2 |
| Per-tool `timeoutMs` | MEDIUM | LOW | P2 |
| Structured JSONL stderr | LOW | MEDIUM | P2 |
| HMR restart | MEDIUM | MEDIUM | P2 |
| Progress notifications | LOW (no consumer) | MEDIUM | P3 |
| Plugin→host `agent/inject` | MEDIUM | HIGH | P3 |
| HTTP/WS transports | LOW | MEDIUM | P3 |
| Guard `Rewrite` | MEDIUM | HIGH (host-blocked) | P3 |
| Generic Cordis reflection | LOW | VERY HIGH | P3 |

---

## Competitor Feature Analysis

| Feature | MCP (2026-07-28 RC) | Claude Code / Codex hooks | LSP | DSH in-process | **Our approach** |
|---|---|---|---|---|---|
| **Handshake** | **Removed** — per-request `_meta` version + optional `server/discover` | None; process-per-event, stdin JSON | `initialize` + `initialized` | N/A (in-process registration) | One-shot `initialize` (stdio process-lifetime makes statelessness pointless) |
| **Version negotiation** | Per-request; `UnsupportedProtocolVersionError` lists `supported` | None | `initialize` params, no retry mechanism | N/A | Fail loud, **but carry the supported list** (MCP's payload, not its negotiation) |
| **Capability declaration** | `capabilities` + `extensions` map with per-extension settings | None | Static in `initialize` + dynamic `client/registerCapability` | Provider `capabilities` record (subagents); registration is the capability (tools) | Static in the handshake manifest. Dynamic registration is LSP's biggest complexity source for its smallest payoff — skip. |
| **Tool schema** | Full JSON Schema 2020-12, `$ref` resolution required | N/A | N/A | **Enforced subset**; unsupported keywords rejected | Derive to the enforced subset; check in-SDK, fail in the author's terminal |
| **Output schema** | Optional `outputSchema` + `structuredContent` | N/A | N/A | **Mandatory** `output: { schema, render }` | Mandatory; make omission unrepresentable in the `Tool` type |
| **Result content** | text/image/audio/resource_link/resource + `annotations` | stdout text or JSON | N/A | `ContentBlock` (merge-extensible map) | Mirror `ContentBlockMap` with `Unknown Value` passthrough |
| **Error split** | Protocol error vs. `isError: true` (explicitly different model consequences) | Exit 2 = blocking; other non-zero = non-blocking error | JSON-RPC error only | `ToolExecutionFailure` vs. thrown `HarnessError` | Two-tier, matching MCP's rationale and DSH's types |
| **Cancellation** | `notifications/cancelled {requestId, reason}`; no response for cancelled id | Timeout only; no cancel channel | `$/cancelRequest` | `exec.signal` fused across around-wrappers | `$/cancel` notification → `Exec.cancelled :: STM Bool`; full race rules |
| **Timeouts** | Sender-side; **MAY** reset on progress, **SHOULD** cap | Per-hook `timeout`, per-event defaults (600s / 30s / 10s); timeout ⇒ **action proceeds** | Client-side | `ToolDefinition.timeoutMs` + a `tools/execute` wrapper | Host owns enforcement; plugin declares `timeoutMs` and must be cooperative |
| **Guard / interception** | None (client-side human-in-the-loop only) | `permissionDecision: allow\|deny\|escalate` + **`updatedInput`** | None | `allow\|deny\|ask` — **rewrite explicitly excluded** | `Allow\|Deny\|Ask`. **No `Rewrite`** — the host cannot honor it |
| **Context contribution** | `prompts` primitive (no DSH consumer) | `additionalContext`, `systemMessage` | None | `systemPrompt.section` (sync), `agent.inject()`, `additionalContexts` | Static manifest sections + `additionalContexts` on decisions |
| **Subagent delegation** | None | `SubagentStart`/`SubagentStop` observation only | None | `ctx.subagents` with capability advertisement | Typed provider, advertising nothing in v1 (matching `subagent-dsh-sdk`) |
| **Logging** | **Deprecated** (12-month grace) | stderr + exit code | `window/logMessage`, `telemetry/event` | `ctx.logger` | Leveled stderr, bridge-forwarded. Not an RPC method. |
| **Manifest dump for CI** | None (Inspector is interactive) | None | None | `--dump-default-config` (config, not contributions) | **`--dump-manifest`** — the clearest gap in the field |
| **Hot reload** | `notifications/tools/list_changed` + client re-sync | Re-read `hooks.json` | `client/registerCapability` | Cordis HMR; disposers required | Bridge-owned restart; SDK only guarantees clean exit |
| **Test harness** | `InMemoryTransport.createLinkedPair()`; Inspector UI | None | `vscode-languageserver-node` test utils | `dsh-loader-smoke`, `dsh-acp-snapshot` | In-process fake host + golden frames |
| **Schema-from-types DX** | zod (TS), Pydantic (Python); Haskell `mcp-server` uses Template Haskell | N/A | N/A | `defineTool` + schemastery | `HasSchema` with a Generic default, subset-guaranteed |

---

## Confidence and Gaps

**HIGH confidence** (read directly from the harness source of truth, quoted above):
`ToolSchema` fields; `ToolDefinition.output` being mandatory; the enforced JSON Schema subset; `PreToolDecision` excluding rewrite; `ToolGuard` being synchronous while `tools/pre-execute` is an async waterfall; `PromptSection.text` being synchronous; `SubagentProvider.capabilities`; the `subagent-dsh-sdk` shutdown ladder and its all-false capability advertisement; `ContentBlock` merge-extensibility; `dsh-hook-protocol`'s `updatedInput` non-honoring; `dsh-sdk-protocol` having no version negotiation.

**HIGH confidence** (current official spec fetched 2026-08-25): MCP `2026-07-28` RC — handshake removal, `server/discover`, `UnsupportedProtocolVersionError`, tool declaration and result fields, protocol-vs-execution error split, cancellation and progress semantics, deterministic-ordering rationale, and the Roots/Sampling/Logging deprecations.

**MEDIUM-HIGH** (official Claude Code hooks reference): the event table, output fields, exit-code semantics, per-event timeout defaults, fail-open-on-timeout.

**MEDIUM** (search summaries, not primary spec): LSP dynamic registration details; Codex hooks specifics (notably the claim that Codex `PreToolUse` intercepts only the shell tool — single secondary source, would matter only if Codex parity were a goal, which it is not).

**Gaps for later, phase-specific research:**
- Whether the bridge should register the Haskell guard via `tools/pre-execute` *scoped* (`agent.ctx`) or globally, and how per-agent scoping is expressed on the wire. The harness's scope-filtered dispatch (`@deepseek-ai/dsh-scope`) is a real feature the v1 wire has no vocabulary for; worth a decision before the bridge phase.
- The fail-open vs. fail-closed decision for a guard whose plugin process has died or timed out. Claude Code and `dsh-hook-protocol` both fail *open*; a security-motivated guard author will assume the opposite. Needs an explicit, tested decision.
- Whether `presentCall`/`presentResult` (the tool's UI render intent — `generic`/`terminal`/`diff`, `locations`) must be expressible on the wire. The harness treats render intent as "part of a tool's design, decided up front" and requires the methods to be **pure functions of `args`** — which is compatible with a static manifest declaration but was not covered by the question list and is not in PROJECT.md's requirements. Likely a real v1 gap.
- Which Hackage package (if any) supplies a maintained JSON-RPC 2.0 layer — deliberately left to STACK.md.

---

## Sources

**Harness source of truth** (read 2026-08-25, `~/ai-agents/deepseek-harness`):
- `packages/core/tools/src/index.ts` — `ToolDefinition`, `ToolOutputDefinition`, `PreToolDecision`, `PostToolDecision`, `ToolGuard`, `tools/pre-execute` and `tools/post-execute` waterfall JSDoc
- `packages/core/tools/src/json-schema.ts` — the enforced JSON Schema subset and `JsonSchemaError`
- `packages/core/system-prompt/src/index.ts` — `PromptSection`, `PromptContext`, `system-prompt/assemble`
- `packages/llm/llm/src/types.ts` — `ToolSchema`, `ContentBlockMap`, `FinishReasonMap`
- `packages/mcp/mcp-client/README.md` — tool naming, reconnect supervision, Known Limitations
- `packages/hooks/README.md`, `packages/hooks/hook-protocol/README.md`, `packages/hooks/hooks-claude-code/README.md` — hook bridging, decision merge precedence, `updatedInput` non-honoring
- `packages/sdk/protocol/README.md` — `JsonRpcLineTransport`, Known Limitations (no version negotiation, no cancel)
- `packages/subagent/subagent/README.md`, `packages/subagent/subagent-dsh-sdk/README.md` — provider capabilities, stop-reason mapping, dispose ladder
- `packages/test-support/loader-smoke/README.md`, `packages/test-support/acp-snapshot/README.md` — snapshot harness shape
- `packages/boot/app-boot/src/profile.ts` — `--dump-default-config` precedent

**External:**
- [MCP 2026-07-28 Release Candidate](https://blog.modelcontextprotocol.io/posts/2026-07-28-release-candidate/)
- [MCP — Versioning and Compatibility](https://modelcontextprotocol.io/specification/2026-07-28/basic/lifecycle)
- [MCP — Tools](https://modelcontextprotocol.io/specification/2026-07-28/server/tools)
- [MCP — Cancellation](https://modelcontextprotocol.io/specification/2026-07-28/basic/utilities/cancellation)
- [MCP — Progress](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/progress)
- [Claude Code Hooks Reference](https://code.claude.com/docs/en/hooks)
- [Codex CLI Hooks Reference](https://agenticcontrolplane.com/blog/codex-cli-hooks-reference) (secondary)
- [Codex Advanced Configuration](https://developers.openai.com/codex/config-advanced)
- [LSP Specification 3.17](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/)
- [MCP TypeScript SDK — Test a server](https://ts.sdk.modelcontextprotocol.io/v2/testing.html) (`InMemoryTransport`)
- [Hackage: `mcp-server`](https://hackage.haskell.org/package/mcp-server), [`mcp-types`](https://hackage.haskell.org/package/mcp-types), [`mcp`](https://hackage.haskell.org/package/mcp) — Haskell prior art for schema/handler derivation

---
*Feature research for: out-of-process agent-plugin SDK (Haskell) targeting DeepSeek Harness*
*Researched: 2026-08-25*
