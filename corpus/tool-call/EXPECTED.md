# Flipped by: Phase 5 — Plugin API, Manifest, and runPlugin

**Requirement:** API-03

## Why this is red

No dispatch and no `Tool` existential exist, so `tool/execute` is unanswered.

## What flipping it requires

`tool/execute` returns `{value, content}` where `content` is the plugin-side
`render` output.
