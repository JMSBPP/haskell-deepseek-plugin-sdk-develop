# Flipped by: Phase 2 — Wire Envelope and Transport

**Requirement:** WIRE-01, WIRE-03

## Why this is red

No envelope validation exists, so non-object `params`, batch arrays, and
non-scalar ids are unhandled.

## What flipping it requires

Each malformed frame yields `-32600` with the following well-formed frame still
served.
