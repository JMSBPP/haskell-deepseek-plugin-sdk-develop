# Flipped by: Phase 5 — Plugin API, Manifest, and runPlugin

**Requirement:** API-01

## Why this is red

No event loop exists.

## What flipping it requires

`shutdown` returns `{}` and the process exits cleanly with no orphaned threads.
