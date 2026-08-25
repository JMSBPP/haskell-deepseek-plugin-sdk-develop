# Flipped by: Phase 3 — Peer, Async Router, and Cancellation

**Requirement:** WIRE-04

## Why this is red

No cancel registry exists, so a completed request cannot be distinguished from
an in-flight one.

## What flipping it requires

The completed request keeps its successful result while the late `$/cancel`
produces no frame.
