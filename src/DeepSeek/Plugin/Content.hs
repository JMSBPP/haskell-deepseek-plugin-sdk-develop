{- |
@ContentBlock@ mirroring the harness's @packages\/llm\/llm\/src\/types.ts@
union (@text@, @reasoning@, @image@, @tool-call@, @tool-result@) with an
@Unknown Value@ fall-through, so a harness that merges in a new variant does
not break decoding.

Empty in Phase 1. Phase 5 (API-04) fills it in.
-}
module DeepSeek.Plugin.Content () where
