{- |
Bidirectional peer: one @async@ per inbound request, the STM correlation map
for outbound requests, and the cancellation registry behind @$/cancel@.

Empty in Phase 1. Phase 3 (WIRE-04, WIRE-05, API-05) fills it in.
-}
module DeepSeek.Plugin.Peer () where
