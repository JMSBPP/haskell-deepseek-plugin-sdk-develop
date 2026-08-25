{- |
JSON-RPC 2.0 envelope values and the newline-delimited stdio transport that
carries them, including the bounded reader and the hostile-frame rebuild
described in @PROTOCOL.md@ sections 2, 3, and 10.

Empty in Phase 1. Phase 2 (WIRE-01, WIRE-02, WIRE-03, WIRE-06) fills it in.
-}
module DeepSeek.Plugin.Wire () where
