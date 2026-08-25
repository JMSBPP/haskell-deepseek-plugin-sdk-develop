{- |
The author-facing records @runPlugin@ consumes: @Plugin@, the @Tool@
existential, @Guard@, @Section@, and @Subagent@, plus @Config@ and @Exec@.
Re-exported from @DeepSeek.Plugin@, which is the module a plugin author
imports.

Empty in Phase 1. Phase 5 (API-01, API-03) and Phase 6 (API-06, API-07,
API-08) fill it in.
-}
module DeepSeek.Plugin.Types () where
