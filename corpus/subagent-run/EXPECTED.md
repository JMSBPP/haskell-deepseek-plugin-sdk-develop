# Flipped by: Phase 6 — Guard, Section, and Subagent Seams (Haskell)

**Requirement:** API-08

## Why this is red

No `Subagent` seam exists, so `subagent/run` is unanswered.

## What flipping it requires

The provider returns `{stopReason, output}` mirroring the harness's
`SubagentResult`.
