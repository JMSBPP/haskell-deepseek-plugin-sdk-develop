# Flipped by: Phase 6 — Guard, Section, and Subagent Seams (Haskell)

**Requirement:** API-07

## Why this is red

No `PluginHandle` and no outbound notification path exist, so the plugin can
originate no frame at all.

## What flipping it requires

`notifySectionChanged` pushes one `section.changed` notification after the
handshake, with no host request preceding it.
