# Flipped by: Phase 5 — Plugin API, Manifest, and runPlugin

**Requirement:** PROTO-03

## Why this is red

No handshake exists, so no version comparison happens and no `-32001` frame is
emitted.

## What flipping it requires

The plugin replies `-32001` naming both versions, serves no contribution, and
exits non-zero.
