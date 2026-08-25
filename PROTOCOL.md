# DeepSeek Harness Plugin Protocol

## 1. Scope and Status

This document freezes the wire between a DeepSeek Harness host and an out-of-process plugin peer. It is normative: every method name, manifest field, error code, and framing rule a conforming implementation needs is here, and no implementation detail of either side is.

Pre-1.0 there is no compatibility promise, no shim, and no deprecation window. A breaking change bumps `protocolVersion`, which is the integer `1`.

This document supersedes `.planning/research/ARCHITECTURE.md`. That file is a frozen record of an earlier draft, is never edited to match this one, and is not authority for anything below.

Every JSON example here is copied from a file under `corpus/` and names the file it came from. A rule that has no corpus frame is not frozen.

## 2. Framing

Newline-delimited JSON over stdio. One compact JSON object per line, encoded as UTF-8 bytes, with no raw newline inside a frame. A frame is `encode msg <> "\n"`.

The harness writes a frame as the JSON text of the message followed by a newline (`deepseek-harness/packages/sdk/protocol/src/transport.ts:261`) and reads frames by scanning for the delimiter with `buffer.indexOf('\n')` (`transport.ts:182`).

The plugin's stdout carries frames and nothing else. Diagnostics, logs, and crash output go to stderr. A plugin redirects any stray stdout writer to stderr before serving, because one stray line corrupts framing for every frame after it.

## 3. Envelope Rules

`params` is **always a JSON object**. The harness's `objectParams()` collapses an array or scalar `params` to `{}` (`transport.ts:214,:222`), so a non-object `params` is silent data loss rather than a decode failure. This protocol therefore rejects it with `-32600` instead of inheriting the collapse.

**Batches are unsupported.** A JSON array at the top level of a frame matches neither id correlation nor method dispatch, and is rejected with `-32600`.

`id` is a string or a number, round-tripped verbatim into the reply. A non-scalar `id` can never be echoed, so the error reply for such a frame carries `"id":null`.

Unknown members are dropped when a frame is rebuilt (section 10). A member this document does not name has no meaning and never reaches a handler.

Example: `corpus/malformed-shape/host.jsonl` and `corpus/malformed-shape/plugin.jsonl`.

## 4. Handshake Manifest

The handshake is host-initiated: the host sends `initialize`, and the manifest is that request's `result`. The normative example is `corpus/handshake/plugin.jsonl`:

```json
{"jsonrpc":"2.0","id":"h-1","result":{"protocolVersion":1,"pluginInfo":{"name":"echo","version":"0.1.0"},"tools":[{"name":"echo","description":"Echo text back.","parameters":{"type":"object","properties":{"text":{"type":"string","description":"Text to echo."}},"required":["text"],"additionalProperties":false},"output":{"schema":{"type":"object","properties":{"echoed":{"type":"string"}},"required":["echoed"],"additionalProperties":false}},"presentation":{"mode":"generic"},"timeoutMs":10000,"concurrencySafe":true}],"guards":[{"id":"no-forbidden","match":{"tools":["echo"]},"failPolicy":"closed","timeoutMs":2000}],"sections":[{"name":"echo:guidance","order":150,"text":"The echo tool returns its input."}],"subagents":[{"name":"echo-delegate","description":"Delegates a prompt to a canned echo child.","capabilities":{"outputSchema":false,"depthLimit":false,"toolFilter":false,"persona":false},"inheritsParentContext":false}]}}
```

| Field | Type | Meaning |
|---|---|---|
| `protocolVersion` | integer | must equal the host's; see section 5 |
| `pluginInfo` | `{name, version}` | identifies the peer in host logs |
| `tools[]` | `{name, description, parameters, output:{schema}, presentation:{mode}, timeoutMs?, concurrencySafe?}` | `parameters` and `output.schema` use only the harness's supported keyword subset (`type`, `oneOf`, `properties`, `required`, `additionalProperties`, `items`, `enum`, `const`, annotations); `output.schema` is mandatory; `presentation.mode` is static and decided at declaration time |
| `guards[]` | `{id, match:{tools[]}, failPolicy:"open"\|"closed", timeoutMs?}` | see the guard rules below |
| `sections[]` | `{name, order, text}` | static text carried in the manifest, so a section costs zero round trips |
| `subagents[]` | `{name, description, capabilities:{outputSchema,depthLimit,toolFilter,persona}, inheritsParentContext}` | mirrors the harness's `SubagentProvider`; all four capability booleans are required |

**Optional tool fields.** `timeoutMs` and `concurrencySafe` are optional and map to the harness's own `ToolDefinition.timeoutMs` (`packages/core/tools/src/index.ts:255`) and `isConcurrencySafe` (`:269`). A plugin that omits them gets the host's defaults. `presentation.locations` is deferred: the harness supports it, the bridge does not register it in v1, and adding it later is a manifest-only change.

**Guard matching.** `match.tools` is an exact tool-name list. The single string `"*"` means every tool. There are no globs, no prefixes, and no regular expressions, so a name is either literally in the list or the list is `["*"]`. The **host** evaluates `match` and only sends `guard/decide` for a call the guard matches; a plugin that receives a `guard/decide` naming a tool the guard does not match answers `-32002`. This is why `Guard` carries a declarative `matchTools :: [ToolName]` rather than a `ToolName -> Bool` predicate: a predicate cannot cross the process boundary into the manifest.

**Guard fail policy.** `failPolicy` is declared per guard, by the plugin, and is authoritative: it is what the host applies when that guard throws, times out, or the peer is dead. The host's own config supplies only the timeout duration (`requestTimeoutMs`); it does not supply a fail policy. An operator who overrides a guard's policy in host config gets a logged override, never a silent one. A guard may narrow the host's timeout with its own optional `timeoutMs`.

**Tool names.** This protocol's rule, not a harness constraint, is that a tool name matches `/^[A-Za-z0-9_-]{1,64}$/`. A name outside that set fails activation loudly; the host never normalizes it.

## 5. Versioning

`protocolVersion` is an integer, compared for exact equality. There is no negotiation, no capability exchange, and no shim.

On mismatch the plugin replies `-32001` with both versions in the message, serves no contribution, and exits non-zero. The error frame comes first because an error frame is observable to the host and to the corpus, and a bare exit is not.

Example: `corpus/version-mismatch/host.jsonl` and `corpus/version-mismatch/plugin.jsonl`.

## 6. Methods

| Direction | Method | Kind | Params | Result |
|---|---|---|---|---|
| host to plugin | `initialize` | request | `{protocolVersion, hostInfo:{name,version}, cwd}` | the manifest |
| host to plugin | `tool/execute` | request | `{callId, tool, arguments}` | `{value, content}` |
| host to plugin | `guard/decide` | request | `{guard, callId, tool, arguments}` | `{kind:"allow"\|"deny"\|"ask", reason?}` |
| host to plugin | `subagent/run` | request | `{runId, subagent, prompt:ContentBlock[], cwd}` | `{stopReason, output:ContentBlock[], structured?, diagnostic?}` |
| host to plugin | `shutdown` | request | `{}` | `{}` |
| host to plugin | `$/cancel` | notification | `{id}` | (none) |
| plugin to host | `section.changed` | notification | `{name, text}` | (none) |

Requests use slashes, except bare `initialize` and `shutdown`. Those two match the harness's own `HarnessSdkRequestMap` by naming only: the harness's `initialize` and `shutdown` payloads belong to a different protocol and are not compatible with these. Notifications use dots, matching `session.event` and `subagent.started` in the same file. `$/cancel` keeps its LSP spelling.

**`tool/execute` result.** `{value, content}`. `value` is the tool's own payload; `content` is the plugin-side `render` output shipped with the result, so the harness can replay a session without the plugin process. Before replying, the plugin validates `value` against the `output.schema` it declared in the manifest. A validation failure is `-32603`, not `-32004`: a plugin whose own output contradicts its own declaration is an SDK-level bug, not a domain failure, and the error's `data` names the failing path (for example `{"path":"/echoed"}`). Example: `corpus/tool-call/plugin.jsonl`.

Host side, the bridge registers the tool on `ctx.tools` with the envelope schema `{type:"object", properties:{value:<declared output.schema>, content:{type:"array"}}, required:["value","content"], additionalProperties:false}` and a `render` that returns `content` verbatim. This is the same construction `packages/mcp/mcp-client/src/tools.ts` `createOutput()` builds for MCP's `{content, structuredContent}`.

**`subagent/run` result.** `{stopReason, output, structured?, diagnostic?}`, mirroring the harness's `SubagentResult` field for field. `stopReason` is one of `completed | aborted | error | max-tokens | refusal`. Example: `corpus/subagent-run/plugin.jsonl`.

## 7. Error Codes

| Code | Name | Meaning |
|---|---|---|
| -32700 | `PARSE_ERROR` | malformed JSON line |
| -32600 | `INVALID_REQUEST` | not a JSON-RPC 2.0 frame: a batch array, a non-object `params`, a non-scalar `id`, an integer outside the safe range (section 9), or a frame longer than `maxFrameBytes` |
| -32601 | `METHOD_NOT_FOUND` | unknown **method** |
| -32602 | `INVALID_PARAMS` | params fail the method's record |
| -32603 | `INTERNAL_ERROR` | unhandled exception inside the SDK, or a tool result that fails its own declared `output.schema` — operator-actionable |
| -32800 | `REQUEST_CANCELLED` | the request was cancelled (LSP's code) |
| -32001 | `PROTOCOL_VERSION_MISMATCH` | handshake versions differ; activation fails loud |
| -32002 | `UNKNOWN_CONTRIBUTION` | tool, guard, section, or subagent id absent from the manifest, or a `guard/decide` the guard's `match` does not cover |
| -32004 | `TOOL_FAILED` | the author's handler failed — a domain failure the model reads |
| -32005 | `INVALID_ARGUMENTS` | model arguments failed the declared schema |

The `-32004` / `-32603` split is load-bearing: both surface to the model as an error, but only `-32603` is an operator-actionable log line.

`-32601` is for an unknown method, never an unknown contribution. `tool/execute`, `guard/decide`, and `subagent/run` naming a name absent from the manifest answer `-32002`: the method was found and dispatched, the contribution was not. Example: `corpus/tool-unknown/host.jsonl` and `corpus/tool-unknown/plugin.jsonl`.

## 8. Cancellation

`$/cancel` is a notification carrying `{id}`.

Once a `$/cancel` is observed for an in-flight id, the SDK discards the handler's eventual outcome and replies `-32800` for that id, whether the handler later succeeds, throws, or never returns. A well-behaved handler observes `cancelled` and returns early, which frees the thread sooner but changes nothing the host sees. The reply is unconditional so that a host waiter — in particular the `tools/pre-execute` waterfall — can never wedge on a cancelled request.

A `$/cancel` for an unknown or already-completed id is silently ignored: no error frame, no crash, and no log line above `debug`.

Examples: `corpus/cancel-inflight/`, `corpus/cancel-late/`, `corpus/cancel-unknown/`.

## 9. Lossless JSON and Number Policy

- Any integer anywhere in a frame — at any depth, in `params`, `result`, `error`, or `id` — whose value falls outside ±(2^53 - 1) causes the whole frame to be rejected with `-32600`. It is never rounded and never truncated.
- A number whose JSON text is finite but has no finite IEEE-754 double value (`1e400`) is rejected the same way.
- The check happens at the wire layer, on the raw frame text, before any handler runs. Phase 2 owns it (WIRE-01, WIRE-03).
- SCHEMA-05 enforces the same bound a second time at schema-validation level, so a value that reaches a handler cannot carry an unsafe integer even if the transport is bypassed in a test.

The precedent is the harness's own `packages/code-runtime/code-runtime-python` lossless-JSON policy, which rebuilds hostile frames rather than trusting a decoder's numeric defaults.

## 10. Hostile Input

Every inbound frame is shape-validated and rebuilt, never cast: forged extra fields never ride along, and a non-scalar id can never be echoed into a reply.

A junk line becomes a `-32700` error frame rather than an exception, and the reader stays in sync for the next line (`corpus/malformed-junk-line/`).

The reader is bounded by a configurable `maxFrameBytes`. A frame exceeding it is rejected with `-32600` and `id:null` instead of being buffered (`corpus/malformed-oversize/`). The default value of `maxFrameBytes` is Phase 2's to set and is a validated config field, not a hardcoded constant.

A plugin-to-host error frame carrying `"id":null` corresponds to no outstanding request, so the host cannot resolve a waiter with it. The host logs it at `warn` and continues. Dropping it silently is forbidden: an `id:null` frame is usually the only evidence that the plugin rejected something the host thought it sent.

## 11. Id Namespaces

Host-issued and plugin-issued request ids live in separate namespaces and never collide. The concrete scheme is implementation-private; the corpus normalization rule in section 12 makes it invisible to conformance comparisons.

## 12. Conformance Corpus

`corpus/<scenario>/host.jsonl` carries the frames the host sends and `corpus/<scenario>/plugin.jsonl` the frames the plugin must emit, in order.

A **zero-length `plugin.jsonl` means the plugin emits no frames** (see `corpus/cancel-unknown/`); it is not an unwritten stub.

A scenario carrying `EXPECTED.md` is a known-red scenario whose first line names the phase that must turn it green. When the last `EXPECTED.md` is deleted, the corpus is fully implemented.

`SCENARIO.json` is an optional per-scenario file. When present it is a JSON object with any of these keys; an absent key takes the stated default:

| Key | Default | Meaning |
|---|---|---|
| `maxFrameBytes` | the implementation's default | the bound the reader is configured with for this scenario |
| `deadlineMs` | 5000 | the whole scenario must finish within this; exceeding it fails the scenario |
| `quiescenceMs` | 250 | after the expected frames have arrived, how long to wait while asserting nothing else does |

`corpus/malformed-oversize/SCENARIO.json` is `{"maxFrameBytes": 256}`, which is how a 300-byte line exercises the bound without committing a large file.

**Fake-host pacing.** The replaying host is deterministic, so two implementations cannot disagree about interleaving:

- It sends `host.jsonl` line by line and awaits each request's reply before sending the next line, with one exception: a `$/cancel` notification immediately following a request is sent without waiting, which is the only way an in-flight cancellation is reachable (`corpus/cancel-inflight/`). A `$/cancel` that does not immediately follow a request is sent in the normal paced order, which is what makes `corpus/cancel-late/` deterministically late.
- After the last `host.jsonl` line, the host keeps reading until `plugin.jsonl`'s frame count has been matched, then waits `quiescenceMs` and fails the scenario if any further frame arrives. A scenario expecting zero frames waits only that window. This is what makes `corpus/section-changed/` (the host sends nothing after `initialize`; the plugin speaks) and `corpus/cancel-unknown/` (the plugin never speaks) finite, checkable claims.

**Reference-tool behavior.** The corpus is replayable only because the `echo` tool's response to each argument it is sent is frozen here, not left to the example's author:

| `arguments.text` | Behavior |
|---|---|
| `"quick"` | returns `{"echoed":"quick"}` immediately |
| `"boom"` | fails with `-32004` |
| `"slow"` | blocks until cancelled; if it is still blocked at `deadlineMs`, the scenario fails |
| anything else | returns `{"echoed": <text>}` immediately |

Phase 7's `dsh-plugin-echo` (API-10) implements exactly this table.

**Id normalization.** Two passes, so direction is decided by a pass that has already seen both files:

```
# Pass 1 — origin table, built from BOTH files. Pass order is irrelevant:
# a request id appears as a request in exactly one of the two files.
origin = {}                                   # request id -> "h" | "p"
for frame in hostFrames:
    if isObject(frame) and has(frame,"method") and isScalarId(frame.id):
        origin[frame.id] = "h"
for frame in pluginFrames:
    if isObject(frame) and has(frame,"method") and isScalarId(frame.id):
        origin[frame.id] = "p"

# Pass 2 — relabel each file on its own, walking that file in file order.
relabel(frames):
    counter = { "h": 0, "p": 0 }
    label   = {}                              # id -> normalized label
    for frame in frames:
        if not isObject(frame):               # junk line, batch array
            continue                          # passes through unchanged
        if isScalarId(frame.id) and frame.id in origin:
            side = origin[frame.id]           # a response inherits the
                                              # requester's side
            if frame.id not in label:
                counter[side] += 1
                label[frame.id] = side + counter[side]
            frame.id = label[frame.id]
        if frame.method == "$/cancel" and isObject(frame.params)
                                        and frame.params.id in label:
            frame.params.id = label[frame.params.id]
            # an origin miss leaves params.id unchanged: corpus/cancel-unknown/
    return frames

normalize(hostFrames, pluginFrames) =
    (relabel(hostFrames), relabel(pluginFrames))
```

Three consequences:

- **Direction is decided by the side that originated the request, not by the file the frame appears in.** A plugin's response to host request `h-1` normalizes to `h1`, never `p1`. Pass 1 is what makes this possible without interleaving two files that carry no timestamps.
- **Non-object and unparseable lines pass through unchanged**, so `corpus/malformed-junk-line/host.jsonl` line 1 and `corpus/malformed-shape/host.jsonl` line 2 survive normalization byte for byte.
- **Comparison is expected `plugin.jsonl` against actual plugin output**, both relabelled by the same function, decode-then-compare rather than byte-compare: JSON object key order is not significant and aeson's key order is not declaration order.

## 13. Shutdown

A `shutdown` request answers every in-flight request with `-32800` first, then returns `{}` for the `shutdown` request itself, then the peer exits cleanly.

There is no drain window: a handler is not given time to finish, which is why no `SHUTTING_DOWN` code exists.

stdin EOF is equivalent to `shutdown`. SIGPIPE is a clean exit, not a crash. No orphaned threads and no in-flight handler survive either path.

Example: `corpus/shutdown/host.jsonl` and `corpus/shutdown/plugin.jsonl`.

## Deferred

This document deliberately does not freeze:

- Windows and macOS CI lanes — Phase 2, landing with the transport, where newline mode, process termination, and GHC console handling first matter.
- The default `maxFrameBytes` and `requestTimeoutMs` values — Phase 2 and Phase 8.
- `presentation.locations` on a manifest tool — the harness supports it; the bridge does not register it in v1.
- Streamable-HTTP and WebSocket transports, generic Cordis service reflection, progress notifications, and `agent/inject` — all v2.
