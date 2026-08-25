# Flipped by: Phase 3 — Peer, Async Router, and Cancellation

**Requirement:** WIRE-04, API-05

## Why this is red

No async router exists, so `$/cancel` cannot reach a running handler.

## What flipping it requires

The cancelled `tool/execute` resolves with `-32800` while its handler still
runs.
