# Phase 1: Protocol Freeze and Toolchain Foundation - Research

**Researched:** 2026-08-25
**Domain:** Haskell toolchain scaffolding (Stack/hpack/GHC2024), tasty conformance-suite boilerplate with visible red state, GitHub Actions for Haskell, protocol prose + executable corpus
**Confidence:** HIGH — every toolchain and library claim below was verified by building and running a real probe package on `lts-24.56` today, not inferred from training data

<user_constraints>
## User Constraints (from CONTEXT.md)

### Scope directive (from the orchestrator, overriding)

> "Make this just stubs and boilerplate set up."

Phase 1 delivers scaffolding only — repinned toolchain, hpack package layout with library/executable/test-suite stanzas, tasty+hedgehog test-suite skeleton with `expectFail` wiring and the `EXPECTED.md` manifest meta-test, `corpus/` directory stubs for every required scenario (frames may be minimal placeholders that make scenarios red), a `PROTOCOL.md` skeleton with all section headings and the decided facts filled in, the ADR, and CI workflows. **No JSON-RPC implementation, no codec, no schema code.**

### Locked Decisions

**TDD approach (user-emphasized: tests before anything)**
- Corpus-first AND prose: the corpus scenarios are written first as the executable spec; `PROTOCOL.md` prose is written in the same phase and every example in it is a corpus frame (no prose-only examples).
- Corpus form: one directory per scenario, `corpus/<scenario>/host.jsonl` (frames the host sends) and `corpus/<scenario>/plugin.jsonl` (frames the plugin must emit). A tasty test group enumerates the directories at test time — one test per scenario.
- Red state is visible, never hidden: scenarios with no implementation yet are wrapped in `tasty-expected-failure`'s `expectFail`, and each such scenario has `corpus/<scenario>/EXPECTED.md` naming the phase that must flip it. A meta-test asserts every `expectFail` scenario is listed in that manifest; Phase 7 asserts the manifest is empty. **No `pending`, no whole-job `continue-on-error` for conformance.**
- Property families written up-front as failing/expected-fail signatures in Phase 1, filled in by the owning phase:
  1. Codec round-trips (`decode . encode`) for every envelope and manifest type — Phase 2/5.
  2. Hostile-frame totality: any ByteString line yields a frame or a `-32700` error, never an exception — Phase 2.
  3. Schema subset closure: every generated `DshSchema` passes a Haskell port of the harness's `assertSupportedJsonSchema` — Phase 4.
  4. Cancellation ordering as a Hedgehog state-machine (`Command`/`executeSequential`/`executeParallel`) over request/`$/cancel`/response interleavings: no leaked waiters, late cancels are no-ops — Phase 3.
- Precedent from the Python SDK (`deepseek-harness/python/sdk/tests/test_client.py`): test against a fake peer over real stdio, not mocks; committed expected outputs re-recorded with an explicit flag (`tasty-golden --accept` mirrors `--update-snapshots`); mirror its error taxonomy (`TransportClosedError` / `SdkProtocolError` / `JsonRpcError{code,message,data}`) as Haskell exception types.

**Test stack**
- Runner: `tasty`. Libraries: `tasty-hunit`, `tasty-golden`, `tasty-hedgehog`, `tasty-expected-failure`. Properties in `hedgehog` (chosen over QuickCheck for built-in state-machine testing and integrated shrinking).
- Golden comparison is decode-then-compare (aeson key order is not declaration order); byte-exact goldens only where recorded from real output.

**Cancellation semantics (resolves the roadmap blocker)**
- After `$/cancel {id}` reaches a running handler, the plugin ALWAYS replies with a JSON-RPC error `-32800` (`RequestCancelled`, LSP's code). The host's waiter resolves on that reply; the `tools/pre-execute` waterfall can therefore never wedge on a cancelled guard.
- A `$/cancel` for an unknown or already-completed id is ignored silently (no error frame).
- `-32003` from ARCHITECTURE.md is retired; the error table in `PROTOCOL.md` supersedes the research draft.

**Method naming and versioning**
- Inherit the harness's existing wire style: requests use slashes (`initialize`, `tool/execute`, `guard/decide`, `subagent/run`, `shutdown`), notifications use dots (`section.changed`), and `$/cancel` keeps its LSP spelling.
- `protocolVersion` is an integer starting at `1`; any breaking change bumps it; no negotiation — mismatch fails loud on both sides (PROTO-03) and is a corpus scenario.
- Handshake is host-initiated (`initialize` request → manifest result), per research.
- Distinct id namespaces: host-issued request ids and plugin-issued request ids must never collide (concrete scheme is Claude's discretion; the corpus normalizer makes it invisible to comparisons).

**Corpus home and id normalization**
- Corpus lives at this repo's root: `corpus/<scenario>/{host.jsonl,plugin.jsonl,EXPECTED.md?}`. The bridge PR vendors a copy into deepseek-harness with a checksum test so drift fails loud.
- Normalization rule both implementations apply before comparing: every JSON-RPC `id` is rewritten to an ordinal by first appearance per direction (`h1,h2,…` for host-issued, `p1,p2,…` for plugin-issued). Implementations may use any id scheme.
- Required scenarios (from PROTO-02 and roadmap criterion 2): handshake, tool call, tool failure, guard decision (allow / deny / ask), in-flight cancellation, malformed frames (junk line, oversize, non-object params, batch array), shutdown, `protocolVersion` mismatch.

**Maintainer alignment (E2E-03)**
- Decide here, no upstream issue: the user maintains both repos. Write `docs/adr/0001-harness-e2e-tiering.md` choosing the Node fixture-plugin snapshot as the sanctioned deepseek-harness CI path, with a real-binary keyed e2e living in this repo; the bridge PR's Agent Note links the ADR.

**CI and package layout**
- GitHub Actions on both remotes (`origin` fork and `upstream`): `haskell-actions/setup` with Stack cache; `stack build` + `stack test` blocking; `hlint` and `fourmolu` run with `continue-on-error` until Phase 7 flips them to required together with emptying the expectFail manifest.
- hpack `package.yaml` is the source; the generated `.cabal` is committed for cabal users. Stanzas: library `dsh-plugin`, executable(s) with `-threaded -rtsopts "-with-rtsopts=-N"`, test-suite `conformance`. Language `GHC2024`, `-Wall`.
- Repin `stack.yaml` to `lts-24.56` (GHC 9.10.3), replacing the scaffold's `lts-22.43`.

### Claude's Discretion

- Exact id scheme per namespace, error-code table beyond `-32700/-32600/-32601/-32602/-32603/-32800/-32004`, JSONL field ordering, module/directory layout under `src/`, and the wording of the large-integer policy (must forbid integers outside the JS safe range per SCHEMA-05).

### Deferred Ideas (OUT OF SCOPE)

- TS-side test discipline for the bridge (coverage, corpus vendoring test) — Phase 8.
- Mutation testing of the Haskell suite — backlog.
- Corpus timing/race expressiveness beyond ordering (a DSL) — revisit only if Phase 3's Hedgehog model proves insufficient.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| PROTO-01 | `PROTOCOL.md` freezes method names, handshake manifest, `protocolVersion`, error codes (incl. `-32004 TOOL_FAILED` vs `-32603`, `-32800 RequestCancelled`), object-only `params`, no batches | §PROTOCOL.md Skeleton — verified section list, the verbatim harness facts to cite (`transport.ts:261` framing, `objectParams()`, `-32601`/`-32603`), the LSP `-32800` provenance, the harness lossless-JSON stance to copy, and the naming conflict to resolve (§Open Questions Q1) |
| PROTO-02 | Shared conformance corpus covers handshake, tool call, guard decision, cancellation, malformed frames, shutdown; both Haskell and TS bridge tests replay it | §Corpus Layout and Stub Frames — 12 verified scenario directories, minimal JSONL frames consistent with locked decisions, `EXPECTED.md` format, id-normalization note. §Pattern 1 (directory enumeration) and §Pattern 2 (EXPECTED.md-driven `expectFail`) make the corpus executable in Phase 1 with zero implementation |
| PROTO-03 | Handshake is host-initiated; `protocolVersion` mismatch fails loud, no shim | §Corpus scenario `version-mismatch` + §PROTOCOL.md Skeleton §5. Confirmed the harness's own SDK uses a bare `initialize` request (`packages/sdk/protocol/src/types.ts:HarnessSdkRequestMap`) so the style matches |
| PROTO-04 | Manifest declares tools, guards, sections, subagent providers | §PROTOCOL.md Skeleton §4 + §Manifest facts read live from `packages/core/tools/src/index.ts` (`PreToolDecision`, mandatory `output`, `presentCall`/`presentResult` purity) and `json-schema.ts` (the enforced keyword subset). Manifest appears as the `handshake` scenario's `plugin.jsonl` result — a corpus frame, not prose |
| TOOL-01 | `stack.yaml` pinned to `lts-24.56`; library + executable + test-suite with `GHC2024`, `-Wall`, `-threaded -rtsopts "-with-rtsopts=-N"` | §Standard Stack (all versions verified against `lts-24.56/cabal.config` today) + §package.yaml Shape (built and run locally; hpack 0.39.6 emits `default-language: GHC2024` and the exact `ghc-options` line) |
| TOOL-02 | CI builds, tests, runs `hlint`/`fourmolu` on push to `main` and PRs, on both remotes | §GitHub Actions — verified action versions, the node20 removal deadline that disqualifies `hlint-setup@v2.4.10`, cache keys, and the identical-file-on-both-remotes mechanics |
| E2E-03 | Maintainer alignment on e2e tiering recorded | §ADR — MADR 4.0.0 template fetched live, the `python-runtime` job precedent read from `deepseek-harness/.github/workflows/ci.yml:301`, and the verbatim `docs/testing.md` clauses the ADR must argue against |
</phase_requirements>

## Summary

Everything in this phase is boilerplate, and boilerplate is only worth doing once. I built a throwaway probe package on `lts-24.56` with the exact stanza layout, the exact test-library set, and a `conformance` suite that enumerates `corpus/` at runtime, then ran it. It compiles under `GHC2024` with `-Wall` and it exits `0` with four visibly-red expected failures. The whole Phase 1 deliverable is reproducible from the transcript in §Code Examples — nothing below is speculative.

Three findings change how the plan should be written. **First**, `hedgehog 1.5` replaced `HTraversable` with `barbies`' `FunctorB`/`TraversableB` for `Command` inputs; the `HTraversable`-based state-machine code every tutorial shows does not compile. The Phase 3 property signature must be written against the new class today or Phase 3 rewrites it. **Second**, `expectFail` on a test that *passes* is reported as `unexpected success` and **fails the suite** — verified. That is the forcing function the whole red-state design depends on, but it also means Phase 1's stub scenario bodies must genuinely fail (`assertFailure "not implemented"`), otherwise CI is red on day one. **Third**, `haskell-actions/hlint-setup@v2.4.10` and `hlint-run@v2.4.10` still declare `runs.using: node20`, and GitHub removes Node 20 from runners on **2026-09-16** — three weeks out. Their `main` branches are already `node24` but carry no tag. Do not use the tagged releases.

Two smaller course corrections: `fourmolu` is **not in `lts-24.56`** (nor any snapshot), so it can only be a downloaded binary in CI, never a `stack install` — `haskell-actions/run-fourmolu@v13` (node24, fetches a release binary) is the right tool. And the corpus JSONL files must **not** be wired as `tasty-golden` goldens, because `--accept` would rewrite the hand-authored spec with aeson's key order; goldens belong on generated artifacts (`--dump-manifest` output), the corpus belongs to `goldenTest`-with-a-decoding-comparator or plain HUnit.

**Primary recommendation:** Write `package.yaml` + `stack.yaml` + `test/Main.hs` exactly as verified in §Code Examples, drive `expectFail` *from the presence of* `corpus/<scenario>/EXPECTED.md` rather than a parallel hardcoded list, make every unimplemented scenario body an `assertFailure`, and build CI on `haskell-actions/setup@v2.12.0` with `--system-ghc --no-install-ghc`.

## Standard Stack

All versions below were read from `https://www.stackage.org/lts-24.56/cabal.config` on 2026-08-25, or from `~/.ghcup/ghc/9.10.3/.../package.conf.d` for GHC boot libraries. `https://www.stackage.org/lts` still redirects to `/lts-24.56` — the pin is the current series terminal, not a stale one.

### Core (toolchain)

| Component | Version | Purpose | Why Standard |
|-----------|---------|---------|--------------|
| Stackage snapshot | **`lts-24.56`** | dependency set | Current LTS terminal, verified live today. Fixes the `autodocodec-schema` `integer`-vs-`number` regression and unlocks `GHC2024` (see STACK.md Decision 1) |
| GHC | 9.10.3 | compiler | Bundled with `lts-24.56`; already installed on this machine |
| Stack | 3.11.1 (bundles hpack 0.39.6) | build + snapshot pin | Installed. `snapshot:` key (not the legacy `resolver:`) |
| hpack | 0.39.6 (via Stack) | `package.yaml` → `.cabal` | Emits `default-language: GHC2024` from `language: GHC2024` — verified |

### Core (library runtime deps — declared in Phase 1, unused until Phase 2+)

| Library | Version in lts-24.56 | Source |
|---------|----------------------|--------|
| `base` | 4.20.2.0 | GHC boot |
| `aeson` | 2.2.5.0 | snapshot |
| `bytestring` | 0.12.2.0 | GHC boot |
| `text` | 2.1.3 | GHC boot |
| `containers` | 0.7 | GHC boot |
| `stm` | 2.5.3.1 | GHC boot |
| `async` | 2.2.6 | snapshot |
| `safe-exceptions` | 0.1.7.4 | snapshot |
| `autodocodec` | 0.5.0.0 | snapshot |
| `autodocodec-schema` | 0.2.0.1 | snapshot |
| `optparse-applicative` | 0.18.1.0 | snapshot |

**None require `extra-deps`.** `stack.yaml` needs no `extra-deps:` block at all — verified by a clean build.

### Test-suite stack (the CONTEXT-locked choice)

| Library | Version in lts-24.56 | Purpose | Verified |
|---------|----------------------|---------|----------|
| `tasty` | **1.5.4** | runner | built + ran |
| `tasty-hunit` | **0.10.2** | `testCase`, `assertFailure`, `@?=` | built + ran |
| `tasty-golden` | **2.3.6** | `goldenVsString`, `goldenTest`, `--accept`, `--no-create` | built + ran |
| `tasty-hedgehog` | **1.4.0.2** | `testProperty` | built + ran against `hedgehog 1.5` |
| `tasty-expected-failure` | **0.12.3** | `expectFail`, `expectFailBecause`, `ignoreTestBecause` | built + ran against `tasty 1.5.4` |
| `hedgehog` | **1.5** | properties + state machine | built + ran |
| `directory` | 1.3.8.5 (boot) | `listDirectory`, `doesDirectoryExist`, `doesFileExist` | built + ran |
| `filepath` | 1.5.4.0 (boot) | `(</>)` | built + ran |
| `typed-process` | 0.2.13.0 | spawning the built binary (Phase 7 e2e; declare now) | resolved |
| `temporary` | 1.3 | test scratch dirs | resolved |

**No `extra-deps` needed for any of these.** The four-library `tasty` set plus `hedgehog` all resolve inside `lts-24.56`.

### Tools that are NOT in the snapshot

| Tool | Status | Consequence |
|------|--------|-------------|
| `hlint` | **3.10 IS in lts-24.56** | but `stack install hlint` compiles `ghc-lib-parser` (many minutes). Use a downloaded release binary in CI |
| `fourmolu` | **NOT in lts-24.56, not in any snapshot** | Cannot be `stack install`ed against the pin. Latest Hackage is `0.20.1.0` (2026-08-07, `ghc-lib-parser >=9.14 && <9.15`). Use `haskell-actions/run-fourmolu@v13`, which downloads a release binary |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `tasty` set | `hspec` + `hspec-golden` (STACK.md's original recommendation) | **Superseded by CONTEXT.md.** `hspec` has no equivalent of `tasty-expected-failure`'s "unexpected success = failure" semantics, which is the entire red-state forcing function. `tasty` is correct for this design |
| `hedgehog` | `QuickCheck 2.15.0.1` + `tasty-quickcheck 0.11.1` | Locked to hedgehog. QuickCheck has no in-tree state machine (`quickcheck-state-machine` is a separate, thinner package) |
| `haskell-actions/hlint-setup@v2.4.10` | `curl` the `hlint-3.10-x86_64-linux.tar.gz` release asset | **Prefer the curl.** The tagged action is `node20`; Node 20 is removed from runners 2026-09-16 |
| `expectFail` for red scenarios | `ignoreTestBecause` | **Forbidden by CONTEXT.md** ("no `pending`"). Verified: `IGNORED` tests never fail and never flip — the exact failure mode the design rejects |
| committing only `package.yaml` | committing only the `.cabal` | Locked: commit both. Add the staleness gate in §CI |

**Installation:** nothing to install. `stack build --test` resolves the entire set from `lts-24.56`.

**Version verification performed:**
```bash
curl -s https://www.stackage.org/lts-24.56/cabal.config | grep -E '^ *(tasty|hedgehog|aeson) =='
curl -sI https://www.stackage.org/lts | grep -i location   # -> /lts-24.56
stack build --test --no-run-tests                          # EXIT=0, 76 dep actions
stack test                                                 # EXIT=0, "All 8 tests passed"
```

## Architecture Patterns

### Recommended Project Structure

```
haskell-deepseek-plugin-sdk/
├── package.yaml                  # hpack source of truth
├── haskell-deepseek-plugin-sdk.cabal   # generated, COMMITTED
├── stack.yaml                    # snapshot: lts-24.56
├── stack.yaml.lock               # COMMITTED (snapshot sha256)
├── PROTOCOL.md                   # the frozen wire (PROTO-01..04)
├── README.md
├── CHANGELOG.md
├── fourmolu.yaml                 # formatter config (Phase 1, enforced Phase 7)
├── .hlint.yaml                   # lint config incl. -XGHC2024 (Phase 1, enforced Phase 7)
├── .github/workflows/ci.yml      # identical file, pushed to BOTH remotes
├── docs/adr/
│   ├── README.md                 # ADR index + "we use MADR 4.0.0"
│   └── 0001-harness-e2e-tiering.md
├── corpus/                       # the executable spec — see below
│   └── <scenario>/{host.jsonl,plugin.jsonl,EXPECTED.md?}
├── src/DeepSeek/Plugin/          # library — EMPTY-ISH IN PHASE 1
│   └── ...                       # module stubs only, no logic
├── app/                          # executable(s)
│   └── echo/Main.hs              # placeholder `dsh-plugin-echo`
└── test/
    ├── Main.hs                   # tasty entry: defaultMain =<< buildTree
    ├── Conformance/Corpus.hs     # scenario enumeration + EXPECTED.md manifest
    ├── Conformance/Properties.hs # the four expected-fail property signatures
    └── golden/                   # generated-artifact goldens (NOT the corpus)
```

**Module layout under `src/` is Claude's discretion.** Recommendation: create the module files that Phase 2–6 will fill, each with a real module header, a JSDoc-equivalent Haddock comment stating its contract, and no exports beyond what is needed to compile. This makes the `-Wmissing-export-lists` and `-Wall` regime a Phase 1 concern rather than a Phase 2 surprise. Do **not** create stub *types* — an empty `data Frame` that Phase 2 must redesign is worse than an empty module.

### Pattern 1: Build the `TestTree` in `IO`, then `defaultMain`

`tasty` has two ways to get filesystem contents into a tree. Use the first.

```haskell
main :: IO ()
main = do
  names     <- listScenarios                      -- IO [FilePath]
  scenarios <- traverse (\n -> (,) n <$> readExpected n) names
  defaultMain (allTests scenarios)
```

**Why not `withResource`:** `withResource` is for resources with *acquire/release* lifetimes (a temp dir, a spawned process). It cannot change the *shape* of the tree — the test names must be known before the resource is acquired, so it cannot produce one test per discovered directory. Reserve `withResource` for Phase 7's built-binary e2e, where the resource is the spawned `dsh-plugin-echo` process. Both forms were compiled and run in the probe.

**Working directory:** `stack test` runs the test binary with cwd = the package root, so the relative path `"corpus"` resolves. Verified. Do not use `getCurrentDirectory`-relative gymnastics or `Paths_` data-files.

### Pattern 2: Drive `expectFail` FROM `EXPECTED.md`, not from a parallel list

CONTEXT.md asks for two things: `expectFail`-wrapped red scenarios, and a meta-test asserting every `expectFail` scenario appears in the manifest. If the wrapper decision and the manifest are two separate lists, the meta-test only proves they were kept in sync by hand.

**Make the manifest the single source of truth:** a scenario is `expectFail`-wrapped **iff** `corpus/<scenario>/EXPECTED.md` exists. Then:

| Situation | Outcome | Why it is right |
|-----------|---------|-----------------|
| Scenario red, `EXPECTED.md` present | `FAIL (expected: …)` — suite green | intended red state, named and visible |
| Scenario green, `EXPECTED.md` still present | **`OK (unexpected: …)` — suite RED** | forces the implementing phase to delete the file; verified empirically |
| Scenario red, no `EXPECTED.md` | plain `FAIL` — suite red | a regression, correctly loud |
| Scenario green, no `EXPECTED.md` | `OK` | the steady state |

The meta-test then becomes *semantic* rather than bookkeeping: assert every `EXPECTED.md` names an owning phase from a known set. Phase 7's "manifest is empty" assertion becomes `listDirectory corpus >>= \ss -> filterM hasExpected ss >>= (@?= [])`.

**`EXPECTED.md` format** (Claude's discretion; this shape parses with one `takeWhile`):

```markdown
# Flipped by: Phase 3 — Peer, Async Router, and Cancellation

**Requirement:** WIRE-04

## Why this is red

No router exists yet, so no `$/cancel` handling and no `-32800` reply.

## What flipping it requires

The plugin replies `-32800` to the cancelled `tool/execute` request, and a
late `$/cancel` for a completed id produces no frame at all.
```

Line 1 is the machine-readable part; everything below is for humans.

### Pattern 3: Unimplemented scenario bodies must genuinely fail

This is the single most likely way to get Phase 1 wrong. Because `expectFail` turns a *passing* test into a suite failure, a scenario stub that trivially succeeds ("read the file, assert it is non-empty") makes CI red the moment it is written.

```haskell
replayScenario :: FilePath -> IO ()
replayScenario name = do
  host <- BL.readFile (corpusRoot </> name </> "host.jsonl")
  BL.null host @?= False
  assertFailure ("replay not implemented: " <> name)   -- Phase 2 deletes this line
```

Same rule for the four property signatures: each must have a body that fails (`assert False`, `n === n + 1`, or an `Ensure` callback that cannot hold). Verified: the probe's four expected failures produce `EXIT=0` with all four visibly listed.

### Pattern 4: Hedgehog 1.5 state machines use `barbies`, not `HTraversable`

**This is a live API change that every tutorial predates.** `hedgehog-1.5/src/Hedgehog.hs` re-exports `FunctorB`, `TraversableB`, and `Rec` from `Hedgehog.Internal.Barbie` and lists `HTraversable(..)` under a literal `-- * Deprecated` heading. `Command`'s `input` type now needs `TraversableB`, and an `HTraversable` instance does **not** satisfy it — the probe failed with `Could not deduce 'TraversableB Open'` until the instances were switched.

The library's own Haddock prescribes the derivation:

```haskell
data Register v = Register Name (Var Pid v)
  deriving (Eq, Show, Generic, FunctorB, TraversableB)

newtype Unregister (v :: Type -> Type) = Unregister Name
  deriving (Eq, Show, Generic)
  deriving anyclass (FunctorB, TraversableB)
```

Signatures verified from source (`Hedgehog/Internal/State.hs`):

```haskell
Hedgehog.Gen.sequential
  :: (MonadGen gen, MonadTest m)
  => Range Int -> (forall v. state v) -> [Command gen m state] -> gen (Sequential m state)

executeSequential
  :: (MonadTest m, MonadCatch m, HasCallStack)
  => (forall v. state v) -> Sequential m state -> m ()
```

Note the rank-2 `(forall v. state v)` argument — GHC2024 includes `RankNTypes` (via GHC2021) so no pragma is needed, but the model state must be genuinely polymorphic in `v`.

Phase 1 writes this skeleton with an `Ensure` callback that fails, wrapped in `expectFailBecause "Phase 3 …"`. Phase 3 replaces the model, not the plumbing.

### Pattern 5: Goldens go on generated artifacts, never on the corpus

`tasty-golden`'s `--accept` calls the update function with the **tested** value. If the corpus JSONL files are wired as golden files, `--accept` overwrites the hand-authored spec with whatever the implementation produced — including aeson's key order, which is *not* record declaration order (empirically confirmed in STACK.md). That silently launders a bug into the spec.

| Artifact | Mechanism | Rationale |
|----------|-----------|-----------|
| `corpus/<s>/plugin.jsonl` | `Test.Tasty.Golden.Advanced.goldenTest` with a **decode-then-compare** comparator, or plain `testCase` | CONTEXT.md's "decode-then-compare"; `--accept` must be either absent or explicitly reviewed |
| `test/golden/manifest.json` (`--dump-manifest` output, Phase 5) | `goldenVsString` | Recorded from real output, byte-exact, `--accept` is the sanctioned re-record path |

`goldenTest`'s verified signature (`tasty-golden-2.3.6/Test/Tasty/Golden/Advanced.hs`):

```haskell
goldenTest
  :: TestName
  -> IO a                       -- read golden (must be strict — the update may follow)
  -> IO a                       -- produce tested value
  -> (a -> a -> IO (Maybe String))   -- Nothing = equal; golden is the FIRST argument
  -> (a -> IO ())               -- update the golden file
  -> TestTree
```

Instantiate `a ~ [Value]` (decoded frames) and the comparator becomes order-insensitive for free.

`Test.Tasty.Golden` also exports `findByExtension`, `writeBinaryFile`, `createDirectoriesAndWriteFile`, and the options `SizeCutoff`, `DeleteOutputFile`, `NoCreateFile`.

### Pattern 6: hpack stanza shape

Verified generated output for the exact `package.yaml` in §Code Examples:

```cabal
executable probe-exe
  ghc-options: -Wall -threaded -rtsopts -with-rtsopts=-N
  default-language: GHC2024
```

Facts confirmed:
- `language: GHC2024` at top level → `default-language: GHC2024` in every stanza. Per-stanza override is also supported.
- Top-level `ghc-options:` is **prepended** to each stanza's own list, so `-Wall` at top level and `-threaded -rtsopts '-with-rtsopts=-N'` per executable/test-suite composes correctly.
- `'-with-rtsopts=-N'` must be single-quoted in YAML (leading `-` plus `=`); it emits unquoted and cabal parses it as one token.
- hpack auto-injects `Paths_<pkg>` into `other-modules` **and** `autogen-modules`. Harmless under `-Wall`. To suppress it, list `other-modules:` explicitly or use `generated-other-modules`.
- hpack writes `cabal-version: 2.2`. `default-language: GHC2024` needs **Cabal ≥ 3.12** to parse regardless of that declaration — a plain-cabal consumer on an older `cabal-install` will fail. If the compatibility promise matters, either raise the declared `cabal-version` or document the minimum in the README.
- Stack **regenerates the `.cabal` on every build** and overwrites hand-edits — verified by appending a marker to the `.cabal` and watching `stack build --dry-run` erase it.

### Anti-Patterns to Avoid

- **`ignoreTest` / `ignoreTestBecause` for red scenarios:** produces `IGNORED`, never runs, never flips, never fails. Explicitly forbidden by CONTEXT.md ("no `pending`"). Verified behavior in the probe.
- **`continue-on-error: true` on the conformance job:** forbidden by CONTEXT.md. It is permitted *only* on the `hlint` and `fourmolu` steps until Phase 7.
- **A parallel Haskell list of expect-fail scenario names:** see Pattern 2. Two lists means the meta-test proves nothing about the implementation.
- **Stub types in `src/`:** an empty `data Frame = Frame` that Phase 2 must redesign creates a false compile-time contract. Stub *modules* with Haddock, not stub types.
- **`ghc-options: -Werror` in `package.yaml`:** a warning becomes an unbuildable clone for a contributor on a slightly different GHC. Use `stack build --pedantic` in CI instead (verified flag: "Pass the `-Wall` and `-Werror` flags to GHC").
- **Wiring `corpus/**` as `goldenVsString` goldens:** see Pattern 5.
- **Trusting `haskell-actions/hlint-setup@v2.4.10`:** node20; see §GitHub Actions.

## Corpus Layout and Stub Frames

Twelve scenario directories cover the CONTEXT-required list (malformed frames expands to four, guard decision to three). Phase 1 writes minimal-but-valid frames; Phase 2+ replaces placeholders with the real sequences.

| # | Directory | Covers | Owning phase (`EXPECTED.md` line 1) |
|---|-----------|--------|--------------------------------------|
| 1 | `handshake` | `initialize` → manifest (PROTO-03, PROTO-04) | Phase 5 |
| 2 | `version-mismatch` | `protocolVersion` ≠ 1 → loud failure, no shim (PROTO-03) | Phase 5 |
| 3 | `tool-call` | `tool/execute` → `{value, content}` | Phase 5 |
| 4 | `tool-failure` | handler throws → `-32004 TOOL_FAILED` (not `-32603`) | Phase 5 |
| 5 | `guard-allow` | `guard/decide` → `{"kind":"allow"}` | Phase 6 |
| 6 | `guard-deny` | `guard/decide` → `{"kind":"deny","reason":…}` | Phase 6 |
| 7 | `guard-ask` | `guard/decide` → `{"kind":"ask","reason"?:…}` | Phase 6 |
| 8 | `cancel-inflight` | `$/cancel` during `tool/execute` → `-32800` reply | Phase 3 |
| 9 | `cancel-late` | `$/cancel` for a completed id → **no frame at all** | Phase 3 |
| 10 | `malformed-junk-line` | non-JSON line → `-32700`, no crash | Phase 2 |
| 11 | `malformed-shape` | non-object `params`, batch array, non-scalar `id` | Phase 2 |
| 12 | `shutdown` | `shutdown` request → `{}` then clean exit | Phase 5 |

`malformed-oversize` may be folded into #11 or split out; the `maxFrameBytes` rejection is WIRE-02 (Phase 2) either way. Splitting it means committing a large file, so folding it in and generating the oversize line at test time is the better call.

### Stub frames (consistent with every locked decision)

`corpus/handshake/host.jsonl`:
```json
{"jsonrpc":"2.0","id":"h-1","method":"initialize","params":{"protocolVersion":1,"hostInfo":{"name":"deepseek-harness","version":"0.1.1-rc.2"},"cwd":"/workspace"}}
```

`corpus/handshake/plugin.jsonl` (the manifest is PROTO-04's spec, as a frame, not prose):
```json
{"jsonrpc":"2.0","id":"h-1","result":{"protocolVersion":1,"pluginInfo":{"name":"echo","version":"0.1.0"},"tools":[{"name":"echo","description":"Echo text back.","parameters":{"type":"object","properties":{"text":{"type":"string","description":"Text to echo."}},"required":["text"],"additionalProperties":false},"output":{"schema":{"type":"object","properties":{"echoed":{"type":"string"}},"required":["echoed"],"additionalProperties":false}},"presentation":{"mode":"generic"}}],"guards":[{"id":"no-forbidden","match":{"tools":["echo"]},"failPolicy":"closed"}],"sections":[{"name":"echo:guidance","order":150,"text":"The echo tool returns its input."}],"subagents":[]}}
```

`corpus/cancel-inflight/host.jsonl`:
```json
{"jsonrpc":"2.0","id":"h-1","method":"tool/execute","params":{"callId":"call-1","tool":"echo","arguments":{"text":"slow"}}}
{"jsonrpc":"2.0","method":"$/cancel","params":{"id":"h-1"}}
```

`corpus/cancel-inflight/plugin.jsonl`:
```json
{"jsonrpc":"2.0","id":"h-1","error":{"code":-32800,"message":"Request cancelled"}}
```

`corpus/cancel-late/plugin.jsonl` — **an empty file with a trailing newline is the correct content**: a late `$/cancel` produces no frame. The `PROTOCOL.md` prose must state that an empty `plugin.jsonl` means "emits nothing", so the file is not mistaken for a stub.

`corpus/malformed-junk-line/host.jsonl`:
```
this is not json
{"jsonrpc":"2.0","id":"h-1","method":"shutdown","params":{}}
```

`corpus/malformed-junk-line/plugin.jsonl`:
```json
{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}
{"jsonrpc":"2.0","id":"h-1","result":{}}
```

The second frame is load-bearing: it proves the reader did not crash and stayed in sync.

`corpus/version-mismatch/host.jsonl`:
```json
{"jsonrpc":"2.0","id":"h-1","method":"initialize","params":{"protocolVersion":2,"hostInfo":{"name":"deepseek-harness","version":"0.1.1-rc.2"},"cwd":"/workspace"}}
```

`corpus/version-mismatch/plugin.jsonl`:
```json
{"jsonrpc":"2.0","id":"h-1","error":{"code":-32001,"message":"protocolVersion mismatch: host 2, plugin 1"}}
```

### Id normalization

The locked rule: rewrite every `id` to an ordinal by first appearance **per direction** (`h1,h2,…` host-issued, `p1,p2,…` plugin-issued). Two consequences the plan must honor:

1. The literal ids in the corpus (`"h-1"` above) are cosmetic. Write them readable; the normalizer erases them.
2. The **direction** of an id is determined by which file the frame *originating* the request appears in, not by the frame's own file. A plugin's *response* to `h-1` carries a host-issued id and normalizes to `h1`. State this explicitly in `PROTOCOL.md`, or two implementations will normalize differently.

## PROTOCOL.md Skeleton

The phase deliverable is "complete enough to read alone." Section list, with what Phase 1 fills in vs. leaves as a heading:

| § | Heading | Phase 1 content |
|---|---------|-----------------|
| 1 | Scope and status | **Full.** Pre-1.0, no compatibility promise, `protocolVersion: 1` |
| 2 | Framing | **Full.** NDJSON; one compact JSON object per line; `encode msg <> "\n"`; UTF-8 bytes; no embedded newline. Cite `deepseek-harness/packages/sdk/protocol/src/transport.ts:261` (`this.output.write(\`${JSON.stringify(message)}\n\`)`) and `:182` (`buffer.indexOf('\n')`) |
| 3 | Envelope rules | **Full.** `params` is always a JSON object (harness `objectParams()` collapses arrays/scalars to `{}` — silent data loss, so object-only is a hard rule); **batches unsupported** (a JSON array matches neither the id nor method dispatch and is dropped silently); `id` is `string \| number`, round-tripped verbatim; unknown members dropped on rebuild |
| 4 | Handshake manifest | **Full.** Points at `corpus/handshake/plugin.jsonl` as the normative example. Field table for `tools`/`guards`/`sections`/`subagents` (PROTO-04). Tool names must match `/^[A-Za-z0-9_-]{1,64}$/`; fail loud, never normalize |
| 5 | Versioning | **Full.** Integer, exact equality, no negotiation, no shim; mismatch → error frame + both versions in the message (PROTO-03) |
| 6 | Methods | **Full.** Table below |
| 7 | Error codes | **Full.** Table below |
| 8 | Cancellation | **Full.** `$/cancel {id}` notification; running handler always replies `-32800`; unknown/completed id is silently ignored |
| 9 | Lossless JSON / number policy | **Full.** Integers outside ±(2⁵³−1) are rejected, never rounded (SCHEMA-05). Mirror the harness's `code-runtime-python` stance (`hasUnsafeIntegerToken` reads the raw frame text to catch tokens `JSON.parse` would silently round; non-finite and negative-zero rejected) |
| 10 | Hostile input | **Full (policy), stub (limits).** Every inbound frame is shape-validated and **rebuilt**, not cast — forged extra fields never ride along; a non-scalar id can never be echoed into a reply; junk drops to a `-32700` error rather than throwing. `maxFrameBytes` is a `Config` field; the default value is Phase 2's |
| 11 | Id namespaces | **Full.** Host-issued and plugin-issued ids never collide; the concrete scheme is implementation-private; the corpus normalization rule (§ above) makes it invisible |
| 12 | Conformance corpus | **Full.** Layout, `EXPECTED.md` semantics, the empty-`plugin.jsonl` convention, the normalization algorithm as pseudocode |
| 13 | Shutdown | **Full.** `shutdown` request → `{}`; stdin EOF is equivalent; SIGPIPE is a clean exit |

### Methods table (Phase 1 writes this)

| Direction | Method | Kind | Params | Result |
|---|---|---|---|---|
| host → plugin | `initialize` | request | `{protocolVersion, hostInfo:{name,version}, cwd}` | the manifest |
| host → plugin | `tool/execute` | request | `{callId, tool, arguments}` | `{value, content}` |
| host → plugin | `guard/decide` | request | `{guard, callId, tool, arguments}` | `{kind:"allow"\|"deny"\|"ask", reason?}` |
| host → plugin | `subagent/run` | request | `{runId, subagent, prompt, cwd}` | `{stopReason, lastAssistantMessage?}` |
| host → plugin | `shutdown` | request | `{}` | `{}` |
| host → plugin | `$/cancel` | notification | `{id}` | — |
| plugin → host | `section.changed` | notification | `{name, text}` | — |

`initialize` and `shutdown` are bare (no slash) — this matches the harness's own `HarnessSdkRequestMap` (`'initialize'`, `'session/prompt'`, `'shutdown'`), read live from `packages/sdk/protocol/src/types.ts`. Notifications use dots, matching `'session.event'`, `'session.status'`, `'subagent.started'`, `'subagent.finished'` in the same file. See §Open Questions Q1 for the `section.changed` vs `section/changed` conflict.

### Error codes (Phase 1 writes this; entries beyond the locked seven are discretionary)

| Code | Name | Meaning |
|---|---|---|
| −32700 | `PARSE_ERROR` | malformed JSON line |
| −32600 | `INVALID_REQUEST` | not a JSON-RPC 2.0 frame (incl. batch array, non-object `params`) |
| −32601 | `METHOD_NOT_FOUND` | unknown method |
| −32602 | `INVALID_PARAMS` | params fail the method's record |
| −32603 | `INTERNAL_ERROR` | unhandled exception in the SDK — **operator-actionable** |
| −32800 | `REQUEST_CANCELLED` | handler observed cancellation (LSP's code) |
| −32004 | `TOOL_FAILED` | the author's handler failed — a **domain** failure the model reads |
| −32001 | `PROTOCOL_VERSION_MISMATCH` | *(discretionary)* handshake versions differ → fail activation loud |
| −32002 | `UNKNOWN_CONTRIBUTION` | *(discretionary)* tool/guard/section/subagent id not in the manifest |
| −32005 | `INVALID_ARGUMENTS` | *(discretionary)* model args failed the derived schema |
| −32006 | `SHUTTING_DOWN` | *(discretionary)* request arrived after drain began |

`-32003 CANCELLED` from the ARCHITECTURE.md draft is **retired** per CONTEXT.md. The `-32004`/`-32603` split is load-bearing: both surface as `isError` to the model, only the second is an operator-actionable log line.

Verified harness facts to cite: the transport itself emits only `-32601` (missing handler) and `-32603` (handler threw) — `packages/sdk/protocol/src/transport.ts:59-60, :229, :236`. `-32800`'s provenance is `lsp-types`' generated `LSPErrorCodes.hs` (`RequestCancelled = -32800`).

## GitHub Actions

### Verified action versions (GitHub API, 2026-08-25)

| Action | Latest tag | Latest **release** | `runs.using` | Verdict |
|--------|-----------|--------------------|--------------|---------|
| `haskell-actions/setup` | `v2.12.0` (also `v2.12`, `v2`) | `v2.11.0` (2026-04-15) | **node24** on both | **Use `@v2.12.0`.** Its `versions.json` lists GHC `9.10.3` explicitly |
| `haskell-actions/run-fourmolu` | `v13` (2026-06-24) | `v13` | **node24** | **Use `@v13`** with an explicit `version:` input |
| `haskell-actions/hlint-setup` | `v2.4.10` (2024-06-20) | `v2.4.10` | **node20** (`main` branch is node24, untagged) | **Avoid the tag** — see below |
| `haskell-actions/hlint-run` | `v2.4.10` (2024-06-20) | `v2.4.10` | **node20** (`main` is node24, untagged) | **Avoid the tag** |
| `actions/cache` | v4 | — | node24 | standard |
| `actions/checkout` | v6 (what deepseek-harness uses) | — | node24 | standard |

### The node20 deadline (HIGH confidence, time-sensitive)

GitHub's changelog: Node 20 reached EOL in April 2026; actions were **forced to Node 24 by default on 2026-06-02**, and **Node 20 is removed from the runner on 2026-09-16** — three weeks from today. `hlint-setup`/`hlint-run` at `v2.4.10` declare `node20`. Their `main` branches were pushed 2026-08-17 and already declare `node24`, but no release carries that fix.

**Recommendation:** skip the actions entirely for hlint. Download the release binary:

```yaml
      - name: hlint
        continue-on-error: true      # required until Phase 7
        run: |
          curl -fsSL https://github.com/ndmitchell/hlint/releases/download/v3.10/hlint-3.10-x86_64-linux.tar.gz \
            | tar xz --strip-components=1 -C /usr/local/bin hlint-3.10/hlint
          hlint src app test
```

Asset name `hlint-3.10-x86_64-linux.tar.gz` verified against the `ndmitchell/hlint` `v3.10` release (2025-02-02; also ships `-osx` and `-windows` assets). If the maintained-action route is preferred instead, pin the `main`-branch SHA, not `@v2.4.10`.

### hlint and fourmolu must be told about GHC2024

Neither tool reads `default-language` from the `.cabal` file. Both use `ghc-lib-parser` with their own default extension set.

- `.hlint.yaml`: add `- arguments: [-XGHC2024]` so lint parses `LambdaCase`, `GADTs`, `DataKinds`, and friends.
- `run-fourmolu`: pass `extra-args: --ghc-opt -XGHC2024`.

`fourmolu 0.20.1.0` builds against `ghc-lib-parser >=9.14 && <9.15` — a syntactic superset of GHC 9.10, so GHC2024 source parses. *(MEDIUM confidence on the exact flag spellings — verify with one CI run before Phase 7 makes these blocking.)*

### GHC provisioning: use the action's GHC, not Stack's

Two workable shapes; the second is materially faster and is what to use.

| Shape | Cost |
|-------|------|
| `enable-stack: true` + `stack-no-global: true` + `stack-setup-ghc: true` | Stack downloads its own GHC into `~/.stack`; the cache carries ~2 GB |
| `enable-stack: true` + `ghc-version: '9.10.3'` + `stack build --system-ghc --no-install-ghc` | The action installs GHC 9.10.3 via ghcup (cached by the action); Stack reuses it |

`--system-ghc` and `--no-install-ghc` were verified locally (`stack --system-ghc --no-install-ghc build --dry-run` → `EXIT=0`). Keeping them as **CLI flags** rather than `stack.yaml` keys means local contributors still get Stack-managed GHC from a clean clone (TOOL-03).

### Cache keys

`haskell-actions/setup` exposes `steps.<id>.outputs.stack-root`. Cache both the Stack root and `.stack-work`:

```yaml
      - uses: actions/cache@v4
        with:
          path: |
            ${{ steps.setup.outputs.stack-root }}
            .stack-work
          key: ${{ runner.os }}-stack-${{ hashFiles('stack.yaml.lock', 'package.yaml') }}
          restore-keys: ${{ runner.os }}-stack-
```

Keying on `stack.yaml.lock` + `package.yaml` (per PITFALLS.md Pitfall 14) is correct here because `package.yaml` is the dependency source of truth. Do **not** key on the generated `.cabal` — Stack rewrites it during the build, so the post-build hash may differ from the pre-build hash.

### The stale-`.cabal` gate

Since both `package.yaml` and the generated `.cabal` are committed, a stale `.cabal` is the routine footgun (STACK.md Open Question 3). Verified: Stack regenerates the `.cabal` on every build and overwrites hand-edits. So the gate is one line after the build step:

```yaml
      - name: generated .cabal is current
        run: git diff --exit-code -- '*.cabal'
```

### Both remotes

The workflow is **one file**. GitHub Actions runs whatever `.github/workflows/*.yml` exists on the branch in *that* repository, so pushing the same commit to `origin` (`JMSBPP/haskell-deepseek-plugin-sdk-develop`) and `upstream` (`d2p-finance/haskell-deepseek-plugin-sdk`) gives two independent runs of an identical definition. Confirmed both remotes are configured in this clone. Two things the plan must state:

1. **Actions must be enabled on both repositories** in Settings → Actions (a fork has Actions disabled by default until an owner enables them). This is a manual step, not a file — call it out as a task with a human check.
2. Triggers must cover both: `on: {push: {branches: [main]}, pull_request: {branches: [main]}}`. If the fork's default branch is not `main`, add it.

### Concurrency and job matrix

Phase 1 needs one Linux job. Windows and macOS are named risks (PITFALLS.md Pitfall 2/9 — newline mode, process termination) but the phase has no transport to test, so a matrix now is cost with no signal. Add `runs-on: ubuntu-latest` plus:

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

Record "Windows/macOS lanes land in Phase 2 with the transport" as a `README` or `.planning` note so it is a deferral, not an omission.

## The ADR (E2E-03)

`docs/adr/0001-harness-e2e-tiering.md`, MADR 4.0.0 format (template fetched live from `adr/madr@4.0.0`; MADR 4.0.0 released September 2024, still current). Front-matter keys: `status`, `date`, `decision-makers`, `consulted`, `informed`. Sections: **Context and Problem Statement**, *Decision Drivers*, **Considered Options**, **Decision Outcome** (+ *Consequences*, *Confirmation*), *Pros and Cons of the Options*, *More Information*. Bold = mandatory in MADR's minimal variant.

Also write `docs/adr/README.md` declaring the format and numbering — otherwise ADR 0002 is a fresh argument about format.

### Content the ADR must contain

**Context.** deepseek-harness CI has **no Haskell anywhere** — verified by grep across all 18 workflow files today; the only hit for "stack" is the word in a comment. Meanwhile `docs/testing.md` says, verbatim:

> Every non-trivial model-, protocol-, or human-visible change adds or updates a keyless scenario in the same PR through a runnable example's owning snapshot suite. Package tests, e2e assertions, mock/test-only compositions, and PR rationale do not replace the assembled transcript

and, separately, "Prefer the real implementation over a mock: Mock only the expensive or non-deterministic boundary (LLM adapter, network, clock); keep everything downstream real."

**Options** (from PITFALLS.md Pitfall 15, which the ADR should cite):
- (a) Add a GHC/Stack job to deepseek-harness CI. **Precedent exists:** `python-runtime` is a distinct required PR job (`.github/workflows/ci.yml:301`, reusing `build-exe-for-python-sdk.yml`) that exists solely to run the Python SDK snapshot, and it is listed in the aggregate gate's `needs` at `ci.yml:481`. Cost: a GHC toolchain, CI minutes, a cross-repo binary dependency.
- (b) Commit a prebuilt echo binary. Platform matrix, binary size in git, provenance — unattractive.
- (c) **Node fixture plugin replaying `corpus/plugin.jsonl`** (BRIDGE-09's ~50-line fixture) as the sanctioned harness-CI path, with the real-binary e2e living in *this* repo (E2E-01 keyless, E2E-02 keyed).

**Decision (locked by CONTEXT.md): option (c).**

**Confirmation** — this is the section that makes the ADR more than an opinion, and it is where the corpus earns its keep. The argued exception to "prefer the real implementation" rests on the corpus being a *shared* artifact, not a mock:
- The Node fixture replays the **same** `corpus/plugin.jsonl` bytes the Haskell `conformance` suite replays, so "the fixture and the real plugin agree" is a checked fact, not an assumption.
- The bridge PR vendors the corpus with a **checksum test** so drift fails loud (CONTEXT.md, Phase 8).
- `--dump-manifest` output is diffed against the harness's own `assertSupportedJsonSchema` (the `code-runtime-python` `protocol-mirror.e2e.ts` pattern) so the Haskell schema is proven against the real validator.
- This repo owns the real-binary tiers: E2E-01 (keyless, built binary through the fake host) and E2E-02 (keyed, `dsh --profile headless`).

**More Information.** Link `docs/testing.md`, `.agents/notes/implemented/testing/2026-06-19-real-api-e2e-ci.md`, `ci.yml:301`, and note the revisit trigger: if the harness ever gains a GHC job for another reason, option (a) supersedes this.

**Status.** `accepted`. `decision-makers:` is the repo owner (both repos). CONTEXT.md is explicit that no upstream issue is needed.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Marking a test as known-red | A `Bool` flag + `when`, or a skipped test | `tasty-expected-failure`'s `expectFailBecause` | Only it makes an *unexpected pass* a failure — verified. That property is the entire design |
| Re-recording expected output | A custom `--update` flag | `tasty-golden`'s `--accept` / `--no-create` | Already wired into `defaultMain` by the ingredient; verified in `--help` |
| Generating `.cabal` from `package.yaml` | A Makefile invoking `hpack` | `stack build` (bundles hpack 0.39.6) | Stack regenerates on every build; a separate hpack binary is another version to pin |
| State-machine property scaffolding | Hand-rolled interleaving generators | `hedgehog`'s `Gen.sequential` / `executeSequential` / `Gen.parallel` | Integrated shrinking on the *action sequence* is what makes a cancellation-race failure readable |
| `FunctorB`/`TraversableB` instances | Hand-written `htraverse` | `deriving anyclass (FunctorB, TraversableB)` via `Generic` | The library's own Haddock prescribes it; hand-written instances get the `Rec` wrapping wrong |
| Installing hlint/fourmolu | `stack install` against the pin | Release binaries (curl / `run-fourmolu@v13`) | `fourmolu` is not in any snapshot; `hlint` compiles `ghc-lib-parser` for many minutes |
| ADR format | A bespoke template | MADR 4.0.0 | A format argument on ADR 0002 costs more than adopting one now |

**Key insight:** every item here is a place where the "obvious" hand-rolled version silently *weakens* a gate rather than failing — a skipped test that never flips, a golden that never re-records, a stale `.cabal` that builds anyway. Phase 1's job is gates that bite.

## Common Pitfalls

### Pitfall 1: A stub scenario that accidentally passes turns CI red
**What goes wrong:** `expectFail (testCase name (pure ()))` reports `OK (unexpected: …)` and **fails the suite**. Verified in the probe: `2 out of 8 tests failed`.
**Why it happens:** the natural first draft of a stub is "read the file and assert it is non-empty," which passes.
**How to avoid:** every unimplemented scenario body ends in `assertFailure`; every unimplemented property has a body that cannot hold.
**Warning sign:** `OK (unexpected:` anywhere in the tasty output.

### Pitfall 2: Hedgehog 1.5's `Command` needs `TraversableB`, not `HTraversable`
**What goes wrong:** `Could not deduce 'TraversableB Open' arising from a use of 'Command'`. Every pre-1.5 tutorial and blog post uses `HTraversable`, which `Hedgehog` still exports under a `-- * Deprecated` heading.
**How to avoid:** `deriving (Generic)` + `deriving anyclass (FunctorB, TraversableB)`, with `{-# LANGUAGE DeriveAnyClass #-}` (GHC2024 supplies `DeriveGeneric` and `DerivingStrategies` but **not** `DeriveAnyClass`).
**Warning sign:** copying a state-machine example dated before 2025.

### Pitfall 3: `--accept` overwrites the hand-authored corpus
**What goes wrong:** wiring `corpus/<s>/plugin.jsonl` as a `goldenVsString` golden means `stack test --ta --accept` rewrites the *spec* with the implementation's output, including aeson's key order (which is not declaration order).
**How to avoid:** goldens on generated artifacts only; the corpus uses `goldenTest` with a decode-then-compare comparator, or plain HUnit. See Pattern 5.
**Warning sign:** a corpus file changing in a diff that was supposed to only touch Haskell.

### Pitfall 4: `hlint`/`fourmolu` cannot parse GHC2024 by default
**What goes wrong:** parse errors on `\case`, `data ... where`, or promoted types, because neither tool reads `default-language` from the `.cabal`.
**How to avoid:** `.hlint.yaml` gets `- arguments: [-XGHC2024]`; `run-fourmolu` gets `extra-args: --ghc-opt -XGHC2024`.
**Warning sign:** lint failures on files that compile cleanly. *(Both steps are `continue-on-error` until Phase 7, so this pitfall hides until Phase 7 makes them blocking — verify the flags in Phase 1, not Phase 7.)*

### Pitfall 5: Committed `.cabal` drifts from `package.yaml`
**What goes wrong:** a contributor edits `package.yaml`, Stack silently regenerates the `.cabal` locally, and only the `package.yaml` change is staged. Cabal-only users then build the old layout.
**How to avoid:** `git diff --exit-code -- '*.cabal'` after `stack build` in CI, plus a pre-commit hook locally.
**Warning sign:** the `.cabal`'s `hpack version` header comment disagrees with `stack --version`'s bundled hpack.

### Pitfall 6: `default-language: GHC2024` under `cabal-version: 2.2`
**What goes wrong:** hpack writes `cabal-version: 2.2`, but the `GHC2024` token needs Cabal ≥ 3.12 to parse. A plain-`cabal` user on an older `cabal-install` gets an unhelpful parse error.
**How to avoid:** state the minimum `cabal-install`/GHC in the README, or set `verbatim`/`cabal-version` explicitly in `package.yaml`.

### Pitfall 7: `-Werror` in `package.yaml`
**What goes wrong:** a new GHC minor adds a warning and a clean clone stops building for contributors.
**How to avoid:** `stack build --pedantic` in CI only (verified flag). Keep `-Wall -Wcompat -Widentities -Wincomplete-record-updates -Wincomplete-uni-patterns -Wmissing-export-lists -Wmissing-home-modules -Wpartial-fields -Wredundant-constraints` in `package.yaml`.

### Pitfall 8: Actions disabled on the fork
**What goes wrong:** the workflow file is pushed to both remotes and only one shows runs; TOOL-02 looks satisfied on `upstream` and silently is not on `origin` (or vice versa).
**How to avoid:** make "enable Actions in Settings on both repos, observe a green run on each" an explicit, human-verified task with two run URLs recorded.

### Pitfall 9: `-N` plus parallel golden writes
**What goes wrong:** `-with-rtsopts=-N` makes tasty default `--num-threads` to the core count (confirmed in `--help`). Two golden tests writing to the same output path race.
**How to avoid:** one golden file per test; never share an output path. Not an issue in Phase 1's single golden, but the plan should state the rule before Phase 5 adds manifest goldens.

## Code Examples

Every block below was compiled and executed on `lts-24.56` / GHC 9.10.3 today.

### `stack.yaml`

```yaml
snapshot: lts-24.56
packages:
- .
```

Nothing else. No `extra-deps`, no `system-ghc`, no `install-ghc` — CI passes `--system-ghc --no-install-ghc` on the command line so a clean local clone still works with zero setup (TOOL-03). Commit the generated `stack.yaml.lock`:

```yaml
packages: []
snapshots:
- completed:
    sha256: 121a2b65e6842f67819409330694d068e6276f64df87faaf2a66c0016ddf277b
    size: 732456
    url: https://raw.githubusercontent.com/commercialhaskell/stackage-snapshots/master/lts/24/56.yaml
  original: lts-24.56
```

### `package.yaml` (verified shape; names adapted to this project)

```yaml
name: haskell-deepseek-plugin-sdk
version: 0.1.0.0
license: BSD-3-Clause
license-file: LICENSE
synopsis: Haskell SDK for DeepSeek Harness out-of-process plugins
category: Development
extra-source-files:
  - README.md
  - CHANGELOG.md
  - PROTOCOL.md

language: GHC2024

ghc-options:
  - -Wall
  - -Wcompat
  - -Widentities
  - -Wincomplete-record-updates
  - -Wincomplete-uni-patterns
  - -Wmissing-export-lists
  - -Wmissing-home-modules
  - -Wpartial-fields
  - -Wredundant-constraints

library:
  source-dirs: src
  dependencies:
    - base >= 4.18 && < 4.22     # deliberately wider than the pin: 9.6..9.12
    - aeson >= 2.2 && < 2.3
    - async >= 2.2 && < 2.3
    - bytestring >= 0.11 && < 0.13
    - containers >= 0.6 && < 0.9
    - safe-exceptions >= 0.1.7 && < 0.2
    - stm >= 2.5 && < 2.6
    - text >= 2.0 && < 2.2

executables:
  dsh-plugin-echo:
    source-dirs: app/echo
    main: Main.hs
    ghc-options:
      - -threaded
      - -rtsopts
      - '-with-rtsopts=-N'
    dependencies:
      - base
      - haskell-deepseek-plugin-sdk
      - optparse-applicative >= 0.18 && < 0.20

tests:
  conformance:
    source-dirs: test
    main: Main.hs
    ghc-options:
      - -threaded
      - -rtsopts
      - '-with-rtsopts=-N'
    dependencies:
      - base
      - haskell-deepseek-plugin-sdk
      - aeson
      - bytestring
      - containers
      - directory
      - filepath
      - text
      - tasty
      - tasty-hunit
      - tasty-golden
      - tasty-hedgehog
      - tasty-expected-failure
      - hedgehog
      - typed-process
      - temporary
```

Generated stanza (verbatim from the probe's `.cabal`):

```cabal
test-suite conformance
  type: exitcode-stdio-1.0
  main-is: Main.hs
  hs-source-dirs:
      test
  ghc-options: -Wall -threaded -rtsopts -with-rtsopts=-N
  default-language: GHC2024
```

### `test/Main.hs` — the verified conformance skeleton

This exact file compiles under `GHC2024 -Wall` and produces `EXIT=0` with four visible expected failures. Split it into `Conformance/Corpus.hs` and `Conformance/Properties.hs` when writing the real thing; kept in one file here so the transcript is reproducible.

```haskell
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (filterM)
import Control.Monad.IO.Class (MonadIO)
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.Kind (Type)
import Data.List (sort)
import GHC.Generics (Generic)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath ((</>))

import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.ExpectedFailure (expectFailBecause)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range

corpusRoot :: FilePath
corpusRoot = "corpus"          -- stack test runs with cwd = package root

-- | Every scenario directory, paired with the first line of its EXPECTED.md
-- when one exists. Presence of EXPECTED.md is the ONLY thing that decides
-- whether a scenario is expect-fail wrapped.
listScenarios :: IO [(FilePath, Maybe String)]
listScenarios = do
  entries <- listDirectory corpusRoot
  names <- sort <$> filterM (doesDirectoryExist . (corpusRoot </>)) entries
  traverse (\n -> (,) n <$> readExpected n) names

readExpected :: FilePath -> IO (Maybe String)
readExpected name = do
  let f = corpusRoot </> name </> "EXPECTED.md"
  ok <- doesFileExist f
  if ok then Just . takeWhile (/= '\n') <$> readFile f else pure Nothing

main :: IO ()
main = listScenarios >>= defaultMain . allTests

allTests :: [(FilePath, Maybe String)] -> TestTree
allTests scenarios =
  testGroup
    "conformance"
    [ testGroup "corpus" (map scenarioTest scenarios)
    , manifestMetaTest scenarios
    , testGroup "properties" [roundTripStub, hostileStub, schemaSubsetStub]
    , testGroup "state-machine" [cancelOrderingStub]
    ]

scenarioTest :: (FilePath, Maybe String) -> TestTree
scenarioTest (name, expected) =
  maybe id expectFailBecause expected (testCase name (replayScenario name))

-- | Phase 2 replaces the assertFailure with a real replay through the
-- in-memory transport pair. Until then the body MUST fail: expectFail turns
-- an unexpected pass into a suite failure.
replayScenario :: FilePath -> IO ()
replayScenario name = do
  host <- BL.readFile (corpusRoot </> name </> "host.jsonl")
  BL.null host @?= False
  assertFailure ("replay not implemented: " <> name)

-- | The manifest meta-test: every EXPECTED.md names an owning phase.
-- Phase 7 replaces this with "no EXPECTED.md exists".
manifestMetaTest :: [(FilePath, Maybe String)] -> TestTree
manifestMetaTest scenarios =
  testCase "every EXPECTED.md names an owning phase" $
    case [n | (n, Just h) <- scenarios, not (namesAPhase h)] of
      [] -> pure ()
      xs -> assertFailure ("EXPECTED.md without an owning phase: " <> show xs)
  where
    namesAPhase h = any (`elem` map show [2 :: Int .. 7]) (words h)

roundTripStub :: TestTree
roundTripStub =
  expectFailBecause "Phase 2/5 own codec round-trips" $
    testProperty "decode . encode == id" . property $ do
      n <- forAll (Gen.int (Range.linear 0 100))
      n === n + 1

hostileStub :: TestTree
hostileStub =
  expectFailBecause "Phase 2 owns hostile-frame totality" $
    testProperty "any line yields a frame or -32700" . property $ do
      s <- forAll (Gen.string (Range.linear 0 64) Gen.unicode)
      assert (length s < 0)

schemaSubsetStub :: TestTree
schemaSubsetStub =
  expectFailBecause "Phase 4 owns schema subset closure" $
    testProperty "every DshSchema passes assertSupportedJsonSchema" . property $
      assert False

--------------------------------------------------------------------------------
-- Hedgehog state machine skeleton (Phase 3 replaces the model, not the plumbing)
--------------------------------------------------------------------------------

newtype ModelState (v :: Type -> Type) = ModelState Int

data Issue (v :: Type -> Type) = Issue
  deriving (Eq, Show, Generic)
  deriving anyclass (FunctorB, TraversableB)   -- hedgehog >= 1.5: barbies, NOT HTraversable

issueCommand :: (MonadGen g, MonadIO m) => Command g m ModelState
issueCommand =
  Command
    (const (Just (pure Issue)))
    (\Issue -> pure ())
    [ Update (\(ModelState n) _ _ -> ModelState (n + 1))
    , Ensure (\_ (ModelState n) _ () -> footnote "Phase 3 owns this model" >> assert (n < 0))
    ]

cancelOrderingStub :: TestTree
cancelOrderingStub =
  expectFailBecause "Phase 3 owns cancellation ordering" $
    testProperty "no leaked waiters; late cancels are no-ops" . property $ do
      actions <- forAll (Gen.sequential (Range.linear 1 10) (ModelState 0) [issueCommand])
      executeSequential (ModelState 0) actions
```

**Observed output** (`stack test`, `EXIT=0`):

```
conformance
  corpus
    cancel-inflight:                       FAIL (expected: # Flipped by: Phase 3)
    handshake:                             FAIL (expected: # Flipped by: Phase 5)
  every EXPECTED.md names an owning phase: OK
  properties
    decode . encode == id:                 FAIL (expected: Phase 2/5 own codec round-trips)
    any line yields a frame or -32700:     FAIL (expected: Phase 2 owns hostile-frame totality)
  state-machine
    no leaked waiters; …:                  FAIL (expected: Phase 3 owns cancellation ordering)

All N tests passed
```

And the forcing function, observed when a wrapped test passes:

```
    cancel-inflight:  OK (unexpected: flipped by a later phase: cancel-inflight)
2 out of 8 tests failed (0.01s)
```

### `.github/workflows/ci.yml`

```yaml
name: ci

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  build-and-test:
    name: stack build + conformance (ubuntu, ghc 9.10.3)
    runs-on: ubuntu-latest
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v6
        with:
          persist-credentials: false

      - id: setup
        uses: haskell-actions/setup@v2.12.0
        with:
          ghc-version: '9.10.3'
          enable-stack: true
          stack-version: 'latest'
          cabal-update: false

      - uses: actions/cache@v4
        with:
          path: |
            ${{ steps.setup.outputs.stack-root }}
            .stack-work
          key: ${{ runner.os }}-stack-${{ hashFiles('stack.yaml.lock', 'package.yaml') }}
          restore-keys: ${{ runner.os }}-stack-

      - name: build dependencies
        run: stack build --system-ghc --no-install-ghc --test --only-dependencies

      - name: build
        run: stack build --system-ghc --no-install-ghc --test --no-run-tests

      - name: generated .cabal is current
        run: git diff --exit-code -- '*.cabal'

      - name: conformance
        run: stack test --system-ghc --no-install-ghc --test-arguments="--no-create"

      # Advisory until Phase 7 flips these to required alongside emptying the
      # expectFail manifest (CONTEXT.md).
      - name: hlint
        continue-on-error: true
        run: |
          curl -fsSL https://github.com/ndmitchell/hlint/releases/download/v3.10/hlint-3.10-x86_64-linux.tar.gz \
            | tar xz --strip-components=1 -C "$RUNNER_TEMP" hlint-3.10/hlint
          "$RUNNER_TEMP/hlint" src app test

      - name: fourmolu
        continue-on-error: true
        uses: haskell-actions/run-fourmolu@v13
        with:
          version: '0.20.1.0'
          extra-args: '--ghc-opt -XGHC2024'
          pattern: |
            src/**/*.hs
            app/**/*.hs
            test/**/*.hs
```

`--no-create` is a `tasty-golden` option (verified in the test binary's `--help`) that makes a **missing golden file an error** instead of silently creating one — the CI-side half of the "goldens are reviewed, not conjured" discipline.

### `.hlint.yaml` and `fourmolu.yaml` (Phase 1 stubs)

```yaml
# .hlint.yaml
- arguments: [-XGHC2024]
```

```yaml
# fourmolu.yaml — generate with `fourmolu --print-defaults` and commit verbatim
indentation: 2
function-arrows: leading
comma-style: leading
import-export-style: diff-friendly
indent-wheres: false
record-brace-space: false
newlines-between-decls: 1
haddock-style: multi-line
let-style: auto
in-style: right-align
single-constraint-parens: auto
```

*(MEDIUM confidence on the `fourmolu.yaml` field set — generate it from the pinned binary rather than transcribing this, since fields have shifted between fourmolu minors.)*

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `HTraversable` for hedgehog `Command` inputs | `barbies`' `FunctorB` + `TraversableB`, derived via `Generic` | hedgehog 1.5 | **Every state-machine tutorial online is stale.** `HTraversable` is still exported under `-- * Deprecated` and does not satisfy `Command`'s constraint |
| `resolver:` in `stack.yaml` | `snapshot:` | Stack 2.15+ | Cosmetic but `stack init` templates now emit `snapshot:` |
| `default-language: Haskell2010` | `GHC2024` | GHC 9.10 | Needs Cabal ≥ 3.12 to parse; hpack 0.39.6 emits it from `language: GHC2024` |
| Actions on `node20` | `node24` | forced default 2026-06-02; node20 **removed 2026-09-16** | `haskell-actions/hlint-*@v2.4.10` is on borrowed time |
| MADR 3.x (`Deciders`, `Validation`) | MADR 4.0.0 (`decision-makers`, `Confirmation` under Decision Outcome) | September 2024 | Use the 4.0.0 key names |
| `haskell-actions/setup@v2` (node16/20 era) | `@v2.12.0` (node24), GHC list includes 9.10.3 / 9.12.4 / 9.14.1 | 2026 | Pin the point release |

**Deprecated/outdated in this repo today:**
- `stack.yaml` `snapshot: lts-22.43` — not even the LTS-22 terminal (`lts-22.44` is); replace with `lts-24.56`.
- The raw `haskell-deepseek-plugin-sdk.cabal` with a single `executable` stanza and `default-language: Haskell2010`, plus placeholder `githubuser` / `Author name here` / `example@example.com` metadata — replace wholesale.
- `src/Main.hs` (`putStrLn "hello world"`) — delete; `src/` becomes the library.

## Open Questions

1. **`section.changed` vs `section/changed` — a real conflict between locked inputs.**
   - What we know: CONTEXT.md (the locked, latest input) says "notifications use dots (`section.changed`)". The harness's own SDK confirms the dot convention for notifications (`session.event`, `session.status`, `subagent.started`, `subagent.finished` in `packages/sdk/protocol/src/types.ts`). But REQUIREMENTS.md **API-07** and **BRIDGE-06** both spell it `section/changed`, as does the ARCHITECTURE.md draft.
   - What's unclear: nothing technically — CONTEXT.md is the later, locked decision and it matches the harness.
   - **Recommendation:** `PROTOCOL.md` freezes `section.changed`. The plan should include a task to amend REQUIREMENTS.md API-07 and BRIDGE-06 in the same commit, so a Phase 6/9 implementer does not read the stale spelling. Do not silently diverge.

2. **Does `-32001 PROTOCOL_VERSION_MISMATCH` belong in the frozen table, or is the mismatch a transport-level abort?**
   - What we know: CONTEXT.md locks only `-32700/-32600/-32601/-32602/-32603/-32800/-32004` and leaves the rest to discretion. PROTO-03 requires "fails loud on both sides with no compatibility shim." The corpus needs *some* observable plugin behavior for the `version-mismatch` scenario.
   - **Recommendation:** freeze `-32001` and have the plugin reply with it, then exit non-zero. An error frame is observable in `plugin.jsonl`; a bare exit is not, and the corpus is the spec. Record the exit code in `PROTOCOL.md` §5 as well.

3. **Where does the corpus id-normalizer live in Phase 1?**
   - What we know: the rule is locked; two implementations must agree. Phase 1 is stubs-only.
   - **Recommendation:** `PROTOCOL.md` §12 carries the algorithm as language-neutral pseudocode (that *is* the Phase 1 deliverable), and the Haskell implementation is Phase 2's. Do not write a half-normalizer now — it will be rewritten against real frame types.

4. **`fourmolu.yaml` exact field set for 0.20.1.0.**
   - What we know: fields have shifted across minors; the block in §Code Examples is from an older release.
   - **Recommendation:** run `fourmolu --print-defaults` with the pinned 0.20.1.0 binary once and commit the output verbatim. One command, removes the guess.

5. **Windows/macOS CI lanes.**
   - What we know: PITFALLS.md flags newline mode, process termination, and console handling as untested; the harness runs a Windows lane. Phase 1 has no transport, so a matrix now yields no signal.
   - **Recommendation:** Linux-only in Phase 1; add the matrix in Phase 2 with the transport. Record the deferral explicitly so it is a decision, not an oversight.

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | `tasty 1.5.4` + `tasty-hunit 0.10.2` + `tasty-golden 2.3.6` + `tasty-hedgehog 1.4.0.2` + `tasty-expected-failure 0.12.3` + `hedgehog 1.5` |
| Config file | `package.yaml` → `test-suite conformance` (❌ Wave 0 — does not exist yet) |
| Quick run command | `stack test --fast --test-arguments="-p '/corpus/'"` |
| Full suite command | `stack test --test-arguments="--no-create"` |

Phase 1's suite is *fast* — no compilation of a library beyond stubs — so the quick/full split is mostly notional here. It matters from Phase 2 on.

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| PROTO-01 | `PROTOCOL.md` exists and contains all 13 frozen sections | doc gate | `for h in Framing 'Envelope rules' 'Handshake manifest' Versioning Methods 'Error codes' Cancellation 'Lossless JSON' 'Hostile input' 'Id namespaces' 'Conformance corpus' Shutdown; do grep -q "^## .*$h" PROTOCOL.md \|\| { echo "missing: $h"; exit 1; }; done` | ❌ Wave 0 |
| PROTO-01 | Every locked error code appears in the table | doc gate | `for c in -32700 -32600 -32601 -32602 -32603 -32800 -32004; do grep -q -- "$c" PROTOCOL.md \|\| exit 1; done` | ❌ Wave 0 |
| PROTO-01 | `params` object-only and no-batches rules are stated | doc gate | `grep -qi 'batches\? \(are \)\?unsupported' PROTOCOL.md && grep -qi 'always a JSON object' PROTOCOL.md` | ❌ Wave 0 |
| PROTO-02 | All 12 scenario directories exist with both frame files | unit (meta) | `stack test --test-arguments="-p '/corpus/'"` — the tree is built from `listDirectory`, so a missing directory is a missing test | ❌ Wave 0 |
| PROTO-02 | Every scenario's JSONL is line-delimited valid JSON (except the intentional junk line) | unit (meta) | new meta-test `testCase "every corpus line parses"`, with `malformed-*` scenarios exempted by name | ❌ Wave 0 |
| PROTO-02 | Scenario coverage matches the required list | unit (meta) | new meta-test comparing `listScenarios` against a hardcoded required-name list; a missing scenario fails | ❌ Wave 0 |
| PROTO-02 | Every red scenario names its owning phase | unit (meta) | `stack test --test-arguments="-p 'owning phase'"` (implemented in §Code Examples) | ❌ Wave 0 |
| PROTO-03 | Host-initiated handshake + mismatch scenarios are present and red | unit | `stack test --test-arguments="-p '/handshake/'"` and `-p '/version-mismatch/'` → both `FAIL (expected: …)` | ❌ Wave 0 |
| PROTO-04 | Manifest example declares tools, guards, sections, subagents | unit (meta) | new meta-test: decode `corpus/handshake/plugin.jsonl`, assert `result` has all four keys | ❌ Wave 0 |
| TOOL-01 | Snapshot is `lts-24.56` | grep | `grep -qx 'snapshot: lts-24.56' stack.yaml` | ❌ Wave 0 |
| TOOL-01 | Library + executable + test-suite exist under GHC2024 with the right flags | build + grep | `stack build --test --no-run-tests` → exit 0; then `grep -c 'default-language: GHC2024' *.cabal` ≥ 3 and `grep -q 'ghc-options:.*-threaded.*-rtsopts.*-with-rtsopts=-N' *.cabal` | ❌ Wave 0 |
| TOOL-01 | `-Wall` is clean (no warnings) | build | `stack build --pedantic --test --no-run-tests` → exit 0 | ❌ Wave 0 |
| TOOL-01 | Generated `.cabal` matches `package.yaml` | build + git | `stack build --dry-run && git diff --exit-code -- '*.cabal'` | ❌ Wave 0 |
| TOOL-01 | `stack.yaml.lock` committed | grep | `git ls-files --error-unmatch stack.yaml.lock` | ❌ Wave 0 |
| TOOL-02 | Workflow file exists with both triggers and the three gates | grep | `grep -q 'on:' .github/workflows/ci.yml && grep -q 'pull_request' .github/workflows/ci.yml && grep -q 'stack test' .github/workflows/ci.yml && grep -q 'run-fourmolu' .github/workflows/ci.yml && grep -qi 'hlint' .github/workflows/ci.yml` | ❌ Wave 0 |
| TOOL-02 | `hlint`/`fourmolu` are advisory, conformance is not | grep | `! awk '/name: conformance/,/^      - name/' .github/workflows/ci.yml \| grep -q continue-on-error` | ❌ Wave 0 |
| TOOL-02 | CI green on **both** remotes | **manual-only** | `gh run list --repo JMSBPP/haskell-deepseek-plugin-sdk-develop --limit 1` and `gh run list --repo d2p-finance/haskell-deepseek-plugin-sdk --limit 1` — both `success`. *Manual because it requires a push and Actions enabled in each repo's Settings; no local command can produce this signal* | ❌ Wave 0 |
| E2E-03 | ADR exists in MADR 4.0.0 shape | grep | `test -f docs/adr/0001-harness-e2e-tiering.md && grep -q '^status:' docs/adr/0001-harness-e2e-tiering.md && grep -q '^decision-makers:' docs/adr/0001-harness-e2e-tiering.md && grep -q '^## Decision Outcome' docs/adr/0001-harness-e2e-tiering.md && grep -q '^### Confirmation' docs/adr/0001-harness-e2e-tiering.md` | ❌ Wave 0 |
| E2E-03 | ADR cites the harness policy it argues against | grep | `grep -q 'docs/testing.md' docs/adr/0001-harness-e2e-tiering.md && grep -q 'python-runtime' docs/adr/0001-harness-e2e-tiering.md` | ❌ Wave 0 |
| (phase invariant) | The whole suite is green with red *visible* | unit | `stack test` → exit 0 **and** its output contains at least one `FAIL (expected:` **and** contains no `OK (unexpected:` | ❌ Wave 0 |

The last row is the phase's real acceptance test and is worth a small script (`scripts/check-red-visible.sh`) rather than a manual read.

### Sampling Rate

- **Per task commit:** `stack build --test --no-run-tests` (compile gate) plus the grep gates touched by that task.
- **Per wave merge:** `stack test --test-arguments="--no-create"` plus `git diff --exit-code -- '*.cabal'`.
- **Phase gate:** `stack build --pedantic --test --no-run-tests` → 0, `stack test` → 0 with red visible, all grep gates pass, and one successful CI run URL recorded per remote before `/gsd:verify-work`.

### Wave 0 Gaps

Everything is a gap — the repo has no test infrastructure at all.

- [ ] `package.yaml` — the hpack source; creates `test-suite conformance` (TOOL-01)
- [ ] `stack.yaml` repinned to `lts-24.56` + committed `stack.yaml.lock` (TOOL-01)
- [ ] `haskell-deepseek-plugin-sdk.cabal` — regenerated and committed (TOOL-01)
- [ ] `test/Main.hs` — tasty entry, `defaultMain =<< buildTree` (PROTO-02)
- [ ] `test/Conformance/Corpus.hs` — scenario enumeration, `EXPECTED.md` reading, the meta-tests (PROTO-02, PROTO-04)
- [ ] `test/Conformance/Properties.hs` — the four expected-fail property signatures incl. the barbies-based state machine (PROTO-02)
- [ ] `corpus/<12 scenarios>/{host.jsonl,plugin.jsonl}` + `EXPECTED.md` for each red one (PROTO-02, PROTO-03)
- [ ] `src/DeepSeek/Plugin/*.hs` — module stubs so the library stanza compiles (TOOL-01)
- [ ] `app/echo/Main.hs` — placeholder executable so the exe stanza compiles (TOOL-01)
- [ ] `PROTOCOL.md` — 13 sections (PROTO-01..04)
- [ ] `docs/adr/README.md` + `docs/adr/0001-harness-e2e-tiering.md` (E2E-03)
- [ ] `.github/workflows/ci.yml` (TOOL-02)
- [ ] `.hlint.yaml`, `fourmolu.yaml` (TOOL-02)
- [ ] `scripts/check-red-visible.sh` — the phase acceptance script
- [ ] Framework install: none — `stack build --test` resolves the entire test stack from `lts-24.56` with no `extra-deps` (verified)
- [ ] Manual: enable GitHub Actions in Settings on both repositories

## Sources

### Primary (HIGH confidence — built, run, or read from source today)

- **Local probe build**, `lts-24.56` / GHC 9.10.3 / Stack 3.11.1 / hpack 0.39.6: library + executable + test-suite under `GHC2024 -Wall`, with `tasty`, `tasty-hunit`, `tasty-golden`, `tasty-hedgehog`, `tasty-expected-failure`, `hedgehog`, `typed-process`. `stack build --test --no-run-tests` → EXIT=0 (76 dependency actions, no `extra-deps`). `stack test` → EXIT=0, "All 8 tests passed", four expected failures visible. Artifacts kept at `scratchpad/probe/` and `scratchpad/VERIFIED-conformance-Main.hs`
- `https://www.stackage.org/lts-24.56/cabal.config` — tasty 1.5.4, tasty-hunit 0.10.2, tasty-golden 2.3.6, tasty-hedgehog 1.4.0.2, tasty-expected-failure 0.12.3, hedgehog 1.5, aeson 2.2.5.0, async 2.2.6, autodocodec 0.5.0.0, autodocodec-schema 0.2.0.1, safe-exceptions 0.1.7.4, typed-process 0.2.13.0, temporary 1.3, hlint 3.10, QuickCheck 2.15.0.1, tasty-quickcheck 0.11.1, tasty-discover 5.0.2; **fourmolu absent**
- `https://www.stackage.org/lts` → 302 `/lts-24.56` — the pin is the current terminal
- `~/.ghcup/ghc/9.10.3/lib/ghc-9.10.3/lib/package.conf.d/` — base 4.20.2.0, bytestring 0.12.2.0, containers 0.7, directory 1.3.8.5, filepath 1.5.4.0, process 1.6.26.1, stm 2.5.3.1, text 2.1.3, mtl 2.3.1, transformers 0.6.1.1
- `hedgehog-1.5` tarball (`src/Hedgehog.hs:140-245`, `src/Hedgehog/Internal/State.hs:646-772`, `hedgehog.cabal`) — `FunctorB`/`TraversableB` re-exported from `Hedgehog.Internal.Barbie`, `HTraversable` under `-- * Deprecated`, `barbies >= 1.0 && < 2.2` dependency, `Gen.sequential` and `executeSequential` signatures
- `tasty-golden-2.3.6` tarball (`Test/Tasty/Golden.hs`, `Test/Tasty/Golden/Advanced.hs`) — export lists and `goldenTest` signature
- Probe test-binary `--help` — confirms `--accept`, `--no-create`, `--size-cutoff`, `--delete-output`, `--hedgehog-*`, and `-j` defaulting to core count under the threaded RTS
- `stack build --help` — confirms `--pedantic` ("Pass the -Wall and -Werror flags"), `--test-arguments`, `--coverage`; `stack --system-ghc --no-install-ghc build --dry-run` → EXIT=0
- GitHub API `repos/haskell-actions/{setup,run-fourmolu,hlint-setup,hlint-run}` — tags, releases, and `action.yml` `runs.using` at each tag and on `main`
- GitHub API `repos/ndmitchell/hlint/releases/tags/v3.10` — asset `hlint-3.10-x86_64-linux.tar.gz`
- `https://hackage.haskell.org/package/fourmolu-0.20.1.0/fourmolu.cabal` — `ghc-lib-parser >=9.14 && <9.15`; `fourmolu/fourmolu` releases → `v0.20.1.0` (2026-08-07)
- `https://raw.githubusercontent.com/adr/madr/4.0.0/template/adr-template.md` — MADR 4.0.0 section and front-matter names
- `/home/jmsbpp/ai-agents/deepseek-harness/packages/sdk/protocol/src/types.ts` — `HarnessSdkRequestMap` (`initialize`, `session/prompt`, `shutdown`), `HarnessSdkNotificationMap` (`session.event`, `session.status`, `subagent.started`, `subagent.finished`)
- `.../packages/sdk/protocol/src/transport.ts` — `:59-60` (`-32601`/`-32603` only), `:122` (`req_<hex>` ids), `:182` (`buffer.indexOf('\n')`), `:214`/`:222` (`objectParams`), `:261` (`JSON.stringify(message)+'\n'`)
- `.../packages/core/tools/src/index.ts:588` — `PreToolDecision = allow | deny{reason} | ask{reason?}`; `:222-224` mandatory `output`; `:274-279` `presentCall` purity contract
- `.../packages/core/tools/src/json-schema.ts` — enforced keyword subset (`type`/`oneOf`/`properties`/`required`/`additionalProperties`/`items`/`enum`/`const` + annotations)
- `.../packages/code-runtime/code-runtime-python/README.md:14-15` — hostile-frame rebuild stance and lossless-JSON policy verbatim
- `.../docs/testing.md` — the snapshot requirement and "prefer the real implementation" clauses the ADR must argue against
- `.../.github/workflows/ci.yml:301-308, :481` — the `python-runtime` required-job precedent; grep across all 18 workflow files confirms **no GHC/Stack/Haskell anywhere**
- Local repo inspection: `git remote -v` (both remotes present), `stack.yaml` (`lts-22.43`), `haskell-deepseek-plugin-sdk.cabal` (single `executable`, `Haskell2010`, placeholder metadata), `src/Main.hs`, `.gitignore`

### Secondary (MEDIUM confidence — WebSearch cross-checked against an official source)

- GitHub Changelog "Deprecation of Node 20 on GitHub Actions runners" — forced Node 24 default 2026-06-02, Node 20 removed 2026-09-16. Cross-verified against the observed `runs.using` values on the actions themselves
- MADR 4.0.0 release date (September 2024) and the 3.x→4.0 renames — cross-verified against the fetched 4.0.0 template's actual key names

### Tertiary (LOW confidence — flagged for validation)

- `fourmolu --ghc-opt -XGHC2024` and `.hlint.yaml`'s `- arguments: [-XGHC2024]` as the correct spellings — neither tool was executed here. Verify with one CI run before Phase 7 makes these blocking
- The `fourmolu.yaml` field list in §Code Examples — transcribed from an older release; regenerate with `fourmolu --print-defaults` at 0.20.1.0

## Metadata

**Confidence breakdown:**
- Standard stack (versions, resolvability): **HIGH** — every package built and ran on `lts-24.56` locally today; no `extra-deps` needed
- Architecture (test-tree shape, expectFail semantics, hedgehog API): **HIGH** — the exact patterns compiled and executed; the "unexpected success fails the suite" behavior and the barbies migration were observed, not assumed
- hpack/Stack behavior (GHC2024 emission, ghc-options composition, `.cabal` regeneration): **HIGH** — observed in generated output and by deliberately corrupting the `.cabal`
- GitHub Actions (versions, node runtimes, deadlines): **HIGH** for versions and `runs.using` (GitHub API); **MEDIUM** for the workflow composing correctly end-to-end, which no local command can prove
- Linter configuration for GHC2024: **LOW** — flag spellings unverified
- Corpus stub frames: **HIGH** for consistency with locked decisions and harness conventions; **MEDIUM** for exact field names in the manifest (Phase 4/5 own the derivation and may adjust)
- ADR content and precedent: **HIGH** — MADR template and the `python-runtime` precedent read from source

**Research date:** 2026-08-25
**Valid until:** 2026-09-16 for the GitHub Actions section (Node 20 removal date is a hard cliff); 2026-09-24 (30 days) for everything else. `lts-24` is an open series receiving weekly patches — a `.57`+ bump is expected and harmless.
