# Flipped by: Phase 6 — Guard, Section, and Subagent Seams (Haskell)

**Requirement:** API-06

## Why this is red

No `Guard` seam exists, so `guard/decide` is unanswered.

## What flipping it requires

The guard returns a deny carrying a model-readable `reason`, which
short-circuits the host's waterfall.
