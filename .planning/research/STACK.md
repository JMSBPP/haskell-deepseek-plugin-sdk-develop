# Stack Research

**Domain:** Haskell SDK for out-of-process AI-agent plugins over newline-delimited JSON-RPC 2.0 on stdio
**Researched:** 2026-08-25
**Confidence:** HIGH (versions verified live against Stackage/Hackage on 2026-08-25; library semantics verified by reading published source, not training data)

## Executive Recommendation

Four calls, in order of how much they change the roadmap:

1. **Repin the resolver.** `lts-22.43` is not a sound pin. Repin to **`lts-24.56` (GHC 9.10.3)**. Evidence below is concrete and model-visible, not stylistic.
2. **Own the JSON-RPC envelope module** (~150 LOC over `aeson`). No maintained Hackage package implements the framing this harness actually speaks. `jsonrpc-0.2.0.0` is the named fallback if the team prefers a dependency.
3. **Use `autodocodec` + `autodocodec-schema`** for the `HasSchema` requirement — one codec definition yields `ToJSON`, `FromJSON`, a JSON Schema document, *and* `validateAccordingTo` (the hostile-input arg validator PROJECT.md requires). Do **not** hand-roll a Generic class, and do **not** use `openapi3`.
4. **Keep the runtime dependency closure tiny.** `aeson`, `async`, `safe-exceptions`, `optparse-applicative`, `autodocodec*`, plus GHC boot libraries. No `conduit`, no `unliftio`, no logging framework. This is an SDK third parties link into their own binaries.

---

## Empirical Verification (built locally, 2026-08-25)

The two decisive claims below were not inferred — a throwaway probe package was built on both candidate resolvers with `jsonrpc`, `autodocodec`, `autodocodec-schema`, `async`, `stm`, `unliftio`, `conduit`, and `optparse-applicative` as dependencies, then evaluated in `stack ghci`.

**Both resolvers built clean (`EXIT=0`, 66 and 67 actions).** `jsonrpc-0.2.0.0` compiles as a plain `extra-deps` entry on `lts-22.43` (GHC 9.6.6 / aeson 2.1.2.1 / text 2.0.2) **and** on `lts-24.56` (GHC 9.10.3 / aeson 2.2.5.0 / text 2.1.3) with no `allow-newer`. The envelope decision is therefore genuinely independent of the pin decision.

**Toolchain cost, observed:** the `lts-22.43` build triggered `ghcup install ghc 9.6.6` and spent several minutes installing a compiler before compiling anything. The `lts-24.56` build reused the already-installed GHC 9.10.3 and went straight to packages.

**The `Int` schema regression, A/B:**

```
lts-22.43 (autodocodec-schema-0.1.0.4):
  {"maximum":9223372036854775807,"minimum":-9223372036854775808,"type":"number"}

lts-24.56 (autodocodec-schema-0.2.0.1):
  {"maximum":9223372036854775807,"minimum":-9223372036854775808,"type":"integer"}
```

Same expression (`encode (jsonSchemaViaCodec @Int)`), same everything else. On the current pin, every integral tool argument is advertised to the model as `number`. Note also the `Int64` bounds that both versions emit — noise in a model-visible schema that the SDK's manifest builder should consider stripping alongside the `$comment` → `description` rewrite.

**Other observations worth carrying into the design:**

- `jsonrpc`'s `JSONRPCRequest` serialises as `{"id":"req_1","jsonrpc":"2.0","method":"tool/execute","params":null}` — the anyclass-`Generic` `ToJSON` **emits `"params":null`** rather than omitting it (only the hand-written `JSONRPCNotification` instance omits). Harmless against this harness (`objectParams()` collapses `null` to `{}`), but it is wire noise an owned envelope would not produce.
- **Encoded key order is not record declaration order.** The record is declared `jsonrpc, id, method, params`; `aeson` emitted `id, jsonrpc, method, params`. Byte-exact frame goldens must be recorded from actual output, never hand-written from the record definition — and any assertion that cares about content rather than bytes should decode first (`hspec-expectations-json`).
- `decode @JSONRPCMessage "{\"jsonrpc\":\"2.0\",\"method\":\"$/cancel\"}"` → `Just (NotificationMessage ...)` with `params = Null`. Params-less notification decoding works, and the `<|>`-based `FromJSON JSONRPCMessage` picks the right variant.
- `validateAccordingTo Null (jsonSchemaViaCodec @Int)` → `False`. The pre-decode arg validator behaves.

---

## Recommended Stack

### Core Technologies

| Technology | Version | Purpose | Why Recommended | Confidence |
|------------|---------|---------|-----------------|------------|
| GHC | **9.10.3** (via `lts-24.56`) | compiler | Current LTS series compiler; already installed on this machine (`~/.ghcup/ghc` holds 9.10.3 and 9.8.4, **not** 9.6.x); unlocks `default-language: GHC2024` | HIGH |
| Stack | 3.11.1 (installed) | build + snapshot pin | Already present; `snapshot:` pin gives the reproducible build the constraint asks for | HIGH |
| Stackage snapshot | **`lts-24.56`** | dependency set | Latest LTS as of 2026-08-25 (`stackage.org/lts` → `lts-24.56`, ghc-9.10.3); still receiving weekly patches | HIGH |
| `aeson` | 2.2.5.0 | all JSON | 2.2 added `omitField`/`omittedField` and the `.:?=` / `.:!=` / `.?=` operators, making optional JSON-RPC members (`params`, `data`, optional tool-arg fields) first-class instead of hand-filtered; `Data.Aeson.Decoding` became the default decoder | HIGH |
| `bytestring` | 0.12.2.0 (boot) | wire bytes, frame splitting | Frames are bytes, not `String`. Decode UTF-8 inside `aeson`, never through a `Char` handle | HIGH |
| `text` | 2.1.3 (boot) | method names, messages | Standard | HIGH |
| `containers` | 0.7 (boot) | method dispatch table, in-flight request map | `Map Text Handler`; no need for `unordered-containers` at this scale | HIGH |
| `stm` | 2.5.3.1 (boot) | cancellation flags, outbound frame queue | `Exec.cancelled :: STM Bool` in PROJECT.md is literally a `readTVar`; `TBQueue` gives the single-writer discipline stdout needs | HIGH |
| `async` | 2.2.6 | one thread per in-flight request | Simon Marlow's, released 2026-01-07, the de-facto standard; `withAsync`/`race`/`cancel` are exactly the primitives the `$/cancel` seam needs | HIGH |
| `safe-exceptions` | 0.1.7.4 | exception discipline | `Control.Exception.Safe` distinguishes synchronous failures (become `-32603` error frames) from asynchronous ones (`AsyncCancelled` from `Async.cancel` must propagate, not be turned into an error frame). Getting this wrong with bare `try @SomeException` is the classic cancellation bug | HIGH |
| `autodocodec` | 0.5.0.0 | the `HasSchema` seam | Codec-first: one `HasCodec` instance derives encoder, decoder, and schema from a single definition. Explicit per-field docs — a Generic derivation physically cannot produce the field descriptions a tool-calling model reads | HIGH |
| `autodocodec-schema` | 0.2.0.1 | JSON Schema + validation | `jsonSchemaViaCodec :: HasCodec a => JSONSchema` for the manifest, and **`validateAccordingTo :: Value -> JSONSchema -> Bool`** for the "validate model-controlled args against the derived schema before decode" requirement — from the same source of truth | HIGH |
| `optparse-applicative` | 0.18.1.0 | `--dump-manifest` and future flags | Uncontested standard; same version in lts-22/23/24 so this choice is pin-independent | HIGH |

### Supporting Libraries

| Library | Version (lts-24.56) | Purpose | When to Use |
|---------|---------------------|---------|-------------|
| `hspec` | 2.11.17 | single test runner | All tests. Add `hspec-discover` (2.11.17) as a `build-tool-depends` |
| `hspec-golden` | 0.2.2.0 | wire-frame goldens | `Golden` is a record of `writeToFile`/`readFromFile`/`output`, so a byte-exact `Golden ByteString` instance is a direct construction. Ships an `hgold` CLI to re-record |
| `QuickCheck` | 2.15.0.1 | codec round-trip properties | `decode . encode == Just` for every envelope and `ContentBlock` case, including the `Unknown Value` merge-extensibility case |
| `quickcheck-instances` | 0.3.33 | `Arbitrary` for `Text`/`ByteString`/`Scientific`/`Map` | Needed the moment properties touch anything beyond `Int` |
| `hspec-expectations-json` | 1.0.2.1 | order-insensitive JSON assertions | Assert on decoded frames where key order is irrelevant; keep `hspec-golden` for byte-exact framing (trailing newline, no embedded newline) |
| `aeson-pretty` | 0.8.11 | stable `--dump-manifest` rendering | Only if the manifest golden is checked as pretty JSON. Note it sorts keys — decide once and pin the choice |
| `typed-process` | 0.2.12.0 | integration tests | Spawn the built `examples/echo` binary and drive real frames over its stdio; the only way to test EOF/SIGPIPE shutdown honestly |
| `temporary` | 1.3 | test scratch dirs | Fixtures for the above |

### Development Tools

| Tool | Purpose | Notes |
|------|---------|-------|
| HLS (haskell-language-server) | IDE | Install via `ghcup`, matched to the pinned GHC. Another repin argument: HLS builds for 9.10 are current, and you avoid maintaining a third toolchain |
| `fourmolu` | formatting | Pick one formatter and commit `fourmolu.yaml`; the harness gates formatting, this repo should too |
| `hlint` | lint | Wire into the same gate as `pnpm run lint` on the bridge side |
| `stack test --coverage` (HPC) | coverage | The bridge PR lands under the harness's 100%-per-file gate; keep the Haskell side's coverage story explicit from day one rather than retrofitting |
| GHC flags | correctness | Executable **must** use `-threaded -rtsopts "-with-rtsopts=-N"`. Without `-threaded`, one handler making a blocking foreign call stalls the entire RTS, freezing the JSON-RPC read loop and making `$/cancel` unresponsive. Keep the template's `-Wall -Wcompat …`; add `-Werror` in CI only |

---

## Installation

`stack.yaml`:

```yaml
snapshot: lts-24.56
packages:
  - .
# Only if adopting the jsonrpc envelope package (see decision below):
# extra-deps:
#   - jsonrpc-0.2.0.0
```

`haskell-deepseek-plugin-sdk.cabal` (replace the `simple` template's `executable`-only layout with library + executable + test-suite):

```cabal
cabal-version: 2.2
name:          haskell-deepseek-plugin-sdk
version:       0.1.0.0
license:       BSD-3-Clause
build-type:    Simple

library
  hs-source-dirs:   src
  default-language: GHC2024
  exposed-modules:
      DeepSeek.Plugin
      DeepSeek.Plugin.Wire        -- JSON-RPC envelope + NDJSON framing
      DeepSeek.Plugin.Schema      -- HasSchema over autodocodec
      DeepSeek.Plugin.Tool
      DeepSeek.Plugin.Guard
      DeepSeek.Plugin.Section
      DeepSeek.Plugin.Subagent
  build-depends:
      base                 >=4.18 && <4.22
    , aeson                >=2.2  && <2.3
    , autodocodec          >=0.4  && <0.7
    , autodocodec-schema   >=0.2  && <0.3
    , async                >=2.2  && <2.3
    , bytestring           >=0.11 && <0.13
    , containers           >=0.6  && <0.9
    , safe-exceptions      >=0.1.7 && <0.2
    , stm                  >=2.5  && <2.6
    , text                 >=2.0  && <2.2
  ghc-options: -Wall -Wcompat -Widentities -Wincomplete-record-updates
               -Wincomplete-uni-patterns -Wmissing-export-lists
               -Wmissing-home-modules -Wpartial-fields -Wredundant-constraints

executable dsh-plugin-echo
  hs-source-dirs:   examples/echo
  main-is:          Main.hs
  default-language: GHC2024
  build-depends:
      base, haskell-deepseek-plugin-sdk, optparse-applicative >=0.18 && <0.20
  ghc-options: -threaded -rtsopts "-with-rtsopts=-N" -Wall

test-suite spec
  type:             exitcode-stdio-1.0
  hs-source-dirs:   test
  main-is:          Spec.hs
  default-language: GHC2024
  build-depends:
      base, haskell-deepseek-plugin-sdk, aeson, bytestring, text
    , hspec >=2.11 && <2.12
    , hspec-golden >=0.2 && <0.3
    , hspec-expectations-json
    , QuickCheck, quickcheck-instances
    , typed-process, temporary
  build-tool-depends: hspec-discover:hspec-discover
```

**Note the deliberate split:** `base >=4.18` (GHC 9.6) in the *library* bounds even though the *resolver* pins GHC 9.10. A published SDK's supported GHC range is a compatibility promise; the Stack snapshot is only the development pin. Test the range with a small cabal CI matrix (9.6 / 9.8 / 9.10), not by moving the pin.

---

## Decision 1: The Resolver Pin — `lts-22.43` Is Not Sound

**Verdict: repin to `lts-24.56` (GHC 9.10.3). Fallback: `lts-23.28` (GHC 9.8.4) if third-party GHC availability turns out to matter.**

Verified snapshot facts (stackage.org, 2026-08-25):

| | `lts-22.43` | `lts-23.28` | **`lts-24.56`** |
|---|---|---|---|
| GHC | 9.6.6 | 9.8.4 | **9.10.3** |
| Series status | closed (final patch is **`lts-22.44`**, not `.43`) | closed | **open, current** |
| `base` | 4.18.2.1 | 4.19.2.0 | 4.20.2.0 |
| `aeson` | **2.1.2.1** | 2.2.3.0 | **2.2.5.0** |
| `text` / `bytestring` | 2.0.2 / 0.11.5.3 | 2.1.1 / — | 2.1.3 / 0.12.2.0 |
| `autodocodec` | **0.2.3.0** | 0.4.2.2 | **0.5.0.0** |
| `autodocodec-schema` | **0.1.0.4** | 0.2.0.1 | **0.2.0.1** |
| `json-rpc` | 1.0.4 (2022) | 1.1.2 | 1.1.2 |
| `QuickCheck` / `tasty` | 2.14.3 / 1.4.3 | 2.14.3 / 1.5.3 | 2.15.0.1 / 1.5.4 |
| `default-language: GHC2024` | unavailable | unavailable | **available** |

Five concrete costs of staying on `lts-22.43`:

1. **The pin isn't even the series terminal.** `https://www.stackage.org/lts` redirects `lts-22` → **`lts-22.44`**. Pinning `.43` buys strictly fewer bugfixes for zero benefit. If GHC 9.6 is non-negotiable for another reason, the pin must at minimum become `lts-22.44`.
2. **Model-visible schema regression.** `autodocodec-schema-0.1.0.4` (lts-22) has no `IntegerSchema` constructor — integral tool arguments render as `"type":"number"`. `0.2.0.1` (lts-23/24) added `IntegerSchema` and emits `"type":"integer"` (verified in `src/Autodocodec/Schema.hs`, constructor list and the `"type" .= ("integer"::Text)` branch). Tool-arg schemas are read by the model; this is a correctness difference, not cosmetics.
3. **Missing codec combinators.** `lts-22`'s `autodocodec-0.2.3.0` predates `boundedEnumCodec` (0.4.2.2), `optionalFieldOrNullWithDefault` (0.4.2.1), and the 0.3.0.0 representational-role change that makes `deriving newtype (HasCodec)` work — which the branded-id requirement will want immediately.
4. **`aeson` 2.1 lacks optional-field support.** `omitField`/`omittedField` and `.?=` arrived in `aeson-2.2.0.0` (verified in aeson's changelog). On 2.1 every omitted JSON-RPC member (`params` on a bare notification, `data` on an error, every optional tool-arg field) needs hand-written filtering — exactly the kind of implicit defaulting the harness conventions forbid.
5. **A third toolchain for nothing.** This machine has GHC 9.10.3 and 9.8.4 installed and no 9.6.x. `stack build` against `lts-22.43` triggered `ghcup install ghc 9.6.6` and spent multiple minutes installing a compiler before compiling a single line (observed live during this research).

`lts-23.28` (GHC 9.8.4) is the honest conservative option: it fixes items 2–4 and its compiler is already installed. It costs `GHC2024` and puts you on another closed series. Take it only if a survey of target plugin authors shows GHC 9.10 adoption is a real barrier.

---

## Decision 2: JSON-RPC — Own the Envelope

**Verdict: write `DeepSeek.Plugin.Wire` (~150 LOC over `aeson`). Do not depend on `json-rpc`, `jsonrpc-tinyclient`, or `lsp`. `jsonrpc-0.2.0.0` is a defensible alternative; the tradeoff is stated below so the call can be reversed knowingly.**

### What the harness actually speaks

Read from `packages/sdk/protocol/src/transport.ts` (the peer this SDK talks to). These are the binding constraints, and **no general JSON-RPC library encodes any of them**:

| Harness behavior (verified in source) | Consequence for the Haskell side |
|---|---|
| `output.write(JSON.stringify(msg) + '\n')` | Exactly one compact frame per line, newline-terminated. `aeson`'s `encode` never emits a raw newline, so `encode msg <> "\n"` is exact |
| `objectParams()` collapses arrays and scalars to `{}` | `params` **must always be a JSON object**. Positional params silently become `{}` — a data-loss failure mode, not an error |
| Frames dispatch on `id`/`method` presence; a JSON **array** matches neither and is dropped silently | **Batches are unsupported.** A library that can emit a batch array can silently lose an entire response set |
| `JSON.parse` failure → `return` (line ignored, no error frame) | Malformed input is dropped, not answered. A Haskell `-32700` reply to a dropped line is harmless (unmatched ids are discarded) but is not part of the contract |
| Ids are strings (`req_<hex>`); inbound accepts `string \| number` | Id type must be `string \| number` and must round-trip verbatim, never renumber |
| Errors carry `{code, message, data?}`; the transport itself emits only `-32601` and `-32603` | Handler failures map to `-32603`; unknown methods to `-32601` |
| `buffer.indexOf('\n')` with an unbounded `this.buffer` | The reader is unbounded on both sides — the Haskell reader needs a **configurable `maxFrameBytes`** (hostile-input stance; and per harness convention, a `Config` field, not a `DEFAULT_` constant) |

### Candidate evaluation

**`json-rpc` 1.1.3 — maintained, but wrong shape. REJECT.**
Actively maintained (jprupp, pushed 2026-08-18, 35 stars, not archived). Genuinely disqualifying details, all read from the published source:

- `encodeConduit = CL.mapM $ \m -> return . L8.toStrict $ encode m` (`Interface.hs:88`) — **emits no newline**. The newline-appending conduit `cr = CL.map (\`B8.snoc\` '\n')` (`Interface.hs:339`) is private and applied only inside the bundled TCP transports. You are hand-writing the framing anyway.
- Library `build-depends` includes **`QuickCheck`** (it exports `Network.JSONRPC.Arbitrary`), plus `monad-logger`, `conduit`, `conduit-extra`, `stm-conduit`, `time`, `vector`, `unordered-containers`, `hashable`. **`stm-conduit`'s last Hackage upload is 2018-09-27** (bounds-only revisions since). A plugin SDK should not put a test-generation library and an 8-year-dormant package into every plugin author's runtime closure.
- Imposes its monad: `type JSONRPCT = ReaderT Session` with `MonadLoggerIO m, MonadUnliftIO m` constraints on every operation. PROJECT.md's surface is `runPlugin :: Plugin -> IO ()` and `execute :: a -> Exec -> IO v`.
- `initSession` hardcodes three `newTBMChan 128` bounded channels — an unconfigurable backpressure tunable.
- Full batch machinery (`sendBatchResponse`, `receiveBatchRequest`) that the harness silently drops.
- **On `lts-22.43` you get `json-rpc-1.0.4` (2022)**, because 1.1.0 requires `aeson >= 2.2`. The maintained release is unreachable without breaking the snapshot.

**`jsonrpc` 0.2.0.0 (DPella) — right shape, real adoption caveats. ALTERNATIVE.**
498 LOC, dependencies are `aeson`, `base`, `text` only. Verified semantics match the harness precisely: `RequestId = RequestId Value` (string/number/null), `params` defaults to `Null` when absent, `ToJSON JSONRPCNotification` omits `params` when `Null`, and `JSONRPCMessage` is a closed four-way sum (request/response/error/notification) with **no batch case**. Bounds `base >=4.18 && <4.22`, `aeson >=2.1 && <2.3`, `text >=2.0 && <2.2` — satisfied by lts-22.43, lts-23.28, *and* lts-24.56, so this choice is independent of the pin decision. It is the types layer under the Haskell MCP SDK (`mcp-types`, `mcp`), which is the closest prior art in existence.

Against it:
- **MPL-2.0.** This SDK is BSD-3. MPL 2.0 §3.2 obliges anyone distributing an executable form to make the covered source available under MPL. For a library that third-party plugin authors statically link into shipped binaries, that propagates a (small, satisfiable) compliance obligation downstream that BSD-3 does not. *(MEDIUM confidence — this is a plain reading of the license text, not legal advice.)*
- **Not in any Stackage snapshot** → permanent `extra-deps` entry you must bump by hand.
- **Single vendor, single release, negligible adoption:** version 0.2.0.0 uploaded 2026-02-16, 2 GitHub stars, 30 total Hackage downloads, and both reverse dependencies (`mcp-types`, `mcp`) are by the same author. `tested-with: ghc ==9.12.2` only.

**`jsonrpc-tinyclient` 1.1.0.0 — REJECT outright.** Client-only, HTTP and WebSocket transports only (`http-client`, `http-client-tls`, `websockets` in `build-depends`), no server side, no stdio, no notification handling. It exists to serve `hs-web3`'s Ethereum RPC. Nothing about it applies.

**`lsp` 2.8.0.0 / `lsp-types` — REJECT for transport, MINE for conventions.** `haskell-language-server` uses it and it is well maintained (uploaded 2026-02-17 by `hls_team`). But it implements the **LSP base protocol: `Content-Length` headers, not newline framing** — the wrong wire format — and drags `row-types`, `lens`, `lens-aeson`, `prettyprinter`, `text-rope`, `sorted-list`, `uuid`, `random`, `data-default`. Do steal two things from it: (1) `co-log-core`'s `LogAction` as the *shape* of the SDK's logger field (a function, not a framework), and (2) its cancellation error codes.

### The prescription

Write `DeepSeek.Plugin.Wire` with `jsonrpc-0.2.0.0`'s type layout as the reference (it is public, small, and demonstrably correct):

```haskell
newtype RequestId = RequestId Value          -- string | number, round-tripped verbatim
data Frame = Req  RequestId Text Object      -- params is always an Object, never Value
           | Res  RequestId Value
           | Err  RequestId ErrorInfo
           | Note Text (Maybe Object)        -- omitted entirely when Nothing
```

Deliberate divergences from every off-the-shelf library, each of which is the reason to own the module:

- `params :: Object`, not `Value` — makes the harness's object-only rule unrepresentable to violate.
- **No batch constructor** — a frame the peer silently drops must be impossible to construct.
- Reader enforces a configurable `maxFrameBytes`; an oversized line is a loud protocol error, not an OOM.
- Single writer thread draining a `TBQueue Frame`, `hSetBinaryMode stdout True`, explicit `hFlush` per frame. Never `hPutStrLn`/`String` on `stdout`.
- `hSetEncoding stderr utf8` at startup so non-ASCII log text cannot throw `commitBuffer: invalid argument` under a `C` locale.

**Reverse this decision and adopt `jsonrpc` if** it reaches 1.0, enters a Stackage LTS, or gains reverse dependencies outside DPella — *and* the MPL-2.0 propagation is judged acceptable for downstream plugin authors. The framing, dispatch, correlation, and invariant tests stay owned either way; the dependency only replaces the record definitions.

*(This widens PROJECT.md's stated escape hatch from "only if none is maintained" to "if none is suitable." `json-rpc` is maintained and still unsuitable — the evidence is the newline gap, the `stm-conduit`/`QuickCheck` runtime closure, and the batch frames the harness drops.)*

---

## Decision 3: Schema Derivation — `autodocodec`, Not Generics

**Verdict: `autodocodec-0.5.0.0` + `autodocodec-schema-0.2.0.1`. Reject `openapi3`, `aeson-schemas`, and a hand-rolled Generic `HasSchema`.**

A single `HasCodec` instance gives four things from one source of truth:

```haskell
instance HasCodec GrepArgs where
  codec = object "GrepArgs" $ GrepArgs
    <$> requiredField "pattern" "regular expression to search for" .= grepPattern
    <*> optionalFieldWithDefault "path" "." "directory to search" .= grepPath
```

1. `ToJSON`/`FromJSON` via `deriving via (Autodocodec GrepArgs)`.
2. `jsonSchemaViaCodec @GrepArgs :: JSONSchema` for the handshake manifest.
3. `toJSON` on that schema emits real JSON Schema keywords — `type`/`properties`/`required`/`items`/`additionalProperties`/`anyOf`/`oneOf`/`const`/`$ref`/`$defs` (verified in `Autodocodec/Schema.hs`).
4. **`validateAccordingTo :: Value -> JSONSchema -> Bool`** — the pre-decode validator for model-controlled args that PROJECT.md's security constraint requires, guaranteed consistent with the schema the model was shown because both come from the same codec.

**Why codec-first beats a Generic `HasSchema`.** A Generic derivation can produce field *names* and *types* but not field *descriptions* — and the harness convention is explicit that model-facing contracts are written from the model's perspective. `requiredField "pattern" "regular expression to search for"` puts the model-facing text at the definition site where it is reviewable. It also lines up with "Explicit > implicit at package boundaries." The cost is boilerplate per args type; the mitigation is `deriving via Autodocodec`, so authors write one definition, not four.

**Two known gaps to own in the SDK, not work around per plugin:**

- **`$comment`, not `description`.** `autodocodec-schema` renders codec documentation as `"$comment"` (verified at `Schema.hs:133` in 0.2.0.1 and `:111` in 0.1.0.4). Tool-calling models read `description`. The SDK's manifest builder must rewrite `$comment` → `description` on the way out, and a golden test must pin that. *(HIGH confidence on the library behavior; MEDIUM on the exact downstream sensitivity.)*
- **No `additionalProperties: false`.** Record object schemas emit `properties` + `required` only. If strict function-calling mode is wanted, the SDK injects the key centrally.

Both are ~20 lines in one `DeepSeek.Plugin.Schema` module, applied uniformly. That is the correct place for them.

**`openapi3` 3.2.4/3.2.5 — REJECT.** Maintained (biocad, uploaded 2026-04-22) and its Generic `ToSchema` uses `description` natively. But its dependency closure is `lens` **and** `optics-core` **and** `optics-th` **and** `generics-sop` **and** `template-haskell` **and** `insert-ordered-containers` **and** `http-media` **and** `cookie` **and** `QuickCheck` **and** `base-compat-batteries`. That is an OpenAPI document toolkit; the need here is a schema for a function's arguments. Wrong weight class for an SDK third parties link.

**`aeson-schemas` 1.4.2.1 — REJECT (category error).** It is schema-*first*: a TH quasiquoter that declares a schema and gives you typed `get` accessors for *reading* JSON. It does not emit JSON Schema documents from Haskell types. Well maintained (brandonchinn178, 2026-01), just not this problem.

**Hand-rolled Generic `HasSchema` — REJECT.** It reimplements `autodocodec` minus the validator, minus `$defs`/recursion handling, minus the `anyOf`/`oneOf` sum encoding the `ContentBlock` union needs, and it cannot express field descriptions. This is precisely the case the harness's "prefer maintained dependencies over hand-rolling" policy is aimed at: `autodocodec` genuinely deletes owned code *and* owned tests.

---

## Decision 4: Framing, Concurrency, Cancellation

### Stdio line framing: plain `bytestring`

Read `stdin` as bytes with a hand-written bounded splitter over `Data.ByteString.hGetSome`; decode with `Data.Aeson.eitherDecodeStrict'`.

This is what the ecosystem actually does. The Haskell MCP server's stdio transport (`mcp-0.3.2.0`, `MCP/Server/Stdio.hs`) is a `BS.hGetLine` loop with `eitherDecodeStrict'` and `hSetBuffering LineBuffering` — no streaming library. Its own Haddock documents its limits ("blocks indefinitely … no timeout", single-threaded), which is exactly the bar this SDK must clear, and `BS.hGetLine` is unbounded, which is the hostile-input hole to close.

- **`conduit` 1.3.6.1 — not in the core.** Excellent library, but it buys backpressure and composition this loop does not need; the reader is ~40 lines. Revisit only when the transport interface grows an HTTP/WebSocket implementation.
- **`streaming` 0.2.4.0 — REJECT.** Last uploaded 2023-07-06, `Stability: Experimental`, far smaller ecosystem than conduit.
- **Never `hGetLine`/`String` on a `Char`-mode handle.** GHC's locale decoder throws on invalid UTF-8; `aeson` handles UTF-8 itself. `hSetBinaryMode` both ends.

### Concurrency: `async` + `stm`, nothing more

- `async` 2.2.6 for one `Async` per in-flight request, so a slow `tool/execute` cannot stall the read loop.
- `stm` for `TVar (Map RequestId InFlight)` and for the outbound `TBQueue Frame` drained by a single writer thread. A dedicated writer makes frame interleaving impossible by construction and gives one place to `hFlush`.
- **`unliftio` 0.2.25.1 — REJECT for v1.** It earns its keep when handlers are polymorphic in `m`. PROJECT.md fixes `execute :: a -> Exec -> IO v`. Adding `MonadUnliftIO` to a concrete-`IO` API is a constraint with no current consumer. Revisit only if the handler monad is generalized.
- **`ki` 1.0.1.2 — REJECT.** Good structured-concurrency design, but last uploaded 2024-07-15 with thin ecosystem adoption; `async` is what every Haskell reviewer already knows.
- **`monad-logger` / `katip` / `fast-logger` / `hslogger` — REJECT.** An SDK should not choose its consumers' logging framework. Expose a `Logger :: Text -> IO ()` field in the plugin `Config` (a `LogAction`-shaped function, borrowing `co-log-core`'s idea without the dependency) defaulting to a `stderr` writer.

### Cancellation

`$/cancel {id}` flips a per-request `TVar Bool`; `Exec.cancelled` is `readTVar` on it. Cooperative by default — an async exception at an arbitrary point inside a plugin author's `IO` handler is not something an SDK should inflict without opt-in.

Three things the design must nail, none of which any library provides:

1. **A cancelled request still owes a response.** JSON-RPC 2.0 has no cancellation semantics. Adopt LSP's codes, which every agent-tooling implementer already recognizes: **`RequestCancelled = -32800`**, `ContentModified = -32801`, `ServerCancelled = -32802` (verified in `lsp-types-2.1.1.0/generated/Language/LSP/Protocol/Internal/Types/LSPErrorCodes.hs:74-76`). The harness's transport surfaces `code` verbatim through `JsonRpcResponseError`, so the bridge can distinguish cancellation from failure.
2. **Escalation must be configurable, not hardcoded.** If a handler ignores the flag past `cancelGraceMs`, escalate to `Async.cancel`. That is a deployment-varying tunable → a validated `Config` field.
3. **`AsyncCancelled` must not become a `-32603` frame.** Use `Control.Exception.Safe`'s sync/async split; a bare `try @SomeException` around the handler will swallow the cancellation and report it as an internal error.

---

## What NOT to Use

| Avoid | Specific problem | Use instead |
|-------|------------------|-------------|
| `json-rpc` (any version) | `encodeConduit` emits no newline separator (`Interface.hs:88`); pulls `stm-conduit` (last upload **2018-09-27**), `monad-logger`, and **`QuickCheck`** into the runtime closure; imposes `ReaderT Session` + `MonadLoggerIO`; hardcoded 128-slot channels; emits batch frames the harness silently drops; `lts-22.43` pins the 2022 release | Owned `DeepSeek.Plugin.Wire` |
| `jsonrpc-tinyclient` | Client-only, HTTP/WebSocket only, no server, no stdio, no notifications; exists for `hs-web3` | Owned `DeepSeek.Plugin.Wire` |
| `lsp` / `lsp-types` (as transport) | Implements `Content-Length` header framing, not newline framing; pulls `row-types`, `lens`, `lens-aeson`, `text-rope`, `prettyprinter`, `uuid` | Owned framing; borrow only the `-32800` code and `LogAction` shape |
| `openapi3` | `lens` + `optics-core` + `optics-th` + `generics-sop` + `template-haskell` + 6 more, to schema a function's arguments | `autodocodec-schema` |
| `aeson-schemas` | Schema-first TH quasiquoter for *reading* JSON; does not emit JSON Schema documents | `autodocodec-schema` |
| Hand-rolled Generic `HasSchema` | Cannot express model-facing field descriptions; reimplements `$defs`, sum encoding, and the validator | `autodocodec` `HasCodec` |
| `streaming` | Last upload 2023-07-06, `Stability: Experimental`, thin ecosystem | plain `bytestring` (or `conduit` if a real streaming transport arrives) |
| `conduit` in the core loop | Dependency and monad complexity for a ~40-line bounded line reader | plain `bytestring` |
| `unliftio` in v1 | No current consumer — the handler monad is concrete `IO` | `async` + `stm` directly |
| `ki` | Last upload 2024-07-15, thin adoption; reviewer familiarity matters for an SDK | `async` |
| `monad-logger` / `katip` / `hslogger` | An SDK must not pick its consumers' logging framework | `Logger :: Text -> IO ()` in `Config` |
| `tasty` as a second runner | Two runners double the CI surface for no gain | `hspec` + `hspec-golden` only |
| `Data.ByteString.hGetLine` unbounded | No frame-size limit — hostile-input memory exhaustion; the harness peer's reader is likewise unbounded | Bounded reader with a `maxFrameBytes` `Config` field |
| `String`/`hPutStrLn` on `stdout` | Locale-dependent encoding; interleaving; hidden newlines | `ByteString` + binary mode + single writer thread + explicit `hFlush` |
| Non-`-threaded` executable | A blocking foreign call in one handler stalls the RTS and freezes the read loop, making `$/cancel` unresponsive | `-threaded -rtsopts "-with-rtsopts=-N"` |

---

## Alternatives Considered

| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| `lts-24.56` (GHC 9.10.3) | `lts-23.28` (GHC 9.8.4) | A survey of target plugin authors shows GHC 9.10 is a real adoption barrier. Keeps `aeson` 2.2 and `autodocodec-schema` 0.2; loses `GHC2024` |
| `lts-24.56` | `lts-22.44` (GHC 9.6.6) | Only if an unlisted hard requirement forces GHC 9.6. Never `lts-22.43` — `.44` is the series terminal |
| Owned `DeepSeek.Plugin.Wire` | `jsonrpc-0.2.0.0` | It reaches 1.0 / enters a Stackage LTS / gains non-DPella reverse dependencies, **and** MPL-2.0 propagation to plugin authors' binaries is acceptable |
| `autodocodec` | `openapi3` | The SDK later needs to emit an OpenAPI document (it does not; the harness has Typert for that) |
| `hspec-golden` | `tasty-golden` 2.3.6 | Byte-exact `ByteString` goldens become awkward under `hspec-golden`. `tasty-golden` is `ByteString`-native and more actively maintained (2026-02 vs 2024-04) — but adopting it means moving the whole suite to `tasty`, not running both |
| `async` + `stm` | `ki` | The handler model grows a nursery/scope hierarchy that `withAsync` nesting can no longer express clearly |
| plain `bytestring` framing | `conduit` + `conduit-extra` | The HTTP/WebSocket transports listed as out-of-scope for v1 actually get built |
| Cooperative `TVar Bool` cancellation | `Async.cancel` immediately | Never as the default. Only as a configurable escalation after `cancelGraceMs` |

---

## Version Compatibility

| Package | Compatible with | Notes |
|---------|-----------------|-------|
| `jsonrpc-0.2.0.0` | `base >=4.18 && <4.22`, `aeson >=2.1 && <2.3`, `text >=2.0 && <2.2` | Satisfied by lts-22.43 (base 4.18.2.1 / aeson 2.1.2.1 / text 2.0.2), lts-23.28 (4.19.2.0 / 2.2.3.0 / 2.1.1), **and** lts-24.56 (4.20.2.0 / 2.2.5.0 / 2.1.3). The envelope decision is independent of the pin decision |
| `json-rpc >= 1.1.0` | `aeson >= 2.2` | Unreachable on `lts-22.43` (aeson 2.1.2.1) without breaking the snapshot — you get the 2022 release |
| `autodocodec-schema-0.2.x` | `autodocodec >= 0.4.0.0` | The `IntegerSchema` fix is gated on this pair; `lts-22.43` has neither |
| `aeson 2.2.x` | drops `Data.Aeson.Parser` | Moved to `attoparsec-aeson`. Not used here (we call `eitherDecodeStrict'`), but it breaks older transitive users |
| `GHC2024` | GHC >= 9.10 | Only on `lts-24.x`. On `lts-22`/`lts-23` use `GHC2021` — still better than the template's `Haskell2010` |
| Library `base` bounds | `>=4.18 && <4.22` | Deliberately wider than the resolver pin: GHC 9.6 through 9.12. The snapshot is a dev pin, not the compatibility promise |
| `optparse-applicative 0.18.1.0` | lts-22, lts-23, lts-24 | Identical across all three — pin-independent |
| `hspec-golden 0.2.2.0` | lts-22, lts-23, lts-24 | Identical across all three — pin-independent |

---

## Confidence Summary

| Claim | Confidence | Basis |
|-------|------------|-------|
| Snapshot contents and GHC versions for lts-22.43 / 23.28 / 24.56 | HIGH | `stackage.org` snapshot pages and `cabal.config`, fetched 2026-08-25 |
| `lts-22.44` is the lts-22 terminal | HIGH | `stackage.org/lts-22` redirect |
| `json-rpc` `encodeConduit` emits no newline; deps include `QuickCheck`/`stm-conduit` | HIGH | Read `json-rpc-1.0.4` source (`Interface.hs:88`, `:339`) and its `.cabal` |
| `stm-conduit` last uploaded 2018-09-27 | HIGH | Hackage package page |
| `jsonrpc-0.2.0.0` semantics, bounds, size, adoption | HIGH | Read the tarball; Hackage metadata (upload date, reverse deps, downloads) |
| `autodocodec-schema` `$comment` vs `description`; `IntegerSchema` in 0.2 only | HIGH | Read 0.1.0.4 and 0.2.0.1 sources side by side |
| `aeson` 2.2 optional-field members | HIGH | aeson 2.2.0.0 changelog |
| LSP `-32800` / `-32801` / `-32802` | HIGH | `lsp-types-2.1.1.0` generated metamodel source |
| Harness framing rules (newline, object params, no batch, id types) | HIGH | Read `packages/sdk/protocol/src/transport.ts` |
| GHC 9.6.6 absent locally / installed on demand by Stack | HIGH | Observed live: `ls ~/.ghcup/ghc` before, and `ghcup install ghc 9.6.6` triggered by `stack build` |
| `jsonrpc-0.2.0.0` builds on lts-22.43 **and** lts-24.56 with no `allow-newer` | HIGH | Built both locally (see Empirical Verification) |
| `Int` renders `number` on lts-22.43 vs `integer` on lts-24.56 | HIGH | A/B `encode (jsonSchemaViaCodec @Int)` in `stack ghci` on both resolvers |
| aeson key order != record declaration order | HIGH | Observed in the probe output |
| MPL-2.0 source-availability propagation to plugin authors | MEDIUM | Plain reading of MPL 2.0 §3.2; not legal advice |
| Downstream model sensitivity to `description` vs `$comment` | MEDIUM | General tool-calling schema convention; not verified against a DeepSeek request trace |
| `jsonrpc` long-term maintenance | LOW-MEDIUM | Single release, single vendor, 2 stars, 30 downloads. Actively used by its author's MCP stack, but no independent adoption |

## Open Questions for the Roadmap

1. **Whose JSON Schema dialect does the bridge forward?** The manifest schema is consumed by `packages/core/tools` and eventually by DeepSeek's function-calling API. Whether `$defs`/`$ref` survive that path is unverified and should be settled with a real request trace in the bridge phase, not assumed.
2. **`ContentBlock` sum encoding.** `autodocodec`'s discriminated-union support (`disjointStringConstCodec` + `object`) needs a spike against the five real cases in `packages/llm/llm/src/types.ts` plus the `Unknown Value` fall-through. This is the one place the codec-first choice could get awkward.
3. **Cabal-file authoring.** Stack 3.11.1 bundles hpack 0.39.6; the scaffold is a raw `.cabal`. Pick one and gate it — a stale generated `.cabal` next to a `package.yaml` is a routine footgun.
4. **Coverage gate parity.** The harness enforces 100% per-file on the TypeScript bridge. Decide now what the Haskell side's HPC threshold is, and whether CI enforces it.

## Sources

- https://www.stackage.org/lts-22.43 and `/cabal.config` — snapshot contents (ghc-9.6.6, base-4.18.2.1, aeson-2.1.2.1, stm-2.5.1.0, bytestring-0.11.5.3, text-2.0.2, containers-0.6.7) — HIGH
- https://www.stackage.org/lts-23 → lts-23.28 (ghc-9.8.4) and https://www.stackage.org/lts → lts-24.56 (ghc-9.10.3), plus `/cabal.config` for both — HIGH
- https://www.stackage.org/lts → lts-22 terminal is lts-22.44 — HIGH
- https://hackage.haskell.org/package/json-rpc, `json-rpc-1.0.4` tarball (`src/Network/JSONRPC/Interface.hs`, `Data.hs`, `json-rpc.cabal`) — HIGH
- https://hackage.haskell.org/package/jsonrpc, `jsonrpc-0.2.0.0` tarball (`src/JSONRPC.hs`, `jsonrpc.cabal`) — HIGH
- https://hackage.haskell.org/package/jsonrpc-tinyclient — HIGH
- https://hackage.haskell.org/package/stm-conduit — upload date 2018-09-27 — HIGH
- `mcp-0.3.2.0` tarball (`src/MCP/Server/Stdio.hs`, `mcp.cabal`) — closest prior art for a Haskell stdio JSON-RPC agent server — HIGH
- `autodocodec-schema-0.1.0.4` and `-0.2.0.1` tarballs (`src/Autodocodec/Schema.hs`) — `$comment`, `IntegerSchema`, `validateAccordingTo` — HIGH
- https://hackage.haskell.org/package/autodocodec-0.6.0.0/changelog — 0.2→0.6 feature deltas — HIGH
- https://hackage.haskell.org/package/aeson-2.2.0.0/changelog — `omitField`, `.?=`, `Data.Aeson.Decoding`, `attoparsec-aeson` split — HIGH
- `lsp-types-2.1.1.0` tarball (`generated/.../LSPErrorCodes.hs`) — `-32800`/`-32801`/`-32802` — HIGH
- https://hackage.haskell.org/package/lsp, `/openapi3`, `/aeson-schemas`, `/streaming`, `/ki`, `/async`, `/hspec`, `/hspec-golden`, `/tasty-golden`, `/optparse-applicative` — maintenance recency — HIGH
- GitHub API: `jprupp/json-rpc` (pushed 2026-08-18, 35 stars), `DPella/jsonrpc` (pushed 2026-02-16, 2 stars) — HIGH
- `/home/jmsbpp/ai-agents/deepseek-harness/packages/sdk/protocol/src/transport.ts` — the framing this SDK must match — HIGH
- `/home/jmsbpp/ai-agents/deepseek-harness/packages/mcp/mcp-client/src/transport.ts` — how the harness spawns stdio peers (scrubbed env, `command`/`args`/`cwd`) — HIGH
- Local toolchain inspection: `ghc --version` (9.10.3), `stack --version` (3.11.1, hpack 0.39.6), `ls ~/.ghcup/ghc` (9.10.3, 9.8.4) — HIGH

---
*Stack research for: Haskell out-of-process agent-plugin SDK over NDJSON JSON-RPC 2.0*
*Researched: 2026-08-25*
