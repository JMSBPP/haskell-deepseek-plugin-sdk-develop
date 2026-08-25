# Pitfalls Research

**Domain:** Haskell process-peer speaking bidirectional newline-delimited JSON-RPC 2.0 over stdio to a TypeScript Cordis plugin harness (DeepSeek Harness), plus the harness-side TS bridge plugin
**Researched:** 2026-08-25
**Confidence:** HIGH for harness-side claims (read from `deepseek-harness` source at commit `b150a55`), MEDIUM-HIGH for GHC/Stack claims (official docs, GHC RTS source, Hackage, Stackage), MEDIUM for the two "no prior art" claims (no generic remote-plugin protocol exists in the harness; no GHC job exists in its CI — both verified by exhaustive search of the repo, but absence is harder to prove than presence)

## Executive framing

This project has three distinct pitfall surfaces and they fail in different ways:

1. **The wire** — silent frame loss, unbounded buffers, id collisions, precision loss. These fail *quietly*: the symptom is a hang or a wrong number, never an exception.
2. **The seam impedance mismatch** — the harness's `ToolDefinition` demands *pure synchronous replayable* functions (`output.render`, `presentCall`, `presentResult`) that structurally cannot cross a process boundary. This fails *at design time* if caught, or as an unshippable PR if not.
3. **The contribution gauntlet** — deepseek-harness's per-file 100% coverage gate, keyless snapshot requirement, ~25 `doc-sync` verifiers, and Agent Note requirement apply to the bridge PR. There is **no GHC anywhere in deepseek-harness CI**. This fails *at PR review*, after the work is done.

Pitfall 3.1 (the CI/GHC tension) is the single highest-risk item in the project and should be resolved on paper in Phase 0, before any Haskell is written.

---

## Critical Pitfalls

### Pitfall 1: stdout is the wire, and GHC will quietly break it

**What goes wrong:**
Three independent failure modes share one root:

- **Block buffering.** GHC picks a `Handle`'s buffer mode from what the fd *is*. Interactive terminal → `LineBuffering`. **A pipe → `BlockBuffering`.** In development you run the plugin in a terminal and every frame flushes on `\n`; the moment the bridge spawns it with `stdio: ['pipe','pipe',...]`, frames sit in an 8KB buffer until it fills or the process exits. The handshake never arrives, the bridge's `initialize` never resolves, and plugin activation hangs.
- **Accidental non-frame writes.** `putStrLn`, `print`, `trace`/`Debug.Trace` (which writes to stderr — safe), a library that logs to stdout, `hPutStr stdout` in a partially-written state, and a lazy-IO `interact` all interleave bytes into the frame stream.
- **Bytes that are not frames at all.** `+RTS -s`/`-hT` statistics and RTS panics go to stderr (safe), but `error`/uncaught-exception output and any `Prelude.putStrLn` in a dependency do not.

**Why it is worse here than in a normal RPC system:** the harness's transport *silently drops* what it cannot parse. `JsonRpcLineTransport.handleLine` (`packages/sdk/protocol/src/transport.ts`) does `JSON.parse(line)` inside a `try` whose `catch` is `return` — no log, no error frame, no counter. And `request()` has **no timeout** (only an optional `AbortSignal`). A single corrupted line therefore produces a permanently-pending promise, not an error.

**Why it happens:**
Every Haskell tutorial's hello-world uses `putStrLn`. Nothing in the type system distinguishes "stdout is a user-facing console" from "stdout is a binary protocol channel." Developers test in a TTY, where line buffering hides the bug.

**How to avoid:**
- In `runPlugin`, before anything else: `hSetBuffering stdout (BlockBuffering Nothing)` *plus an explicit `hFlush stdout` after every frame*, or `hSetBuffering stdout LineBuffering`. Prefer the explicit-flush form: it is correct regardless of what the fd is, and it lets you write the frame with one `BS.hPut` and flush once.
- **Structurally remove the temptation:** on entry, `hDuplicate stdout` into a private `Handle` used only by the framer, then `hDuplicateTo stderr stdout` so the *global* `stdout` now points at stderr. Any `putStrLn` anywhere in the program (including in a dependency) lands harmlessly on stderr. This is the single highest-value defensive move in the whole SDK and costs four lines. (`GHC.IO.Handle.hDuplicate` / `hDuplicateTo`, `base`.)
- Never expose the framing `Handle` in the public API; give plugin authors `Exec.log :: Text -> IO ()` writing to stderr so they have a sanctioned logging path.
- On the bridge side, **do not silently drop unparseable lines.** Wrap or fork the harness transport so a malformed line logs at `warn` with a truncated preview and increments a counter; a peer emitting garbage should be visible, not invisible.

**Warning signs:**
- Works under `stack run`, hangs under the bridge.
- Handshake completes only when the plugin exits (buffer flushed at exit).
- A tool works for small results and hangs for large ones (or vice versa — 8KB boundary).
- Bridge logs show zero frames received and no error.

**Phase to address:** Phase 1 (transport & framing). The `hDuplicateTo` guard and a golden test asserting *nothing* reaches the framing handle except frames belong in the first commit.

---

### Pitfall 2: `Handle` encoding is locale-dependent, and the harness spawns with a scrubbed environment

**What goes wrong:**
GHC selects a `Handle`'s character encoding from the process locale at startup. Under `LANG=C`, `LC_ALL=POSIX`, or **no locale variables at all**, that encoding is ASCII. The first non-ASCII character in any frame — a UTF-8 filename, a Chinese error message, an em-dash in a tool description, a `→` in a model-facing string — throws:

```
<stdout>: hPutChar: invalid argument (invalid character)
```

The process dies mid-frame. The bridge sees a truncated line and a child exit, with no useful diagnosis.

**Why this project is specifically exposed:** the harness spawns children through `scrubbedParentEnv()` (`packages/subprocess/subprocess/src/index.ts:60`), which forwards ambient env minus credential-shaped names and `DSH_*`. So `LANG` survives *if the parent has it*. In a Docker CI runner, a systemd service, or a GUI-launched Electron parent, it frequently does not. The bug then reproduces only in CI or only on a user's machine.

A second, quieter variant: **newline translation.** GHC's default `nativeNewlineMode` translates `\n` → `\r\n` on output on Windows. The harness transport happens to `.trim()` each line, so it survives *there* — but a stricter framer, a byte-exact golden test, or a `\r` embedded in a JSON string value will not. Input is symmetric: `\r` is stripped on Windows, retained on POSIX, so a fixture recorded on one platform fails on the other. The harness's testing policy explicitly requires fixtures replay on both macOS and Linux and says "fix fixtures, not normalizers."

**Why it happens:**
Haskell's `String`/`Text` IO looks encoding-agnostic. The locale dependency is invisible until it isn't. Developers on a UTF-8 desktop never hit it.

**How to avoid:**
- Do not use `Handle` text IO for frames at all. **Encode to a strict `ByteString` with `Data.Aeson.encode` (which produces UTF-8 bytes) and write with `Data.ByteString.hPut`**, then `hPut "\n"`. Decode inbound with `Data.ByteString.Char8.hGetLine`/`BS.hGetSome` + `Data.Aeson.eitherDecodeStrict'`. Bytes in, bytes out — the locale never enters the picture.
- Belt and braces for the *log* handle: `hSetEncoding stderr utf8` and `hSetEncoding stderr` with `mkUTF8 TransliterateCodingFailure` so a log line can never kill the process.
- Explicitly `hSetNewlineMode stdout noNewlineTranslation` and the same on the framing input handle, plus `hSetBinaryMode` where you keep a `Handle`. Do this even on POSIX so the code is platform-symmetric and a Windows regression is impossible rather than merely unobserved.
- Add a golden test whose payload contains a 4-byte emoji, a CJK string, and a literal `\r` inside a JSON string value.
- On the bridge side, set `LANG`/`LC_ALL` to a UTF-8 value in the spawn env as a defensive default (a `Config` field, per the harness's no-hardcoded-tunables rule).

**Warning signs:**
- Green locally, red in CI, with a truncated frame.
- "invalid character" / "commitBuffer: invalid argument" in the child's stderr.
- A golden file that differs by `\r` between contributors.

**Phase to address:** Phase 1 (transport & framing), alongside Pitfall 1.

---

### Pitfall 3: `render` / `presentCall` / `presentResult` are pure, synchronous, and replayable — they cannot cross a process boundary

**What goes wrong:**
`PROJECT.md` specifies `Tool` with a "pure total `render :: a -> v -> [ContentBlock]`". The harness's actual contract is stricter than "pure" in a way that is fatal to a naive design. From `packages/core/tools/src/index.ts`:

```ts
export interface ToolOutputDefinition {
  readonly schema: JsonSchemaNode
  /** Pure projection from validated arguments and value to Native/model content. */
  render(args: unknown, value: JsonValue): ContentBlock[]          // SYNCHRONOUS
  presentationMeta?(args: unknown, value: JsonValue): JsonValue     // SYNCHRONOUS
}
```

and

```ts
  presentCall?(args: unknown): ToolCallView | undefined              // SYNCHRONOUS
  presentResult?(args: unknown, result: ToolResult): ToolResultView | undefined
```

with the JSDoc: *"Pure and side-effect-side-free: a UI may call it during live streaming AND a session-log replay, so it must depend only on `args`."*

Three separate impossibilities follow:

1. **Synchronous.** These return values, not promises. There is no way to await a JSON-RPC round trip inside them.
2. **Replay.** `presentCall`/`presentResult` run when a UI re-renders a *historical* session. At that moment the Haskell plugin process **is not running and may not even be installed**. Any design that reaches out to the peer for presentation breaks session replay.
3. **`finalizeContent` is called even on pipeline failures that bypass `tools/post-execute`** and "must be total and must not throw" — including when the peer is dead.

**Why it happens:**
The mismatch is invisible from the Haskell side, where `render :: a -> v -> [ContentBlock]` looks like exactly the right signature. It only surfaces when you try to implement `ToolDefinition` in the bridge.

**How to avoid:**
Pick one of these, deliberately, in Phase 0 — and write it down as a Key Decision:

- **(A) Render eagerly on the Haskell side, ship content with the result.** `tool/execute` returns `{ value, content }`. The bridge's `output.render` becomes a pure lookup into a per-`callId` cache populated by the immediately preceding `execute`. This is viable because the registry calls `output.render(exec.arguments, value)` exactly once, immediately after execute (`index.ts:1800`). **But** the cache must be bounded, keyed on the registry-owned execution token, evicted on the same tick, and must have a defined answer when the entry is missing (the bridge must not throw). And it does *not* solve `presentCall`/`presentResult`.
- **(B) Declarative presentation in the manifest.** The plugin declares render intent as data (`kind: 'generic' | 'terminal' | 'diff'`, a title template over `args` fields, `locations`), and the bridge interprets it synchronously and purely. This is the only option that survives replay. The harness cookbook (`docs/cookbook/adding-a-tool.md`) treats render intent as a design-time decision, which fits a manifest.
- **(C) Omit `presentCall`/`presentResult` in v1** and accept the generic fallback (title = tool name, raw args). Document it under `## Known Limitations and Deferred Work` in the bridge README — which the `verify-package-readme-limitations` gate requires anyway.

The recommendation: **(A) for `output.render` + (C) for the UI presentation methods in v1, with (B) named as the v2 path.** State this explicitly; do not discover it during implementation.

**Warning signs:**
- A design sketch where the bridge's `render` is `async`.
- A test that renders a historical tool call while the peer happens to still be alive.
- Any wire method named `tool/render`.

**Phase to address:** Phase 0 (protocol design) — this is a *protocol shape* decision, not an implementation detail. Getting it wrong means redesigning the `tool/execute` response after Phases 1-3 are built.

---

### Pitfall 4: Unbounded frame accumulation on both sides, from a model-influenced peer

**What goes wrong:**
The harness's own transport has no frame-size bound. `JsonRpcLineTransport.onData` (`packages/sdk/protocol/src/transport.ts`) is:

```ts
this.buffer += typeof chunk === 'string' ? chunk : this.decoder.write(chunk)
this.drainLines()
```

A peer that writes 2GB without a `\n` grows the Node heap until the harness OOMs. That is acceptable for the SDK server (the client is trusted) but **not** for a remote plugin: tool arguments are model-controlled, and a Haskell tool that echoes an argument, reads a file, or shells out can produce an arbitrarily large result frame under model influence.

Symmetrically on the Haskell side, `BS.hGetLine` on a hostile stream, or `eitherDecode` over a lazy `ByteString` from `hGetContents`, has the same unbounded-growth property. And `aeson`'s `Value` is a lossy-but-large intermediate: a deeply nested `[[[[...]]]]` frame builds a deep structure before your validator ever sees it.

Two Haskell-specific amplifiers:
- **Big-exponent numbers.** Historically `aeson` allocated a huge `Integer` for input like `1e1000000000`, exhausting memory (aeson issue #198; fixed in 1.5.6.0 by refusing to realize such values as `Integer`). `Data.Scientific` itself is safe by construction, but *any* code path that does `realToFrac`, `toRealFloat`-to-`Rational`, `truncate`, or `read`/`Numeric.readFloat` on attacker-controlled digits reintroduces it. `HSEC-2023-0007` documents exactly this for `Numeric.readFloat` in `base` (35+ seconds on a single input).
- **Hash flooding.** aeson ≥ 2.0's `KeyMap` mitigates the classic `HashMap` collision attack, but only if you are on aeson 2.x. lts-22.43 ships aeson 2.1.2.1, which is fine — verify this stays true across any resolver bump.

**Why it happens:**
"It's our own plugin, we wrote both sides" is the mental model. But the *arguments* come from the model, and the harness's own doctrine is explicit: `code-runtime-python`'s README states the host "treats every inbound frame as hostile" and *rebuilds* each frame so "forged extra fields never ride along."

**How to avoid:**
- **Bound the line, not the parse.** Both framers cap accumulated bytes before a `\n` (a `Config` field on the bridge, e.g. `maxFrameBytes`, default 16MB). Exceeding it is a hard, loud failure: kill the peer / exit, with a diagnostic naming the byte count. Do not truncate-and-continue — a truncated frame resynchronizes at a random offset.
- **Bound the parse depth and the value.** Use `eitherDecodeStrict'` on a pre-bounded `ByteString`. Validate against the derived schema *before* decoding into the domain type, and reject unknown fields rather than ignoring them (aeson's default `Generic` `FromJSON` silently ignores extras — that is a forged-field vector).
- **Never `realToFrac`/`truncate`/`read` a `Scientific` that came off the wire without first bounding `base10Exponent`.** Add a `boundedScientific` helper in the codec module and use it everywhere.
- **Mirror the harness's rebuild discipline:** the bridge's inbound validator constructs a fresh object with only known fields, exactly as `validateChildFrame` does for fd-3 frames. A non-number call id must never be echoed into a reply.
- Add hostile-input property tests: deep nesting, huge exponent, duplicate keys, forged extra fields, embedded `\r`/`\n`/NUL, lone surrogates, a 100MB line.

**Warning signs:**
- Node RSS climbing during a tool call.
- A `Config` with no `maxFrameBytes`.
- Any `fromJSON`-to-`Int` conversion without a range check.
- `hGetContents` anywhere in the framer.

**Phase to address:** Phase 1 (transport, for the byte bound) and Phase 2 (codec/schema validation, for the value bound). The harness's own "hostile validation at process boundaries" convention makes this a *review blocker* on the bridge PR, not a nice-to-have.

---

### Pitfall 5: No request timeout + waterfall `next()` never called = a permanently wedged agent

**What goes wrong:**
`Guard` binds `tools/pre-execute`, a Cordis **waterfall**. The primer is explicit: *"Call `next()` to delegate... return without `next()` to short-circuit."* `Allow` means the bridge's listener must call `next()` and return its result.

Now compose that with two facts:

- `JsonRpcLineTransport.request()` has **no timeout**. It resolves only on a matching response frame, an input `error`/`end`, or an explicit `AbortSignal`.
- If the Haskell process crashes, deadlocks, or drops a frame *between* receiving `guard/decide` and replying, the bridge's `await peer.request(...)` never settles, so the waterfall listener never returns, so `next()` is never called, so the tool call never dispatches, so the agent turn never ends.

The user sees a hung agent with no error. `whenIdle()` waits forever — and `docs/defensive-patterns.md` names this exact class: *"if the awaited transition can never occur, the wait hangs, so handle the 'nothing to wait for' branch explicitly."*

The same shape applies to `tool/execute` (though there `dsh-tool-call-timeout-policy` will fire *if* the bridge declares `ToolDefinition.timeoutMs`) and to `section/render` (which blocks request assembly — worse, because it blocks *every* turn, not one tool call).

**Why it happens:**
The happy path always replies. The failure path is a process that is alive-but-stuck, which no `exit`/`close` event reports.

**How to avoid:**
- **Every remote call gets a deadline, and every deadline has a defined fallback decision.** Not "reject" — a *decision*. `guard/decide` timing out must mean `Allow` (call `next()`) or `Deny` (short-circuit), chosen deliberately and stated in the README; silently hanging is not an option. Fail-open vs fail-closed is a security decision: for a *guard*, fail-closed (deny) is defensible; for a *section*, fail-open (omit the section) is the only sane choice.
- Declare `ToolDefinition.timeoutMs` on every bridged tool so `dsh-tool-call-timeout-policy` produces a structured `TOOL_TIMEOUT` result. Note its JSDoc: declaring it *asserts* the tool forwards `exec.signal` to a cooperative implementation that reaches quiescence — so the bridge must actually send `$/cancel` and await acknowledgement, not just return early.
- Add a **liveness probe**: a periodic `$/ping` notification with a bounded reply window, so a stuck peer is detected between calls rather than during one.
- On peer death, the bridge must **settle every pending request with a typed error** before any other teardown. `JsonRpcLineTransport.close()` does `failPending(...)` — make sure the bridge calls it on `exit`, `close`, `error`, *and* stdin `end`, not just one of them.
- Write a test that spawns a peer which reads a `guard/decide` and then `sleep`s forever, and assert the turn still completes within the budget. This is the kind of test the harness's `contract-regressions.spec.ts` pattern exists for.

**Warning signs:**
- `await peer.request(...)` with no signal or timeout anywhere in the bridge.
- A waterfall listener with an `await` and no `try/finally` reaching `next()`.
- Manual testing only ever uses a healthy peer.

**Phase to address:** Phase 4 (guard seam) for the decision semantics; Phase 1 for the timeout plumbing. The "peer hangs mid-decision" test is a Phase 4 acceptance criterion.

---

### Pitfall 6: JSON number precision — the two runtimes disagree, and the harness insists on lossless

**What goes wrong:**
- **Haskell/aeson** parses every JSON number into `Data.Scientific` — arbitrary-precision coefficient and base-10 exponent. `12345678901234567890` and `0.1` survive exactly.
- **JavaScript** `JSON.parse` produces IEEE-754 doubles. `12345678901234567890` becomes `12345678901234567000`. Silently. No error.

So a Haskell tool returning a 64-bit database id, a nanosecond timestamp, a token count above 2^53, or a financial decimal loses precision the moment it crosses into Node — and the harness then **persists the rounded value** into the session log as the canonical result.

The harness cares about this a lot. `code-runtime-python`'s README describes the machinery it built for exactly this problem:

> `hasUnsafeIntegerToken` reads the **raw frame text** to catch an integer token that `JSON.parse` would silently round; `hasNonLosslessNumber` rejects a non-finite or negative-zero number... Beyond-safe-range integral doubles serialize through `BigInt` digits so the exact integer crosses, not the rounded `String()` form.

And `session-persistence/src/coordinator.ts` rejects a batch outright: `'session event batch is not losslessly JSON-serializable...'`.

The reverse direction is also live: model-produced tool arguments arrive as JS numbers, get `JSON.stringify`'d into the frame, and land in Haskell as `Scientific`. `-0`, `1e400` (→ `Infinity` → `null` under `JSON.stringify`), and `NaN` are all reachable.

**Why it happens:**
Nobody tests with a number above 2^53. The failure is a wrong value, not an exception, and it only appears in production data.

**How to avoid:**
- **Decide the number policy in the protocol, in Phase 0.** The cheapest correct answer for v1: *the wire carries no integer outside `[-(2^53-1), 2^53-1]`; anything larger is a JSON string with a documented encoding.* Enforce it in the derived schema (`HasSchema` for `Int64`/`Integer` emits `type: "string"` with a pattern, not `type: "integer"`), so a plugin author physically cannot ship a lossy tool.
- If you instead choose to carry big integers as JSON numbers, you must port the harness's `hasUnsafeIntegerToken` **raw-text scan** into the bridge — checking the parsed value is too late, the rounding already happened. Budget for this; it is not a one-liner.
- Reject non-finite and negative-zero at the codec on both sides. `Scientific` cannot represent `NaN`/`Infinity`, so Haskell will reject them at decode — but make the error message name the field.
- Property test: `QuickCheck` round-trip Haskell → JSON text → (a real Node `JSON.parse`/`JSON.stringify` pass) → Haskell, asserting equality. Running the JS half in the loop is the only way to catch this; a Haskell-only round-trip test will pass while the bug is live.

**Warning signs:**
- `HasSchema` maps `Integer`/`Int64` to `type: "integer"` with no bound.
- Any test fixture whose numbers are all small.
- The bridge writes a tool result to the session log without a losslessness check.

**Phase to address:** Phase 0 (protocol number policy), Phase 2 (schema derivation enforces it), Phase 6 (bridge-side check before the value reaches `ctx.tools`).

---

### Pitfall 7: Request-id collisions in a bidirectional protocol

**What goes wrong:**
In bidirectional JSON-RPC both peers issue requests and both maintain a pending map keyed by id. If both sides mint ids from the same space — the obvious `1, 2, 3...` counter on each side — then peer A's pending entry for id `7` can be resolved by a *response to peer B's request* `7`, or by a stale/duplicated response. The harness's own router is a bare `Map` lookup with no ownership check:

```ts
private handleIncomingResponse(id: JsonRpcId, frame): void {
  const pending = this.pending.get(id)
  if (!pending) return          // silently dropped
  ...
}
```

An id collision therefore delivers the **wrong result to the wrong caller**, typed as the wrong thing. In Haskell that is a `fromJSON` failure if you are lucky and a semantically wrong `Allow`/`Deny` if you are not.

The harness side happens to be safe by accident — it mints `req_${randomUUID()}` — but "safe by accident" is not a contract, and a future refactor could change it.

**Why it happens:**
JSON-RPC 2.0 says ids must be unique *within a client's requests*; it does not define behavior for two peers sharing a channel. Most people learn bidirectional JSON-RPC from LSP, where the same trap exists and is solved by convention rather than by the spec.

**How to avoid:**
- **Make the namespaces disjoint by construction and state it in the protocol doc.** Harness→plugin ids are prefixed `h:`; plugin→harness ids are prefixed `p:`. A one-character prefix makes a collision impossible and makes a misrouted frame obvious in a log.
- **Assert ownership on receipt.** Before looking a response id up in the pending map, check the prefix; an unowned id is a protocol violation, logged loudly, not a silent drop. Same for a response to an id that is not pending (currently `return`).
- **Never reuse an id.** Use a monotonic counter behind a `TVar` on the Haskell side (not a hash of the payload, not a wall-clock timestamp).
- Include ids in golden frame fixtures so a change to the scheme is a visible diff.
- Bear in mind `$/cancel {id}` refers to an id in the *other* peer's namespace. With prefixes this is unambiguous; without them it is a second collision surface.

**Warning signs:**
- Both sides start ids at `1`.
- A response handler that drops unknown ids without logging.
- A test suite that never runs a plugin→harness request concurrently with a harness→plugin request.

**Phase to address:** Phase 0 (protocol spec) / Phase 1 (transport). Cheap to get right up front, invasive to retrofit once fixtures exist.

---

### Pitfall 8: Cancellation races — `$/cancel` after completion, and cancel that does not reach quiescence

**What goes wrong:**
`$/cancel {id}` is a notification, so it is unordered with respect to the response for the same id. Four races:

1. **Cancel arrives after the reply was written.** The plugin looks up id `h:42`, finds nothing (already completed and removed), and — if written naively — either throws, logs an error, or worse, *creates* an entry so a later request reusing that id is instantly cancelled.
2. **Cancel arrives before the request.** TCP-like ordering on a pipe makes this impossible for a single peer, but it *is* possible for the bridge to fire `$/cancel` in the same tick it fires the request if the caller's `AbortSignal` was already aborted. `JsonRpcLineTransport.request()` handles the already-aborted case by rejecting before writing — the bridge must not send a bare `$/cancel` for a request it never sent.
3. **Cancel is acknowledged but the work continues.** `docs/defensive-patterns.md`: *"Dispose must reach quiescence, not just request it."* Flipping `Exec.cancelled :: STM Bool` does nothing unless the tool body actually polls it. A `readFile`-then-transform tool will finish anyway and reply with a result the harness has already abandoned — which then hits an unknown pending id.
4. **The signal is swapped underneath you.** `dsh-tool-call-timeout-policy` *mutates `exec` in place*, swapping a derived signal on for the downstream dispatch and restoring the caller's signal afterward. A bridge that captures `exec.signal` once at listener entry and stores it will be listening to the wrong signal.

**Why it happens:**
Cancellation is tested by cancelling early, never by cancelling in the microsecond the work completes.

**How to avoid:**
- **Cancellation is idempotent and total on both sides.** `$/cancel` for an unknown id is a *no-op that logs at debug*, never an error, never a state mutation. Ids are never reused (Pitfall 7), which is what makes this safe.
- **The cancelled request still replies.** Reply with a JSON-RPC error using a dedicated code (e.g. `-32800`, LSP's `RequestCancelled`) so the bridge can distinguish "cancelled" from "failed" from "still running." Never simply drop the request — that recreates Pitfall 5.
- **The bridge tolerates a late success after cancel.** Match the harness's rule: *"close listener/notification registries BEFORE killing so late completions stay silent."*
- **Read `exec.signal` at the moment of use, not at listener entry**, because the timeout policy swaps it.
- Model the plugin side with `STM`: the request registry is a `TVar (Map RequestId (TVar Bool))`; the handler runs under `Control.Concurrent.Async.race` between the work and `atomically (readTVar cancelled >>= check)`. This gives you real interruption of pure/allocating code (GHC can interrupt at allocation points), which polling cannot.
- Test: a tool that completes in ~0ms, cancelled in a tight loop; assert no unhandled error and no leaked pending entry on either side. Run it 1000 times.

**Warning signs:**
- `$/cancel` handler that does `error "unknown request"`.
- A cancelled request that produces no frame at all.
- `Exec.cancelled` documented but never checked in the example tool.

**Phase to address:** Phase 3 (tool seam) for the mechanism; Phase 4 (guard) confirms the fallback decision; a cancellation snapshot scenario in Phase 7. The harness's testing policy explicitly names "mid-stream cancellation" as required with-key coverage.

---

### Pitfall 9: EOF, SIGPIPE, and child-exit are three different events and each side handles only one

**What goes wrong:**
- **GHC does not die on SIGPIPE.** The RTS installs a handler for `SIGPIPE` (`rts/posix/Signals.c` installs an `empty_handler`; `resetDefaultHandlers` restores `SIG_DFL`), so a write to a closed pipe returns `EPIPE`, which surfaces as an `IOException` with `ioe_type = ResourceVanished` ("resource vanished (Broken pipe)"). A plugin that does not catch this dies with an ugly uncaught exception and a nonzero exit — or, if it catches broadly and continues, spins forever writing to a dead pipe. *Neither* is "shut down cleanly."
- **EOF on stdin is the shutdown signal, and it is easy to miss.** `BS.hGetLine` on a closed handle throws `isEOFError`; `hIsEOF` before every read is a race. A plugin whose reader thread dies on EOF while the main thread waits on an `MVar` hangs instead of exiting.
- **The bridge sees three separate Node events** — `exit`, `close`, `error` — plus stdin `end` and stdout `end`. `close` fires after all stdio is closed; `exit` fires before. Handling only `exit` means pending output is lost; handling only `close` means a spawn failure (`ENOENT` — a typo'd binary path) is reported as nothing at all. And `JsonRpcLineTransport.close()` *deliberately does not destroy the streams* ("detaches them and rejects pending requests without destroying the streams") — so the bridge owns stream teardown separately.
- **`shutdown` is a request, and the peer may exit before replying to it.** A bridge that `await`s the `shutdown` response hangs on a well-behaved peer that exits promptly.

**Why it happens:**
Each side is written against its own runtime's happy path. Nobody writes a test that `kill -9`s the peer mid-request.

**How to avoid:**
- Haskell: install a top-level handler that treats `ResourceVanished` on the framing handle as **normal shutdown, exit code 0** — the harness went away, there is nothing to report and nowhere to report it. Do not log it to stderr (stderr may also be gone).
- Haskell: one dedicated reader thread; EOF on stdin ⇒ signal a `TMVar` that the main loop selects on ⇒ run disposers ⇒ exit. Use `Control.Concurrent.Async.withAsync` + `race` so a reader-thread exception propagates to the main thread rather than silently killing the thread (a bare `forkIO` swallows it).
- Bridge: subscribe to **all** of `error`, `exit`, `close`, and stdin `end`; converge them into one `peerGone(reason)` that (a) fails all pending requests with a typed error, (b) unregisters all contributions, (c) is idempotent. Report the orthogonal facts independently — `docs/defensive-patterns.md`: *"a process can time out AND exit 0 because it trapped the signal. Surface each independent fact (`timedOut`, `signal`, `exitCode`) on its own."*
- Shutdown handshake: send `shutdown` as a request with a short deadline, then close stdin (the real EOF signal), then SIGTERM after a grace period, then SIGKILL — and **await the exit** before the disposer resolves. The harness's `SubprocessHandle.terminate` already implements SIGTERM→grace→SIGKILL tree-scoped; use `ctx.subprocess` rather than hand-rolling `child_process`.
- Test the spawn-failure path (`command: '/nonexistent'`) explicitly — the per-file 100% coverage gate will demand it anyway.

**Warning signs:**
- Bridge handles `exit` only.
- No `catch` around the framing `hPut`.
- `runPlugin` uses `forkIO` without `link`/`withAsync`.
- Disposer returns before the child has exited (check: is it `async`?).

**Phase to address:** Phase 1 (Haskell lifecycle) and Phase 6 (bridge lifecycle). Both are named in `docs/defensive-patterns.md`, which the harness requires you to read before subprocess/teardown work.

---

### Pitfall 10: Pipe-buffer deadlock — and the stderr channel nobody drains

**What goes wrong:**
A pipe holds ~64KB on Linux. Two deadlock shapes:

1. **Classic write-write deadlock.** Both sides block writing while neither reads. On the Node side this *cannot* happen — `stream.write()` buffers in the JS heap when the pipe is full and returns `false` rather than blocking (the harness transport ignores that return value entirely, which converts a deadlock into unbounded memory growth — see Pitfall 4). On the **Haskell** side it absolutely can: a single-threaded `forever $ readRequest >>= handle >>= writeResponse` loop that writes a 10MB result blocks in `hPut` once the pipe fills. If the bridge is concurrently sending frames, the plugin never gets back to reading, the bridge's writes buffer in the heap, and the plugin waits forever for a reader that is itself waiting.
2. **The undrained stderr pipe.** The far more common version. The bridge spawns with `stdio: ['pipe','pipe','pipe']` and only wires up `stdout`. The plugin logs to stderr. After 64KB of logs, **every `hPutStrLn stderr` blocks forever**, and because logging happens inside the request handler, the whole plugin wedges — while stdout looks perfectly healthy. This one is well documented in general (`haskell/process` issues; the standard "if the spawned process fills its stdout or stderr buffers it'll block") and is the classic subprocess bug.

**Why it happens:**
Development uses small payloads and a terminal-attached stderr, where neither bound is reachable.

**How to avoid:**
- **Bridge: always drain stderr.** Attach a `data` listener that forwards to `ctx.logger` (bounded/truncated), or use `stdio: [..., 'inherit']` in dev. Never leave a piped fd unread. The harness's subprocess seam already offers bounded collect-mode readers with spill files — use it rather than hand-rolled buffering.
- **Haskell: separate reader and writer threads with a bounded queue between them.** Reader thread: `hGetLine` → `atomically . writeTBQueue inbox`. Writer thread: `readTBQueue outbox` → `hPut`. Handler threads sit in the middle. A blocked writer then never blocks the reader. Use a **bounded** `TBQueue` so a runaway producer applies backpressure instead of growing the heap.
- **Build with `-threaded`.** GHC's IO manager makes handle IO yield rather than block the capability in both RTSes, so a `forkIO` reader is workable single-threaded — but `-threaded` is required for `async`'s `race`/`concurrently` to actually run in parallel, for safe FFI calls (a `safe` foreign call in the non-threaded RTS **blocks every other Haskell thread until it returns**), and for `System.Timeout.timeout` to be meaningful around anything that touches C. Set `ghc-options: -threaded -rtsopts "-with-rtsopts=-N"` in the cabal file and treat it as non-negotiable. A plugin that shells out via `System.Process` without `-threaded` will deadlock.
- Test with a 10MB tool result and 10MB of stderr logging, concurrently.

**Warning signs:**
- Bridge `spawn` options with a `'pipe'` fd and no listener.
- `runPlugin` implemented as one `forever` loop.
- `ghc-options` missing `-threaded`.
- Hang reproduces only when verbose logging is enabled.

**Phase to address:** Phase 1 (Haskell threading model — this determines the whole `runPlugin` architecture, so it cannot be retrofitted), Phase 6 (bridge stderr drain).

---

### Pitfall 11: Schema drift — `HasSchema` will emit JSON Schema the harness rejects

**What goes wrong:**
`PROJECT.md` proposes deriving JSON Schema from Haskell types via a `HasSchema` class with a `Generic` default. The harness does not accept arbitrary JSON Schema: `packages/core/tools/src/index.ts` imports `assertSupportedJsonSchema` and `validateJsonSchemaValue` from `./json-schema.ts`, and the exported vocabulary is a **closed** `JsonSchemaNode` / `JsonSchemaType` / `JsonSchemaScalar` set. Elsewhere the harness explicitly notes that "unsupported schema vocabulary falls back to unconstrained `JsonValue`" (mcp-client), i.e. your constraints are silently dropped.

A `Generic`-derived Haskell schema naturally wants to emit constructs that are likely outside that set:
- Sum types → `oneOf`/`anyOf` with a discriminator, or aeson's default tagged-object encoding (`{"tag":..., "contents":...}`).
- `Maybe a` → either an absent key or `"type": ["T","null"]` (a *type array*, which many validators accept and many restricted subsets do not).
- `Map Text v` → `additionalProperties`.
- Recursive types → `$ref`/`definitions`, which almost certainly are not supported.
- Phantom/newtype wrappers → nothing at all, or an unhelpful `{}`.

Separately, there are **two** validators in play and they must agree: the Haskell side validates before decoding, and the harness's `defineTool`/`validateArgs` validates the model's arguments before dispatch. Divergence means either (a) the harness accepts args Haskell then rejects — a confusing tool error the model cannot fix — or (b) Haskell accepts args the harness would have rejected, which is a validation bypass.

And the model *sees* this schema. `docs/AGENTS.md`/`packages/AGENTS.md`: *"Write model-facing contracts from the model's perspective... only task-relevant concepts, not UI, transport, or implementation vocabulary."* An aeson-derived `{"tag":"MkFoo","contents":[...]}` schema is Haskell implementation vocabulary leaking into the prompt.

**Why it happens:**
`Generic` derivation feels free. Nobody diffs the emitted schema against the consumer's accepted grammar until the tool is rejected at registration.

**How to avoid:**
- **Read `packages/core/tools/src/json-schema.ts` and `schema.ts` first and write the accepted vocabulary down** as the target of `HasSchema`. Do this in Phase 2, before writing derivation code. The harness's `ValueSchemaSpec` union (`StringValueSchemaSpec`, `NumberValueSchemaSpec`, `IntegerValueSchemaSpec`, `BooleanValueSchemaSpec`, `NullValueSchemaSpec`, `ArrayValueSchemaSpec`, `ObjectValueSchemaSpec`, `JsonValueSchemaSpec`, `OneOfValueSchemaSpec`) is effectively the shopping list — note `OneOfValueSchemaSpec` *does* exist, so sums are expressible, but on the harness's terms not aeson's.
- **Make `HasSchema` total over a restricted type vocabulary, not over `Generic`.** Instances for the supported shapes; a *compile error* (or at minimum a loud runtime failure at `runPlugin` startup) for anything else. "Misconfiguration fails loud" is a stated harness convention.
- **`--dump-manifest` + a checked-in golden schema per example tool**, plus a bridge-side test that feeds `--dump-manifest` output through the harness's own `assertSupportedJsonSchema`. This is the *only* mechanical cross-language guard available, and it is exactly the pattern `code-runtime-python` uses (`tests/protocol-mirror.e2e.ts` spawns real `python3` and diffs field sets against `src/protocol.ts`). Note its honest limitation: it compares *field sets*, not *field types* — expect the same gap here and document it.
- **Validate once, authoritatively, on the harness side; validate defensively on the Haskell side.** Do not treat the Haskell check as the enforcement point (`packages/AGENTS.md`: *"Enforce a decision in the operation that makes it"*).
- Snapshot the rendered tool schema as it appears in the system prompt — the harness's `text-turn` ACP scenario pins full tool-schema content for exactly this reason.

**Warning signs:**
- `deriving anyclass HasSchema` on a sum type with record constructors.
- A manifest golden file containing `$ref`, `anyOf`, `definitions`, or `"type": ["string","null"]`.
- Tool registration succeeding but the model never using the tool correctly.

**Phase to address:** Phase 2 (schema derivation). The vocabulary reconnaissance is Phase 0 homework.

---

### Pitfall 12: HMR restart leaves orphan processes and duplicate registrations

**What goes wrong:**
Cordis's whole model is that "registrations are reversible effects" and the loader hot-reloads on `cordis.yml` change. The bridge's disposer must therefore kill the peer *and wait for it*. Failure modes:

- **Orphans.** Dispose sends SIGTERM and returns. The old peer is still alive, still holding a lock/port/temp file. Edit the config ten times and you have ten GHC processes. `docs/defensive-patterns.md` names this: *"A teardown that issues kills/aborts but returns before the work stops leaves orphans. Make cleanup async and await the children's exit."*
- **Process trees.** If the Haskell plugin spawned its own children, killing the plugin leaves grandchildren. The harness's subprocess seam terminates *tree-scoped* — hand-rolled `child.kill()` does not.
- **Duplicate tool names.** New instance registers `myTool` before the old instance's registration is disposed → the tools registry rejects (or worse, silently shadows). `mcp-client` handles the analogous case by rolling back the whole generation rather than leaving a partial set; the bridge needs the same discipline.
- **Late frames from the old peer** resolving pending entries in the *new* transport, if any state is shared.
- **Windows.** SIGTERM does not exist; `taskkill /T` semantics differ; a GHC console app may not exit on the equivalent of Ctrl-Break. The harness runs a Windows CI lane, so this will be caught — late.

**Why it happens:**
Disposal is written last and tested by "it seems to work."

**How to avoid:**
- Spawn through `ctx.subprocess` (`SubprocessHandle.terminate` = SIGTERM→grace→SIGKILL, tree-scoped) rather than `node:child_process`.
- Disposer sequence, in order: (1) close the transport's listener/notification registries so late frames are silent, (2) fail pending requests, (3) unregister contributions, (4) send `shutdown` + close stdin, (5) `await handle.done` with a grace deadline, (6) `terminate()` and await again. Return only after the child is confirmed gone.
- **Write the HMR-safety test the harness requires:** `packages/AGENTS.md` — *"Registry contributions prove disposal through the HMR-safety test... dispose the fiber and observe removal."* Extend it: also assert the OS process is gone (`process.kill(pid, 0)` throws `ESRCH`).
- Guard against reload storms: debounce, and refuse to spawn a new peer while the previous one is still terminating.
- Give each spawned peer a distinguishable argv marker so an orphan hunt is possible (`--dsh-instance <id>`).

**Warning signs:**
- `ps aux | grep <plugin>` shows more than one after a few reloads.
- A disposer that is not `async` or does not `await`.
- Second `pnpm dsh` run fails with a duplicate registration.

**Phase to address:** Phase 6 (bridge). The HMR-safety test is a hard gate — the package cannot merge without it.

---

### Pitfall 13: A remote prompt section breaks determinism, replay, and the KV cache

**What goes wrong:**
`Section` (a prompt-section provider) is different in kind from `Tool` and `Guard`, and this is easy to miss because they sit next to each other in the `Plugin` record.

- **It blocks every request, not one tool call.** Prompt assembly happens before *each* model request. A slow or hung `section/render` stalls every turn (compare Pitfall 5, but with 100% blast radius).
- **It violates "model-visible ⟺ logged."** The harness convention is absolute: *"anything that reaches a model request must be reconstructable from the session log; a new model-visible input requires a session event."* Text produced by an out-of-process peer at assembly time is not reconstructable from the log unless the bridge emits a session event carrying it. That means declaring a new `SessionEventMap` member — which per `CLAUDE.md` requires `@mode` and `@param` JSDoc, is *required-on-read by default* unless marked `ignorable: true`, and pulls in the `verify-scoped-events` and `verify-persistence-catalog` gates.
- **It destroys the KV cache.** A section whose content varies per turn (a timestamp, a counter, live state) invalidates the provider's prefix cache on every request — a large, silent cost increase. Every harness package README must carry a `#### KV Cache effect` subsection precisely because this is a recurring mistake.
- **Snapshots become nondeterministic.** The keyless snapshot suite diffs the assembled request. A section that varies breaks the fixture on every run.

**Why it happens:**
"It's just a string" — the coupling to logging, caching, and snapshot determinism is invisible from the Haskell side.

**How to avoid:**
- **Prefer static sections resolved at handshake time.** If the section content can be computed once, ship it in the manifest and register it as a constant. This eliminates the per-turn call, the logging problem, and the cache problem in one move.
- If dynamic sections are genuinely needed, treat it as a **separate, later phase** with its own session event, its own snapshot scenario, and an explicit KV-cache note. Do not bundle it with Tool/Guard.
- Give `section/render` a hard deadline whose fallback is "omit this section," never "fail the turn."
- Consider deferring `Section` out of v1 entirely and documenting it under `## Known Limitations and Deferred Work`.

**Warning signs:**
- A section renderer that reads a clock, a counter, or mutable state.
- No session event associated with section content.
- A snapshot fixture that needs a normalizer for section text (the harness's rule: *"fix fixtures, not normalizers"*).

**Phase to address:** Phase 5 (section/subagent seams) — or Phase "deferred." Decide in Phase 0 which.

---

### Pitfall 14: Stack/GHC reproducibility and CI cost

**What goes wrong:**

- **The pin is already stale and mis-chosen.** `PROJECT.md` pins `lts-22.43`. As of 2026-08-25, Stackage's LTS-22 series has moved on (LTS 22.44, GHC 9.6.7), and the current series is **LTS 24.56 (GHC 9.10.3)**, with LTS 23.28 (GHC 9.8.4) in between and nightly on GHC 9.12.4. Pinning to a two-major-series-old GHC is a defensible reproducibility choice, but it must be a *deliberate, documented* one, because it determines which Hackage packages you can use without `extra-deps`.
- **The JSON-RPC dependency does not exist in the pinned snapshot.** `jsonrpc` (types + typeclasses only, 0.2.0.0, uploaded 2026-02-16, maintainer `tritlo`) is **not in lts-22.43**. `json-rpc` (1.1.3, uploaded 2026-08-18, maintainer `jprupp`) is actively maintained but pulls `conduit`, `conduit-extra`, `monad-logger`, `unliftio`, `unordered-containers`, and `attoparsec` — a large transitive surface for a project whose entire wire need is "one JSON object per line." Either choice means `extra-deps`, which means transitively pinning their deps too, which is where reproducible-build promises quietly die.
- **CI cost.** A cold Stack build downloads a GHC toolchain (hundreds of MB) and compiles the dependency closure. `aeson` alone is minutes. Without caching `~/.stack` **and** `.stack-work` keyed on `stack.yaml.lock` + `package.yaml`, every CI run is 10-20 minutes. With caching but a wrong key, you get silent staleness.
- **`-threaded` is not the default.** See Pitfall 10. Also `-rtsopts` is needed if you want `+RTS` flags, and `-with-rtsopts=-N` to use more than one core.

**Why it happens:**
The resolver was chosen by `stack new` from a template, not by requirement analysis.

**How to avoid:**
- **Re-derive the pin from the dependency requirements, in Phase 0.** Decide the JSON-RPC dependency first, then pick the newest LTS that contains it (or contains everything else, if you own the framing). Record the decision and the review date in `PROJECT.md`. Given `jsonrpc` is types-only and `json-rpc` is transport-heavy, the honest third option — **own ~150 lines of aeson framing** — is likely correct here and should be evaluated on equal footing rather than dismissed by the dependencies-over-hand-rolling policy (that policy says "when they genuinely delete owned code and tests"; a types-only package deletes very little).
- Commit `stack.yaml.lock`. Treat resolver bumps as their own PR with the golden fixtures re-run.
- CI: cache `~/.stack` and `.stack-work` keyed on `hashFiles('stack.yaml.lock', 'package.yaml')`; build deps in a separate cached step (`stack build --only-dependencies`) so a source-only change is fast.
- `ghc-options: -threaded -rtsopts -Wall -Werror "-with-rtsopts=-N"` from commit one.
- Add `-Wall -Werror` plus `-Wincomplete-uni-patterns` and `-Wpartial-fields` early; retrofitting them across a codebase is miserable.

**Warning signs:**
- `stack.yaml` has `extra-deps` entries without corresponding `stack.yaml.lock` hashes.
- CI Haskell job over 10 minutes on a no-op commit.
- The resolver has not been reviewed since project init.

**Phase to address:** Phase 0 (toolchain + dependency decision). This gates everything and is nearly free to do right at the start.

---

### Pitfall 15: The deepseek-harness contribution gauntlet — especially the "keyless snapshot needs GHC, but CI has no GHC" trap

**What goes wrong:**
This is the highest-risk item in the project because it is a *process* constraint that invalidates work already done.

**The core tension.** `docs/testing.md` is unambiguous:

> Every non-trivial model-, protocol-, or human-visible change adds or updates a keyless scenario in the same PR **through a runnable example's owning snapshot suite**. Package tests, e2e assertions, mock/test-only compositions, and PR rationale **do not replace the assembled transcript**.

`PROJECT.md`'s stated core value is a keyless snapshot of a model calling the Haskell tool. So the snapshot must boot a real `dsh` composition, which must spawn a real peer binary. **`deepseek-harness` CI has no Haskell anywhere**: the workflow set (`ci.yml`, `ci-master.yml`, `e2e.yml`, …) sets up Node and Python only; there is no `haskell-actions/setup`, no GHC, no Stack. Verified by grep across `.github/workflows/`.

The three ways out, none free:

- **(a) Add a Haskell CI job to deepseek-harness.** Precedent exists — `python-runtime` is a distinct required job (`ci.yml:301`) that only runs the Python SDK snapshot. But this asks the harness maintainers to take on a GHC toolchain, minutes of CI time, and a cross-repo binary dependency. Get agreement *before* building.
- **(b) Ship a checked-in prebuilt echo binary.** Platform matrix (Linux/macOS/Windows, x64/arm64), binary size in git, and provenance make this unattractive.
- **(c) Write the snapshot's peer in Node**, speaking the same protocol, and rely on `--dump-manifest` + a cross-language mirror test (the `code-runtime-python` `protocol-mirror.e2e.ts` pattern) to prove the Haskell side agrees. This is the pragmatic answer, but it directly collides with *"Prefer the real implementation over a mock"* and *"mock/test-only compositions do not replace the assembled transcript."* It needs an explicit, argued exception in the Agent Note.

**The other gates**, each capable of blocking the bridge PR:

- **Per-file 100% line/branch/function coverage** on `packages/*/*/src` (`pnpm run test:coverage`). Every error branch in the bridge — spawn `ENOENT`, malformed handshake, protocol-version mismatch, frame over budget, peer death during each of five request types, cancel-after-complete, duplicate tool name — needs a test. `vitest.config.ts` shows the *only* sanctioned escape is a documented exemption (the `pwsh-local` precedent, plus the Windows-only and spawned-entry exclusions). Budget roughly as much test code as source code.
- **The `doc-sync` battery.** ~25 verifiers run (`scripts/run-gates.ts`), including: `verify-translation-pairing` (the README needs a `README.zh.md` **and** a `README.i18n.yaml`), `verify-md-wrap` (one physical line per paragraph), `verify-doc-budgets` (word ceilings), `verify-package-readme-model-experience` (mandatory `## Model Experience` + `#### KV Cache effect`), `verify-package-readme-limitations` (mandatory `## Known Limitations and Deferred Work` or an allowlist entry), `verify-export-jsdoc` (`@param`/`@returns` on every function-like export), `verify-config-catalog`, `verify-tool-catalog`, `verify-cordis-config`, `verify-runtime-closure` (bare plugins in `cordis.yml` must appear in the resolver manifest's `dependencies`), `verify-package-invariants`.
- **`./invariant` is mandatory.** *"Every package owns `./invariant`. Register the manifest name; check an event/data relation or give empty installers package-specific `No runtime invariant:` reasons. Generated companions, unexplained empties, and ignored reporters fail."* And per `CLAUDE.md`, an invariant must assert an *owned relationship* over authoritative event streams or mutable data — not "the service exists."
- **Agent Note required in the same PR** for any non-trivial change, in `.agents/notes/`, passing `verify-agent-note-format` and `verify-agent-note-classification`.
- **No hardcoded tunables.** Every deployment-varying value — binary path, args, cwd, env, `maxFrameBytes`, `handshakeTimeoutMs`, `requestTimeoutMs`, `shutdownGraceMs`, restart policy — is a validated `Config` field. *"A `DEFAULT_*` constant or test hook is not configurability."*
- **Opaque cross-boundary ids are branded** (`Branded<B>` from `dsh-brand`), never bare `string`. Request ids qualify.
- **Both SDKs project the loop.** If anything touches `SessionEventMap`, agent-loop, or session lifecycle, *both* the TypeScript (`examples/jsonrpc-agent`) and Python (`scripts/snapshots/python-sdk-single-exe`) SDK expected outputs update in the same PR — and `pnpm run test` covers neither.
- **Cross-repo split.** `PROJECT.md` already notes it: this repo cannot merge the e2e requirement alone. Sequencing matters — the harness PR needs the protocol frozen, and the Haskell repo needs the harness PR to demonstrate value.

**Why it happens:**
The Haskell work is fun and self-contained; the harness PR feels like "just the glue." The gates are discovered at PR time.

**How to avoid:**
- **Phase 0 deliverable: an alignment note filed as a deepseek-harness issue/discussion** covering (i) the snapshot-peer strategy, (ii) whether a GHC CI job is acceptable, (iii) the coverage exemption if any. Get a maintainer answer before Phase 1.
- Write the bridge package skeleton (README with all gated sections, `invariant.ts`, `Config`, `tsconfig.json` with the required references, `package.json`, i18n yaml) **first, as an empty package that passes `doc-sync` and `hygiene`**, then fill it in. Discovering `verify-doc-budgets` at the end is worse than at the start.
- Run `pnpm run doc-sync` and `pnpm run hygiene` from the first commit of the bridge, not at PR time.
- Follow `docs/cookbook/adding-a-package.md` and `docs/cookbook/adding-a-tool.md` literally.
- Use the `dsh-pre-push-checks` skill rather than guessing which checks apply.

**Warning signs:**
- The roadmap has no phase for the harness-side PR's *gates*, only its *features*.
- No `README.zh.md` in the bridge package.
- The plan assumes the snapshot "just works" with the Haskell binary.
- No deepseek-harness maintainer has seen the protocol yet.

**Phase to address:** Phase 0 (alignment + skeleton) and Phase 7 (e2e/snapshot). Treat the CI question as a **blocking prerequisite**, not a late-phase task.

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Reuse the harness's `JsonRpcLineTransport` verbatim for the peer | Zero transport code on the bridge side; already tested | It silently drops malformed lines, has no frame-size cap, and has no request timeout — all three are wrong for a model-influenced peer (Pitfalls 1, 4, 5) | Only as a *starting point* that you immediately wrap with a bounded reader, a malformed-line log, and per-call deadlines |
| `deriving anyclass HasSchema` via `Generic` for every type | Instant schemas | Emits vocabulary the harness silently drops or rejects; leaks aeson's `tag`/`contents` encoding into the model-facing prompt (Pitfall 11) | Never for model-facing argument types. Fine for internal wire envelopes |
| Skip `presentCall`/`presentResult`, accept generic rendering | Removes the hardest design problem from v1 | Bridged tools look worse than native ones in the CLI/web UI; retrofitting needs a manifest format change | **Acceptable and recommended for v1** — document under Known Limitations |
| Node-based reference peer for the keyless snapshot | Unblocks CI without GHC | Snapshot proves the *bridge* works, not that *Haskell* works; needs an argued exception to the "prefer the real implementation" policy | Acceptable **only** with a companion cross-language mirror test (`--dump-manifest` diffed against the harness's own schema validator) and an explicit Agent Note |
| Hand-roll the JSON-RPC framing instead of taking a Hackage dep | ~150 lines, zero transitive deps, exact control over bounds and hostile-input handling | Owned code and owned tests; the harness's stated preference is maintained deps | **Likely correct here.** `jsonrpc` is types-only (deletes almost nothing); `json-rpc` drags conduit + monad-logger + unliftio for a line-delimited pipe. Argue it explicitly rather than defaulting to it |
| Single-threaded `forever $ read >>= handle >>= write` loop in `runPlugin` | Simplest possible implementation; easy to reason about | Cannot handle concurrent requests, cannot cancel in-flight work, deadlocks on a full pipe (Pitfall 10). Retrofitting concurrency changes every handler signature | Never — the reader/handler/writer split is Phase 1 architecture, not an optimization |
| Fire-and-forget `$/cancel` with no acknowledgement | Simple | The bridge cannot distinguish "cancelled cleanly" from "still running"; `ToolDefinition.timeoutMs`'s quiescence assertion becomes a lie | Only if the tool seam does not declare `timeoutMs` |
| Ship without bounding `Scientific` exponents | Nothing to write | A model-supplied `1e1000000000` in a tool argument hangs or OOMs the plugin (HSEC-2023-0007 class) | Never — it is a five-line helper |
| Pin `lts-22.43` because that is what `stack new` produced | Already done | Two LTS majors behind; forces `extra-deps` for anything recent; the "reproducible" claim is unexamined | Only after deliberately re-deriving it from the dependency set |

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| `ctx.tools.register()` | Implementing `output.render` as `async`, or calling the peer from it | Pure sync lookup into a per-execution cache populated by the preceding `tool/execute` reply (Pitfall 3) |
| `tools/pre-execute` (waterfall) | `await`ing a remote decision with no timeout; forgetting `next()` on the `Allow` path | Deadline with a defined fallback *decision*; `next()` reached from a `finally` (Pitfall 5) |
| `tools/post-execute`, `agent/pre-step` | Assuming all interception points are waterfalls | Check `@mode` per event: `emit` points run detached and cannot block; `serial` differs again |
| `ToolDefinition.timeoutMs` | Declaring it without forwarding `exec.signal` to the peer | Declaring it *asserts* cooperative quiescence — send `$/cancel` and await acknowledgement |
| `exec.signal` | Capturing it once at listener entry | `dsh-tool-call-timeout-policy` mutates `exec` in place to swap signals; read at point of use |
| Session log | Letting peer output reach the model without a session event | "Model-visible ⟺ logged." A new model-visible input requires a `SessionEventMap` member with `@mode` + `@param` JSDoc |
| `ctx.subprocess` | Using `node:child_process` directly | The seam gives tree-scoped SIGTERM→grace→SIGKILL, credential-scrubbed env, bounded collect readers with spill |
| Spawn env | Passing the ambient env, or an empty env | `scrubbedParentEnv()` + explicit `LANG`/`LC_ALL` UTF-8 (Pitfall 2) + explicit `Config.env` |
| Cordis plugin export shape | Mixing a default export with named `name`/`inject`/`apply` | Postmortem 0001: the Loader discards the function plugin's namespace. Assert `expect('default' in mod).toBe(false)` |
| Optional services | `ctx.approval` for a service that may not be mounted | `ctx.get('approval')` — the property proxy is topology-sensitive |
| `cordis.yml` in a test/example | Bare plugin name not in the resolver manifest's `dependencies` | `verify-cordis-config` fails the build |
| aeson `FromJSON` | Default `Generic` instance silently ignores unknown fields | Reject unknown fields explicitly — silent acceptance is a forged-field vector |

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| Per-request process spawn instead of a long-lived peer | Multi-second tool latency; process table churn | One peer per plugin instance, spawned at activation, reused across calls | Immediately — GHC binaries start fast (~ms) but spawn + handshake + page-in is still 10-100× a wire round trip |
| Unbounded `this.buffer +=` in the frame reader | Node RSS climbs during a large tool result; eventual OOM | `maxFrameBytes` cap on both sides | A single result over ~100MB, or a peer that never emits `\n` |
| Ignoring `stream.write()` backpressure on the bridge | JS heap grows while the peer is slow | Respect the return value; pause request dispatch on `false` until `drain` | A peer slower than the harness's request rate — reachable with parallel tool calls |
| Undrained stderr pipe | Plugin wedges after ~64KB of logs; stdout looks healthy | Always attach a `data` listener to every piped fd | ~64KB of log output — one verbose session |
| Dynamic prompt section varying per turn | Token cost per turn jumps; provider cache-hit rate collapses | Static sections resolved at handshake; document `#### KV Cache effect` | Every request, from turn 2 onward |
| `String`-based framing instead of `ByteString` | CPU burn and allocation on large results | `Data.ByteString` + `encode`/`eitherDecodeStrict'` end to end | Results over ~1MB |
| Unbounded queue between reader and handlers | Heap growth under burst; no backpressure | `TBQueue` with a fixed bound | A burst of parallel tool calls (the harness dispatches concurrency-safe tools in parallel) |
| Cold Stack build in CI | 10-20 min per run | Cache `~/.stack` + `.stack-work` keyed on `stack.yaml.lock` + `package.yaml`; separate `--only-dependencies` step | Every run, from day one |

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| Trusting inbound frames because "we wrote both sides" | Tool arguments are model-controlled; a prompt-injected model can steer frame content | Validate **and rebuild** every inbound frame, mirroring `validateChildFrame`. Forged extra fields must not ride along; a non-number id must never be echoed into a reply |
| Echoing a peer-supplied id into a reply without validation | Type confusion; pending-map poisoning | Namespace-prefixed ids + ownership check on receipt (Pitfall 7) |
| No frame-size bound | Memory-exhaustion DoS from either side | `maxFrameBytes` hard cap; exceeding it kills the peer loudly |
| `realToFrac` / `truncate` / `read` on a wire-supplied `Scientific` | CPU/memory exhaustion from `1e1000000000` (HSEC-2023-0007; aeson #198) | Bound `base10Exponent` before any conversion; use a shared `boundedScientific` helper |
| Forwarding the ambient environment to the spawned peer | Harness credentials (`*KEY*`, `*SECRET*`, `*TOKEN*`, `*PASSWORD*`) leak into the plugin's `env`, logs, and any spill file | `scrubbedParentEnv()` — the harness's stated rule: *"Never hand untrusted output the ambient environment or predictable paths"* |
| A guard that fails open on peer death without saying so | A security control silently stops enforcing | Fail-closed by default for guards; make the choice a `Config` field and state it in the README |
| Binary path from user config with no validation | Arbitrary code execution via a crafted `cordis.yml` | Same trust level as any `cordis.yml` plugin — but validate existence/executability at load and fail loud, per "misconfiguration fails loud" |
| Peer-controlled log text written unescaped to the session log or terminal | Terminal escape injection; log forging | Sanitize control characters before logging or persisting peer strings |
| Temp/spill files for large payloads in a shared directory | Symlink race, information disclosure | Private 0700 dir, random names, exclusive `'wx'` / `0o600` opens (harness rule) |

## UX Pitfalls

| Pitfall | User Impact | Better Approach |
|---------|-------------|-----------------|
| Peer crash surfaces as a silent hang | User waits, then Ctrl-C, with no idea why | Every peer-death path produces a typed, user-visible error naming the plugin and the exit facts (`exitCode`, `signal`, `timedOut` — reported independently) |
| Haskell-flavored errors reaching the model | The model sees `Left (ParseError "expected Object, got Array")` and cannot act on it | Model-facing text contains only task-relevant concepts. Map peer errors into the harness's structured tool-result vocabulary |
| Generic tool rendering for every bridged tool | Bridged tools look second-class next to native ones in the CLI/web UI | Accept for v1 and *say so* in Known Limitations; ship declarative render intent in v2 |
| `--dump-manifest` output that is not the actual handshake | Manifest snapshot drifts from runtime behavior | The flag must print the *same* value `runPlugin` sends, from the same code path |
| Protocol-version mismatch reported as a parse error | User cannot tell "rebuild your plugin" from "your plugin is broken" | Fail loud with an explicit message naming both versions — the pre-1.0 stance means this *will* happen often |
| Stack build failure surfacing as "plugin not found" | User debugs the wrong layer | Bridge validates the binary exists and is executable at load, with a distinct error |

## "Looks Done But Isn't" Checklist

- [ ] **stdout discipline:** `hDuplicateTo stderr stdout` installed so stray `putStrLn` anywhere (including in a dependency) cannot corrupt frames — verify by adding a `putStrLn "boom"` to the example tool and asserting the session still works
- [ ] **Buffering:** verified with the peer spawned from a *pipe*, not a TTY — verify the handshake arrives before the peer exits
- [ ] **Encoding:** works with `LANG` and `LC_ALL` unset — verify by clearing them in the bridge's spawn env in one test, with a non-ASCII tool result
- [ ] **Newlines:** golden fixtures byte-identical on macOS and Linux — verify with a payload containing a literal `\r` inside a JSON string
- [ ] **Frame bound:** a peer that writes 100MB without `\n` fails loudly and promptly — verify Node RSS does not climb past the cap
- [ ] **Number losslessness:** a tool returning `9007199254740993` round-trips exactly, or is rejected at schema time — verify through a real `JSON.parse`, not a Haskell-only round-trip
- [ ] **Timeouts:** a peer that receives `guard/decide` and never replies still lets the turn complete — verify the fallback decision is the documented one
- [ ] **Cancel-after-complete:** 1000 iterations of cancel racing a ~0ms tool produce no error and no leaked pending entry on either side
- [ ] **Peer death:** killed with SIGKILL mid-`tool/execute` produces a typed user-visible error, not a hang — and separately for each of the five request types
- [ ] **Spawn failure:** `command: '/nonexistent'` produces a distinct, actionable error and does not wedge activation
- [ ] **stderr drain:** the peer emitting 10MB of logs does not wedge — verify with logging inside the request handler
- [ ] **HMR:** ten config edits leave exactly zero orphan processes — verify with `process.kill(pid, 0)` throwing `ESRCH`, and assert tool names re-register cleanly
- [ ] **Schema:** every example tool's `--dump-manifest` output passes the harness's own `assertSupportedJsonSchema` — verify in a test, not by eye
- [ ] **Coverage:** `pnpm run test:coverage` passes at per-file 100% for the bridge package with no new exemption (or with a documented, argued one)
- [ ] **Docs:** `pnpm run doc-sync` passes — includes `README.zh.md`, `README.i18n.yaml`, `## Model Experience`, `#### KV Cache effect`, `## Known Limitations and Deferred Work`, one-line-per-paragraph wrapping, word budgets
- [ ] **Invariant:** `src/invariant.ts` asserts an owned event/data relationship (not service presence), or carries a package-specific `No runtime invariant:` reason
- [ ] **HMR-safety test:** dispose the fiber, observe registry removal — required for every registry contribution
- [ ] **Agent Note:** filed in the same PR, passing `verify-agent-note-format` and `verify-agent-note-classification`
- [ ] **Snapshot:** the keyless scenario runs in deepseek-harness CI *as configured today* — verify by reading `.github/workflows/ci.yml`, not by assuming
- [ ] **`-threaded`:** present in `ghc-options`, with a test that exercises concurrent request handling
- [ ] **`stack.yaml.lock`:** committed, and the resolver choice justified in writing

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| Stray stdout writes corrupting frames | LOW | Add `hDuplicateTo stderr stdout` in `runPlugin`; add the regression test. Four lines, no protocol change |
| Block buffering | LOW | Explicit `hFlush` after each frame |
| Locale/encoding failure | LOW-MEDIUM | Switch the framer to `ByteString` IO. Localized to the codec module if the framer was isolated; invasive if `Handle` text IO leaked into handlers |
| Unbounded frames | LOW | Add the cap in both readers plus a `Config` field. No protocol change |
| Missing request timeouts | MEDIUM | Plumb deadlines through every remote call **and decide a fallback decision per seam** — the second half is a design question, not a code change, and needs README/Agent Note updates |
| Id collisions | MEDIUM | Add namespace prefixes; re-record every golden fixture; coordinate the bridge and plugin releases (no compatibility promise pre-1.0 makes this survivable) |
| Number precision loss | MEDIUM-HIGH | If caught before release: change the schema policy, re-derive schemas, re-record fixtures. If caught after: rounded values are already in users' session logs and are unrecoverable |
| Pure-`render`-across-the-wire design | **HIGH** | Requires changing the `tool/execute` response shape, the manifest format, the bridge's registration path, and every fixture. This is why it belongs in Phase 0 |
| Wrong threading model in `runPlugin` | **HIGH** | Reader/handler/writer split changes every handler signature and the public `Exec` type. Phase 1 architecture |
| No GHC in deepseek-harness CI | **HIGH** | If discovered at PR time, the whole e2e phase is blocked pending a maintainer decision that may take weeks. Resolve in Phase 0 |
| Doc-sync / coverage gates discovered late | MEDIUM | Mechanical but voluminous — assume 1-2 days of pure gate-satisfaction work if the package skeleton was not gate-clean from commit one |
| Orphan processes | LOW-MEDIUM | Rewrite the disposer to await quiescence; extend the HMR test to assert process death |

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| 3. Pure sync `render` cannot cross a wire | **Phase 0** (protocol design) | A written decision record naming option A/B/C; bridge `ToolDefinition` compiles with a synchronous `render` |
| 6. Number precision | **Phase 0** (number policy) + Phase 2 (enforcement) | Round-trip property test through a real `JSON.parse`; `HasSchema` refuses unbounded `Integer` |
| 7. Id collisions | **Phase 0** (spec) + Phase 1 | Golden fixtures show prefixed ids; unowned-id receipt logs loudly |
| 14. Toolchain / resolver / dependency choice | **Phase 0** | `stack.yaml.lock` committed; resolver justified in `PROJECT.md`; CI Haskell job under 5 min warm |
| 15. Harness CI has no GHC; snapshot strategy | **Phase 0** (blocking prerequisite) | A maintainer-answered issue in deepseek-harness before Phase 1 starts |
| 1. stdout buffering / stray writes | Phase 1 (transport) | `putStrLn "boom"` in the example tool does not break the session; pipe-spawned handshake test |
| 2. Encoding / CRLF | Phase 1 (transport) | Test with cleared `LANG`; emoji + CJK + `\r` golden; fixtures byte-identical across macOS/Linux |
| 4. Unbounded frames / hostile input | Phase 1 (byte bound) + Phase 2 (value bound) | 100MB-line test; deep-nesting, huge-exponent, forged-field, duplicate-key property tests |
| 9. EOF / SIGPIPE / exit | Phase 1 (Haskell) + Phase 6 (bridge) | SIGKILL-mid-request test per request type; `ENOENT` spawn test; `ResourceVanished` exits 0 |
| 10. Pipe deadlock / `-threaded` | Phase 1 (threading architecture) + Phase 6 (stderr drain) | 10MB result + 10MB stderr concurrently; `ghc-options` contains `-threaded` |
| 11. Schema drift | Phase 2 (schema derivation) | `--dump-manifest` output passes the harness's `assertSupportedJsonSchema` in a test; tool-schema snapshot |
| 8. Cancellation races | Phase 3 (tool seam) | 1000× cancel-racing-completion loop; no leaked pending entries; late success after cancel is silent |
| 5. No timeout / waterfall `next()` | Phase 4 (guard seam) | Peer that never replies to `guard/decide` still lets the turn complete with the documented decision |
| 13. Remote prompt sections | Phase 5 (or deferred) | Section content is reconstructable from the session log; snapshot is deterministic with no new normalizer |
| 12. HMR orphans / duplicate registrations | Phase 6 (bridge) | HMR-safety test disposes the fiber, observes registry removal *and* `ESRCH` on the pid |
| 15. Contribution gates (coverage, docs, note) | Phase 6 (skeleton first) + Phase 7 | `pnpm run test:coverage`, `pnpm run doc-sync`, `pnpm run hygiene` green from the bridge's first commit |

## Sources

**Primary — deepseek-harness source, read directly (HIGH confidence)**

- `packages/sdk/protocol/src/transport.ts` — `JsonRpcLineTransport`: unbounded `buffer +=`, silent `JSON.parse` catch, no request timeout, `req_<uuid>` id minting, `close()` does not destroy streams
- `packages/core/tools/src/index.ts` — `ToolOutputDefinition.render` / `presentationMeta` / `presentCall` / `presentResult` / `finalizeContent` purity + synchrony contracts; `timeoutMs` quiescence assertion; `render` call site at line 1800
- `packages/code-runtime/code-runtime-python/README.md` — hostile-frame validate-and-rebuild doctrine; `hasUnsafeIntegerToken` raw-text scan; `BigInt` digit serialization; the honest limitation of a field-set-only cross-language mirror test
- `docs/defensive-patterns.md` — orthogonal outcome reporting; dispose-to-quiescence; callback containment; scrubbed env and private temp dirs; the "nothing to wait for" hang
- `docs/testing.md` — per-file 100% coverage gate; keyless snapshot requirement and its "does not replace the assembled transcript" clause; real-entry-path rule; both-SDKs rule; `pwsh-local` exemption precedent
- `docs/cordis-primer.md` — waterfall `next()` semantics; dispatch modes
- `packages/AGENTS.md` — mandatory `./invariant`; HMR-safety test; model-facing contract rules; enforce-at-the-operation rule; README gated sections
- `CLAUDE.md` / root `AGENTS.md` — model-visible ⟺ logged; no hardcoded tunables; branded ids; misconfiguration fails loud; Agent Note requirement
- `packages/guard/timeout-policy/README.md` — in-place `exec` signal swap
- `packages/mcp/mcp-client/README.md`, `src/transport.ts` — generation rollback, reconnect budget, `scrubbedParentEnv` usage
- `packages/hooks/hooks-claude-code/README.md` — out-of-process interception mapping onto typed decisions; detached emit points
- `packages/subprocess/subprocess/src/index.ts:60` — `scrubbedParentEnv` implementation
- `scripts/run-gates.ts` — the ~25 `doc-sync` verifiers
- `vitest.config.ts` — coverage exemption mechanism and precedents
- `.github/workflows/*.yml` — Node and Python setup only; `python-runtime` as the precedent for a separate-runtime required job; **no GHC/Stack anywhere**

**Haskell / GHC ecosystem (MEDIUM-HIGH confidence)**

- [GHC.IO.Handle (base)](https://hackage.haskell.org/package/base/docs/GHC-IO-Handle.html) — buffer modes, `hSetBuffering`, `hDuplicate`/`hDuplicateTo`, concurrency-safety note
- [GHC User's Guide — Using Concurrent Haskell](https://downloads.haskell.org/ghc/latest/docs/users_guide/using-concurrent.html) and [FFI](https://ghc.gitlab.haskell.org/ghc/doc/users_guide/exts/ffi.html) — `-threaded` requirement; safe foreign calls block all Haskell threads in the non-threaded RTS
- [GHC issue #1619 — "The RTS chokes on SIGPIPE"](https://gitlab.haskell.org/ghc/ghc/-/issues/1619) and [SIGPIPE in the GHC runtime (glasgow-haskell-users)](https://mail.haskell.org/pipermail/glasgow-haskell-users/2010-August/019082.html) — RTS installs a SIGPIPE handler; writes surface as `ResourceVanished`. *Confidence: MEDIUM — corroborated by `rts/posix/Signals.c` and the mailing-list thread; not restated in the current user's guide.*
- [aeson issue #198 "Possibly DoS"](https://github.com/haskell/aeson/issues/198) and [#673](https://github.com/haskell/aeson/issues/673) — huge-exponent memory exhaustion; [aeson 1.5.6.0 changelog](https://hackage.haskell.org/package/aeson-1.5.6.0/changelog) — the fix
- [HSEC-2023-0007](https://haskell.github.io/security-advisories/advisory/HSEC-2023-0007.html) — `Numeric.readFloat` linear-in-denoted-value blowup in `base`
- [Data.Scientific](https://hackage.haskell.org/package/scientific) — safe-by-construction arbitrary-precision numbers
- [Stackage LTS 22.43](https://www.stackage.org/lts-22.43) — GHC 9.6.6, aeson 2.1.2.1; [stackage.org](https://www.stackage.org/) — LTS 24.56 (GHC 9.10.3), LTS 23.28 (GHC 9.8.4), LTS 22.44 (GHC 9.6.7), nightly GHC 9.12.4 as of 2026-08-24
- [Hackage: jsonrpc](https://hackage.haskell.org/package/jsonrpc) — 0.2.0.0, 2026-02-16, types + typeclasses only; [Hackage: json-rpc](https://hackage.haskell.org/package/json-rpc) — 1.1.3, 2026-08-18, conduit/monad-logger/unliftio dependency set
- [Haskell with UTF-8 (Serokell)](https://serokell.io/blog/haskell-with-utf8) and [haskell-cafe: "How does GHC avoid hPutChar: invalid argument"](https://mail.haskell.org/pipermail/haskell-cafe/2017-April/126765.html) — locale-derived handle encoding
- [haskell/process #76](https://github.com/haskell/process/issues/76) and [Haskell Discourse: piping process stdout](https://discourse.haskell.org/t/strange-behavior-while-piping-process-stdout/4743) — pipe-buffer deadlock

**Gaps / lower-confidence items**

- The claim "deepseek-harness has no GHC in CI" rests on an exhaustive grep of `.github/workflows/`; a self-hosted runner image could in principle carry a toolchain not visible in the workflow YAML. Confirm with a maintainer.
- GHC's exact current SIGPIPE disposition should be re-verified against the GHC version you actually pin, ideally with a two-line program, rather than trusted from a 2010 thread.
- Whether `OneOfValueSchemaSpec` is accepted in *model-facing tool parameters* specifically (as opposed to output values) was not verified; read `packages/core/tools/src/schema.ts` and `json-schema.ts` before designing `HasSchema`.
- Windows behavior of the whole stack (newline mode, process termination, GHC console handling) is untested here; the harness runs a Windows CI lane, so plan for it rather than discovering it.

---
*Pitfalls research for: Haskell stdio JSON-RPC plugin SDK + DeepSeek Harness TypeScript bridge*
*Researched: 2026-08-25*
