{- |
Public entry point of the Haskell plugin SDK. @runPlugin@ lives here — this
module, not @DeepSeek.Plugin.Types@, is what a plugin author imports — and it
owns the event loop that answers a host-initiated handshake and serves requests
until stdin EOF, @shutdown@, or SIGPIPE. The records it consumes live in
@DeepSeek.Plugin.Types@ and are re-exported from here.

Empty in Phase 1. Phase 5 (API-01, API-02, API-03, API-09) fills it in.
-}
module DeepSeek.Plugin () where
