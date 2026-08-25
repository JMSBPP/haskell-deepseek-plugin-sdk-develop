---
phase: 01-protocol-freeze-and-toolchain-foundation
plan: 02
subsystem: protocol
tags: [json-rpc, ndjson, conformance-corpus, protocol-spec, cancellation, jsonl]

# Dependency graph
requires: []
provides:
  - "PROTOCOL.md: the frozen wire — 13 numbered sections plus Deferred, readable without any code"
  - "corpus/: 17 scenario directories of host.jsonl/plugin.jsonl frames both implementations replay"
  - "corpus/*/EXPECTED.md: 17 known-red manifests, each naming the phase that must turn it green"
  - "corpus/malformed-oversize/SCENARIO.json: the per-scenario transport-config convention (maxFrameBytes, deadlineMs, quiescenceMs)"
  - "The two-pass id-normalization algorithm, in language-neutral pseudocode"
  - "The reference echo tool's frozen behavior table (quick/boom/slow/other)"
affects: [phase-02-wire-transport, phase-03-router-cancellation, phase-04-schema, phase-05-plugin-api, phase-06-seams, phase-07-echo-conformance, phase-08-bridge, phase-09-bridge-registration, phase-10-e2e, 01-04-conformance-skeleton]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Executable spec first: every normative claim in PROTOCOL.md is pinned by a corpus frame"
    - "EXPECTED.md presence is the single source of truth for expect-fail; its first line is machine-readable"
    - "A zero-length plugin.jsonl means the plugin emits no frames, made finite by a quiescence window"
    - "Per-scenario SCENARIO.json lowers a bound instead of committing a large fixture"

key-files:
  created:
    - PROTOCOL.md
    - corpus/handshake/{host,plugin}.jsonl
    - corpus/version-mismatch/{host,plugin}.jsonl
    - corpus/tool-call/{host,plugin}.jsonl
    - corpus/tool-failure/{host,plugin}.jsonl
    - corpus/tool-unknown/{host,plugin}.jsonl
    - corpus/subagent-run/{host,plugin}.jsonl
    - corpus/section-changed/{host,plugin}.jsonl
    - corpus/shutdown/{host,plugin}.jsonl
    - corpus/guard-{allow,deny,ask}/{host,plugin}.jsonl
    - corpus/cancel-{inflight,late,unknown}/{host,plugin}.jsonl
    - corpus/malformed-{junk-line,shape,oversize}/{host,plugin}.jsonl
    - corpus/malformed-oversize/SCENARIO.json
    - corpus/*/EXPECTED.md
  modified:
    - .planning/REQUIREMENTS.md
    - .planning/ROADMAP.md
    - .planning/PROJECT.md

key-decisions:
  - "-32800 REQUEST_CANCELLED is the frozen cancellation code and -32003 CANCELLED is retired; a cancelled in-flight request always gets a reply, an unknown or late $/cancel gets none"
  - "-32002 UNKNOWN_CONTRIBUTION, not -32601, answers a tool/guard/subagent name absent from the manifest: the method was dispatched, the contribution was not"
  - "-32004 TOOL_FAILED is a domain failure the model reads; -32603 is reserved for SDK bugs, including a tool result that fails its own declared output.schema"
  - "The host evaluates guard match.tools, so Guard carries a declarative matchTools :: [ToolName] rather than a predicate that cannot cross a process boundary"
  - "failPolicy is declared per guard by the plugin and is authoritative; host config supplies only requestTimeoutMs"
  - "All four SubagentCapabilities booleans are required, so a plugin cannot acquire a capability by silence"
  - "The subagent result field is output, mirroring the harness's SubagentResult; lastAssistantMessage is retired"
  - "Id normalization is two passes so direction follows the request's originator: a plugin's response to h-1 normalizes to h1, never p1"
  - "params is always a JSON object and batches are unsupported, both rejected with -32600, because the harness's objectParams() would silently collapse them"

patterns-established:
  - "Corpus frame as specification: PROTO-04's manifest is a single frame, not prose, and section 4 quotes that file"
  - "Manifest exists once and is copied: corpus/section-changed/plugin.jsonl line 1 is byte-identical to corpus/handshake/plugin.jsonl"
  - "Frozen reference-tool argument table (quick/boom/slow) makes every scenario replayable without an author's judgment"
  - "Deterministic fake-host pacing: await each reply, except a $/cancel immediately following a request"

requirements-completed: [PROTO-01, PROTO-02, PROTO-03, PROTO-04]

# Metrics
duration: 5min
completed: 2026-08-25
---

# Phase 1 Plan 02: Protocol Freeze and Conformance Corpus Summary

**A 17-scenario NDJSON frame corpus plus PROTOCOL.md freezing the JSON-RPC wire — methods, manifest, the ten-code error table, cancellation, the large-integer policy, and a two-pass id normalization — with every JSON example in the spec copied from a corpus file.**

## Performance

- **Duration:** 5 min
- **Started:** 2026-08-25T20:38:44Z
- **Completed:** 2026-08-25T20:43:43Z
- **Tasks:** 3
- **Files modified:** 56 (52 created, 4 modified)

## Accomplishments

- 17 scenario directories under `corpus/`, each with `host.jsonl`, `plugin.jsonl`, and an `EXPECTED.md` whose first line names the owning phase — covering handshake, version mismatch, tool call/failure/unknown, subagent run, plugin-originated section change, guard allow/deny/ask, in-flight/late/unknown cancellation, junk line, malformed shape, oversize frame, and shutdown.
- `PROTOCOL.md` frozen at 13 numbered sections plus `Deferred`: framing with harness source citations, envelope rules, the manifest field table, versioning, the method table with both result envelopes, the ten-row error table, cancellation, the lossless-number policy, hostile input, id namespaces, the conformance-corpus contract, and shutdown.
- The roadmap's open blocker is resolved on disk: `-32800` is the cancellation code, `-32003` appears nowhere in `corpus/` or `PROTOCOL.md`, and the choice is pinned by `corpus/cancel-inflight/plugin.jsonl`.
- Section 12 makes the corpus mechanically replayable: `SCENARIO.json` keys with defaults, fake-host pacing rules, the frozen `echo` behavior table, and language-neutral two-pass id-normalization pseudocode.
- Four planning documents now agree with the frozen wire: `section.changed` replaces `section/changed`, `matchTools` replaces the predicate, `output` replaces `lastAssistantMessage`, and API-10 carries the reference-tool behaviors.

## Task Commits

Each task was committed atomically:

1. **Task 1: The eight request/response scenarios the plugin answers directly** - `706edb7` (feat)
2. **Task 2: The nine guard, cancellation, and malformed-input scenarios** - `4ab6b10` (feat)
3. **Task 3: Freeze PROTOCOL.md and amend the planning documents** - `15f786a` (docs)

## Files Created/Modified

- `PROTOCOL.md` - the frozen wire; the only normative authority, superseding `.planning/research/ARCHITECTURE.md`
- `corpus/handshake/plugin.jsonl` - PROTO-04's manifest as a single frame, quoted verbatim by PROTOCOL.md section 4
- `corpus/section-changed/plugin.jsonl` - the manifest line copied byte for byte, then the corpus's only plugin-originated frame
- `corpus/version-mismatch/plugin.jsonl` - the observable PROTO-03 failure (`-32001` naming both versions)
- `corpus/cancel-inflight/plugin.jsonl` - the frozen `-32800` cancellation reply
- `corpus/cancel-unknown/plugin.jsonl` - zero bytes: the "emits no frames" convention
- `corpus/malformed-oversize/{SCENARIO.json,host.jsonl}` - a 300-byte well-formed frame against a 256-byte bound
- `corpus/malformed-shape/{host,plugin}.jsonl` - non-object `params`, batch array, and non-scalar id, each `-32600`, with the next well-formed frame still served
- `corpus/*/EXPECTED.md` - 17 red-state manifests naming phases 2, 3, 5, and 6
- `.planning/REQUIREMENTS.md` - API-06 (`matchTools`, authoritative `failPolicy`), API-07 and BRIDGE-06 (`section.changed`), API-08 (`output`, `structured`, `diagnostic`), API-10 (reference-tool behaviors)
- `.planning/ROADMAP.md` - Phase 6 and Phase 9 success criterion 3 respell the notification
- `.planning/PROJECT.md` - bidirectional-dispatch and `Section` bullets respell the notification; the `Subagent` bullet drops `lastAssistantMessage`

## Decisions Made

- **`-32800`, not `-32003`.** The cancellation code conflict between REQUIREMENTS.md and the research ARCHITECTURE.md draft is settled in favor of LSP's `RequestCancelled`. A cancelled in-flight request always receives a reply so a host waiter — in particular the `tools/pre-execute` waterfall — cannot wedge; an unknown or already-completed id is silently ignored.
- **`-32002` over `-32601` for an unknown contribution.** `tool/execute` exists and was dispatched; only the named tool did not, so the code that fires names the contribution, not the method.
- **`-32603` for a tool result that fails its own declared `output.schema`.** A plugin contradicting its own manifest is an operator-actionable SDK bug, not a domain failure, so it must not share `-32004` with an author's handler exception.
- **The host owns guard `match` evaluation.** That is what makes `matchTools :: [ToolName]` correct: a `ToolName -> Bool` predicate cannot be serialized into a manifest.
- **All four subagent capability booleans are required.** An absent flag is not "false by default", so a plugin that gains a capability cannot acquire it by silence.
- **Two-pass id normalization.** Pass 1 builds an origin table from both files, so pass 2 can assign direction by the request's originator rather than by the file a frame appears in. Without this, two implementations comparing the same corpus would disagree on every response.
- **The oversize scenario lowers the bound instead of raising the frame.** `SCENARIO.json` costs 300 bytes and establishes a per-scenario transport-config convention the later phases reuse for `deadlineMs` and `quiescenceMs`.

## Deviations from Plan

None - plan executed exactly as written.

Two cosmetic wording choices inside PROTOCOL.md prose (both within the plan's stated content, neither changing a rule):

- Section 2 states the framing rule in words rather than transcribing the harness's template-literal expression, which would have required nested backticks inside inline code. The cited line (`transport.ts:261`) is unchanged.
- Section 6's direction column reads "host to plugin" / "plugin to host" rather than using an arrow glyph, keeping the file free of any non-ASCII character that could be confused with U+2212 in the error table.

## Issues Encountered

None. Plans 01-01 and 01-03 ran concurrently in the same working tree; staging was restricted to this plan's own paths, and `.planning/STATE.md` and `.planning/config.json` (touched by 01-03) were left unstaged. `git diff --quiet -- .planning/research/` confirms the frozen research tree is untouched.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Phase 2 can start immediately: `corpus/malformed-*` and `corpus/shutdown` are the transport's acceptance frames, and PROTOCOL.md sections 2, 3, 9, and 10 specify the reader without further decisions. Phase 2 still owns the default `maxFrameBytes` value.
- Phase 3 has its cancellation acceptance frames (`cancel-inflight`, `cancel-late`, `cancel-unknown`) and the unconditional-reply rule.
- Plan 01-04's tasty skeleton has its inputs: 17 directories, 17 `EXPECTED.md` files with a parseable first line, and section 12's normalization algorithm to implement.
- Phase 8's bridge stream is unblocked without GHC; the bridge vendors this corpus with a checksum test.
- Open concern carried forward: `EXPECTED.md` currently exists for all 17 scenarios, so plan 01-04's `expectFail` wiring must treat a passing scenario as a suite failure to force deletion at flip time.

---
*Phase: 01-protocol-freeze-and-toolchain-foundation*
*Completed: 2026-08-25*

## Self-Check: PASSED

All 13 claimed files exist on disk (52 corpus files tracked by git) and all three task commits (`706edb7`, `4ab6b10`, `15f786a`) are present in the repository history.
