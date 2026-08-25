# Flipped by: Phase 6 — Guard, Section, and Subagent Seams (Haskell)

**Requirement:** API-06

## Why this is red

No `Guard` seam exists, so `guard/decide` is unanswered.

## What flipping it requires

The guard returns an allow answer, which the host translates into `next()` on
the `tools/pre-execute` waterfall.
