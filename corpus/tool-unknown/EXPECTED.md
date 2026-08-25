# Flipped by: Phase 5 — Plugin API, Manifest, and runPlugin

**Requirement:** API-03

## Why this is red

No manifest lookup exists, so an undeclared tool name cannot be distinguished
from a declared one.

## What flipping it requires

Dispatch answers `-32002` for a name absent from the manifest, without running
any handler.
