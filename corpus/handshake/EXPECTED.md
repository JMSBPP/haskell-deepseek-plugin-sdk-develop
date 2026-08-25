# Flipped by: Phase 5 — Plugin API, Manifest, and runPlugin

**Requirement:** PROTO-03, PROTO-04, API-01

## Why this is red

No `runPlugin` exists, so nothing answers `initialize` and no manifest is
projected from a `Plugin` record.

## What flipping it requires

The plugin answers the host-initiated `initialize` with the manifest in
`plugin.jsonl`, declaring tools, guards, sections, and subagents.
