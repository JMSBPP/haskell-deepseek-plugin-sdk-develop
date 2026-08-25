# Flipped by: Phase 2 — Wire Envelope and Transport

**Requirement:** WIRE-03

## Why this is red

No transport exists, so a junk line cannot become a `-32700` frame.

## What flipping it requires

The junk line yields `-32700` with the reader still in sync for the next frame.
