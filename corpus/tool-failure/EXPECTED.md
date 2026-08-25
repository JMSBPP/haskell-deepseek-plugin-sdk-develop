# Flipped by: Phase 5 — Plugin API, Manifest, and runPlugin

**Requirement:** API-03

## Why this is red

No handler-exception policy exists.

## What flipping it requires

A handler exception becomes `-32004 TOOL_FAILED` rather than `-32603` or a dead
process.
