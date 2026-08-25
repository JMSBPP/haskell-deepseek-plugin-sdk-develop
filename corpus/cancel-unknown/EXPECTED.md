# Flipped by: Phase 3 — Peer, Async Router, and Cancellation

**Requirement:** WIRE-04

## Why this is red

No cancel registry exists, so an unknown id cannot be silently ignored.

## What flipping it requires

A `$/cancel` for an id the plugin never saw produces no frame at all and no log
line above `debug`.
