# Flipped by: Phase 2 — Wire Envelope and Transport

**Requirement:** WIRE-02

## Why this is red

No bounded reader exists, so `maxFrameBytes` is not enforced and `SCENARIO.json`
is not read.

## What flipping it requires

The reader honors the scenario's `maxFrameBytes`, rejects the 300-byte line with
`-32600` and `id:null`, and does not buffer it.
